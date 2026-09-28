import AndroidKit
import Foundation
import Observation

/// SDK packages: the repository catalog, what's installed, and the install queue.
///
/// Installs run here rather than in a view, so they keep going when the panel closes.
@Observable
final class SDKStore {
    enum ItemState: Equatable {
        case waiting
        case downloading(received: Int64, total: Int64)
        case unpacking
        case removing
        case failed(String)

        var fraction: Double? {
            if case let .downloading(received, total) = self, total > 0 { return Double(received) / Double(total) }
            return nil
        }
    }

    struct QueueItem: Identifiable, Equatable {
        let id: String
        var displayName: String
        var state: ItemState
        /// Size of the archive this item downloads, for display.
        var size: Int64?
    }

    /// Packages waiting for the user to accept licenses before installing.
    struct LicenseRequest: Equatable {
        var plan: InstallPlan
        var licenses: [SDKLicense]
    }

    private(set) var catalog: RepositoryCatalog?
    private(set) var installed: [LocalPackage] = []
    private(set) var list = SDKPackageList(catalog: nil, installed: [])
    private(set) var isLoadingCatalog = false
    private(set) var catalogError: String?
    private(set) var queue: [QueueItem] = []
    private(set) var diskUsage: [String: Int64] = [:]
    var licenseRequest: LicenseRequest?
    var failure: String?

    private(set) var channel: PackageChannel
    private var sdkRoot: URL?
    private var java: JavaInstallation?
    private var environment: [String: String] = [:]
    private var installTask: Task<Void, Never>?
    /// What finished since the queue last emptied, for the notification.
    private var installedNames: [String] = []
    private var failedNames: [String] = []
    private var lastFailure: String?
    private let preferences = SharedPreferences()

    init() {
        channel = preferences.sdkChannel
    }

    var isBusy: Bool { queue.contains { $0.state != .waiting && !$0.isFailed } || installTask != nil }
    var hasTools: Bool { sdkRoot.map { SDKInstaller(sdkRoot: $0, java: nil, environment: [:]).isAvailable } ?? false }
    var updateCount: Int { list.updates.count }

    /// Overall download progress (0…1) while installs run, for the menu bar icon.
    var installProgress: Double? {
        let active = queue.filter { !$0.isFailed && $0.state != .removing }
        guard !active.isEmpty else { return nil }
        let total = active.compactMap(\.size).reduce(0, +)
        guard total > 0 else { return 0 }
        let done = active.reduce(Int64(0)) { sum, item in
            switch item.state {
            case let .downloading(received, _): sum + received
            case .unpacking: sum + (item.size ?? 0)
            default: sum
            }
        }
        return min(1, Double(done) / Double(total))
    }

    // MARK: - Loading

    func configure(sdk: SDKLocation?, java: JavaInstallation?, environment: [String: String]) {
        self.java = java
        self.environment = environment
        let root = sdk?.url
        guard root != sdkRoot else {
            reloadInstalled()
            return
        }
        sdkRoot = root
        reloadInstalled()
        Task { await loadCatalog() }
    }

    func reloadInstalled() {
        guard let sdkRoot else {
            installed = []
            rebuildList()
            return
        }
        Task {
            installed = await Task.detached { LocalPackages.scan(sdkRoot: sdkRoot) }.value
            rebuildList()
        }
    }

    /// Loads the cached catalog immediately, then refreshes it from the network if it's stale.
    func loadCatalog(force: Bool = false) async {
        guard !isLoadingCatalog else { return }
        let client = RepositoryClient()
        if catalog == nil, let cached = client.cachedCatalog() {
            catalog = cached
            rebuildList()
        }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalog = try await client.catalog(forceRefresh: force)
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
        rebuildList()
    }

    func setChannel(_ channel: PackageChannel) {
        self.channel = channel
        preferences.sdkChannel = channel
        rebuildList()
    }

    private func rebuildList() {
        list = SDKPackageList(catalog: catalog, installed: installed, channel: channel)
    }

    // MARK: - Queries

    func queueItem(_ id: String) -> QueueItem? { queue.first { $0.id == id } }

    /// Installable system images for an AVD profile, newest first, not yet installed.
    func downloadableImages(for profile: DeviceProfile) -> [(package: RemotePackage, image: SystemImage)] {
        guard let catalog else { return [] }
        let installedIDs = Set(installed.map(\.id))
        let candidates: [RemotePackage] = catalog.latestPackages(channel: channel).filter { (package: RemotePackage) in
            package.category == PackageCategory.systemImages && !installedIDs.contains(package.id) && !package.obsolete
        }
        return candidates
            .compactMap { (package: RemotePackage) -> (package: RemotePackage, image: SystemImage)? in
                guard let image = SystemImage(remote: package), image.isCompatible(with: profile) else { return nil }
                return (package, image)
            }
            .sorted { lhs, rhs in
                if lhs.image.apiNumber != rhs.image.apiNumber { return lhs.image.apiNumber > rhs.image.apiNumber }
                return lhs.image.hasPlayStore && !rhs.image.hasPlayStore
            }
    }

    func loadDiskUsage(for packages: [SDKPackage]) async {
        let targets = packages.compactMap { package -> (String, String)? in
            guard let path = package.installed?.path, diskUsage[package.id] == nil else { return nil }
            return (package.id, path)
        }
        for (id, path) in targets {
            diskUsage[id] = await Task.detached { AVDCatalog.folderSize(URL(fileURLWithPath: path)) }.value
        }
    }

    // MARK: - Install & remove

    /// Installs packages (with dependencies). Asks for license acceptance first if needed;
    /// returns true if that's what happens, so the UI can show the license page.
    @discardableResult
    func install(_ ids: [String]) -> Bool {
        guard let catalog, let sdkRoot else {
            failure = catalogError ?? "The package catalog hasn't loaded yet."
            return false
        }
        failure = nil
        let pending = Set(queue.map(\.id))
        let plan: InstallPlan
        do {
            plan = try catalog.installPlan(for: ids.filter { !pending.contains($0) }, installed: installed, channel: channel)
        } catch {
            failure = error.localizedDescription
            return false
        }
        guard !plan.isEmpty else { return false }

        let unaccepted = LicenseStore(sdkRoot: sdkRoot).unaccepted(in: plan)
        if !unaccepted.isEmpty {
            licenseRequest = LicenseRequest(plan: plan, licenses: unaccepted)
            return true
        }
        enqueue(plan)
        return false
    }

    func acceptLicensesAndInstall() {
        guard let request = licenseRequest, let sdkRoot else { return }
        do {
            for license in request.licenses {
                try LicenseStore(sdkRoot: sdkRoot).accept(license)
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        licenseRequest = nil
        enqueue(request.plan)
    }

    func update(_ ids: [String]) { install(ids) }

    private func enqueue(_ plan: InstallPlan) {
        for package in plan.packages where !queue.contains(where: { $0.id == package.id }) {
            queue.append(QueueItem(id: package.id, displayName: package.displayName, state: .waiting, size: package.archive?.size))
        }
        Notifier.shared.requestAuthorization()
        startQueueIfNeeded(plan)
    }

    private var pendingPlans: [InstallPlan] = []

    private func startQueueIfNeeded(_ plan: InstallPlan) {
        pendingPlans.append(plan)
        guard installTask == nil else { return }
        installTask = Task { await drain() }
    }

    private func drain() async {
        while let plan = pendingPlans.first, let sdkRoot {
            pendingPlans.removeFirst()
            let installer = SDKInstaller(sdkRoot: sdkRoot, java: java, environment: environment)
            do {
                for try await event in installer.install(plan) {
                    handle(event)
                }
            } catch is CancellationError {
                break
            } catch {
                markFailed(plan, message: error.localizedDescription)
            }
            await refreshInstalled()
        }
        installTask = nil
        if pendingPlans.isEmpty {
            queue.removeAll { !$0.isFailed }
            notifyFinished()
        }
    }

    private func notifyFinished() {
        defer {
            installedNames = []
            failedNames = []
            lastFailure = nil
        }
        if !failedNames.isEmpty {
            let names = ListFormatter.localizedString(byJoining: failedNames)
            Notifier.shared.post("Couldn't install \(names)", lastFailure ?? "Open Andyman to try again.", opening: .sdk)
        } else if !installedNames.isEmpty {
            let title = installedNames.count == 1 ? "SDK package installed" : "\(installedNames.count) SDK packages installed"
            Notifier.shared.post(title, ListFormatter.localizedString(byJoining: installedNames), opening: .sdk)
        }
    }

    private func handle(_ event: InstallEvent) {
        switch event {
        case let .started(id):
            setState(id, .downloading(received: 0, total: queueItem(id)?.size ?? 0))
        case let .downloading(id, received, total):
            setState(id, .downloading(received: received, total: total))
        case let .unpacking(id):
            setState(id, .unpacking)
        case let .finished(id):
            installedNames.append(queueItem(id)?.displayName ?? id)
            queue.removeAll { $0.id == id }
            Task { await refreshInstalled() }
        case .output:
            break
        }
    }

    private func markFailed(_ plan: InstallPlan, message: String) {
        lastFailure = message
        failedNames += plan.packages.filter { package in queue.contains { $0.id == package.id } }.map(\.displayName)
        for package in plan.packages {
            if let index = queue.firstIndex(where: { $0.id == package.id }) {
                queue[index].state = .failed(message)
            }
        }
    }

    private func setState(_ id: String, _ state: ItemState) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].state = state
    }

    private func refreshInstalled() async {
        guard let sdkRoot else { return }
        installed = await Task.detached { LocalPackages.scan(sdkRoot: sdkRoot) }.value
        rebuildList()
    }

    /// Stops the current install and drops everything queued.
    func cancelAll() {
        pendingPlans.removeAll()
        installedNames = []
        failedNames = []
        installTask?.cancel()
        installTask = nil
        queue.removeAll()
        Task { await refreshInstalled() }
    }

    func dismissFailure(_ id: String) {
        queue.removeAll { $0.id == id }
    }

    func uninstall(_ id: String) {
        guard let sdkRoot else { return }
        failure = nil
        let displayName = list.package(id)?.displayName ?? id
        queue.append(QueueItem(id: id, displayName: displayName, state: .removing, size: nil))
        let installer = SDKInstaller(sdkRoot: sdkRoot, java: java, environment: environment)
        Task {
            do {
                try await installer.uninstall([id])
                queue.removeAll { $0.id == id }
            } catch {
                setState(id, .failed(error.localizedDescription))
            }
            diskUsage[id] = nil
            await refreshInstalled()
        }
    }
}

extension SDKStore.QueueItem {
    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
