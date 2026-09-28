import AndroidKit
import Foundation
import Observation

/// Installing JDKs from the Java section.
@Observable
final class JavaStore {
    struct Install: Equatable {
        var major: Int
        /// Download progress; nil while resolving or unpacking.
        var fraction: Double?
        var detail: String
    }

    private(set) var install: Install?
    var failure: String?
    var onInstalled: () -> Void = {}

    private var task: Task<Void, Never>?

    var isInstalling: Bool { install != nil }

    func install(major: Int) {
        guard install == nil else { return }
        failure = nil
        Notifier.shared.requestAuthorization()
        install = Install(major: major, fraction: nil, detail: "Finding JDK \(major)…")
        task = Task {
            defer {
                install = nil
                task = nil
            }
            do {
                let installer = JDKInstaller()
                let release = try await installer.latestRelease(major: major)
                let size = ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file)
                install = Install(major: major, fraction: 0, detail: "Downloading Temurin \(release.version) · \(size)")
                _ = try await installer.install(release) { received, total in
                    Task { @MainActor in
                        guard total > 0 else { return }
                        self.install?.fraction = Double(received) / Double(total)
                    }
                } extracting: {
                    Task { @MainActor in
                        self.install?.fraction = nil
                        self.install?.detail = "Unpacking…"
                    }
                }
                onInstalled()
                Notifier.shared.post("JDK \(major) installed", "Temurin \(release.version) is ready to use.", opening: .tools)
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
                Notifier.shared.post("Couldn't install JDK \(major)", error.localizedDescription, opening: .tools)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
