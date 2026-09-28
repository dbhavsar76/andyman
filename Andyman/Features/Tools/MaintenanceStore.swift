import AndroidKit
import Foundation
import Observation

/// Gradle daemons and disk cleanup ("Free Up Space").
@Observable
final class MaintenanceStore {
    struct Item: Identifiable, Equatable {
        var target: CleanupTarget
        /// Nil while measuring.
        var size: Int64?
        var id: String { target.id }
    }

    private(set) var daemons: [GradleDaemon] = []
    private(set) var hasLoadedDaemons = false
    private(set) var isStoppingDaemons = false

    private(set) var items: [Item] = []
    private(set) var isScanning = false
    private(set) var isCleaning = false
    var selection: Set<String> = []
    /// "Freed 5.2 GB" after a cleanup.
    var result: String?
    var failure: String?

    private var hasChosenSelection = false

    var daemonMemory: Int64 { daemons.reduce(0) { $0 + $1.memory } }
    var selectedSize: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64? {
        guard !isScanning, items.allSatisfy({ $0.size != nil }) else { return nil }
        return items.reduce(0) { $0 + ($1.size ?? 0) }
    }

    // MARK: - Daemons

    func refreshDaemons() async {
        daemons = await GradleDaemons.running()
        hasLoadedDaemons = true
    }

    func stopDaemons() async {
        guard !daemons.isEmpty else { return }
        isStoppingDaemons = true
        await GradleDaemons.stop(daemons)
        await refreshDaemons()
        isStoppingDaemons = false
    }

    // MARK: - Cleanup

    private struct ScanRequest {
        var sdkRoot: URL?
        var environment: [String: String]
        var devices: [VirtualDevice]
        var running: Set<String>
    }

    /// The newest scan asked for while one was running; it runs next.
    private var pendingScan: ScanRequest?

    /// Lists targets, then measures them (largest caches take a few seconds). A request
    /// made during a scan (say, once the emulators have loaded) runs right after it.
    func scan(sdkRoot: URL?, environment: [String: String], devices: [VirtualDevice], running: Set<String>) async {
        pendingScan = ScanRequest(sdkRoot: sdkRoot, environment: environment, devices: devices, running: running)
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        while let request = pendingScan {
            pendingScan = nil
            await performScan(request)
        }
    }

    private func performScan(_ request: ScanRequest) async {
        let targets = await Task.detached {
            Cleanup(sdkRoot: request.sdkRoot, environment: request.environment).targets(devices: request.devices, running: request.running)
        }.value
        let previousSizes = Dictionary(items.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        items = targets.map { Item(target: $0, size: previousSizes[$0.id] ?? nil) }
        if !hasChosenSelection {
            selection = Set(targets.filter(\.recommended).map(\.id))
        }
        selection.formIntersection(targets.map(\.id))

        await withTaskGroup(of: (String, Int64).self) { group in
            for target in targets {
                group.addTask { (target.id, Cleanup.size(of: target)) }
            }
            for await (id, size) in group {
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].size = size }
            }
        }
        // Nothing to gain from empty ones.
        items.removeAll { $0.size == 0 }
        selection.formIntersection(items.map(\.id))
    }

    func toggle(_ id: String) {
        hasChosenSelection = true
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func cleanSelected(sdkRoot: URL?, environment: [String: String], devices: [VirtualDevice], running: Set<String>) async {
        let targets = items.filter { selection.contains($0.id) }.map(\.target)
        guard let freed = await clean(targets) else { return }
        result = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
        await scan(sdkRoot: sdkRoot, environment: environment, devices: devices, running: running)
    }

    /// Deletes targets, stopping Gradle daemons first when needed. Returns bytes freed, or nil
    /// on failure (see `failure`).
    func clean(_ targets: [CleanupTarget]) async -> Int64? {
        guard !isCleaning, !targets.isEmpty else { return nil }
        isCleaning = true
        failure = nil
        result = nil
        defer { isCleaning = false }

        if targets.contains(where: \.needsGradleStopped) {
            let running = await GradleDaemons.running()
            if !running.isEmpty { await GradleDaemons.stop(running) }
        }
        let outcome = await Task.detached { () -> Result<Int64, any Error> in
            do {
                var freed: Int64 = 0
                for target in targets { freed += try Cleanup.clean(target) }
                return .success(freed)
            } catch {
                return .failure(error)
            }
        }.value
        await refreshDaemons()
        switch outcome {
        case let .success(freed):
            return freed
        case let .failure(error):
            failure = error.localizedDescription
            return nil
        }
    }
}
