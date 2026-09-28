import AndroidKit
import Foundation
import Observation

/// What the project doctor compares a project against, gathered from the rest of the app.
nonisolated struct ProjectContext: Sendable {
    var sdk: SDKLocation?
    var installed: [LocalPackage]
    var catalog: RepositoryCatalog?
    var javaInstallations: [JavaInstallation]
    var environment: [String: String]
    var devices: [VirtualDevice]
    var defaultJava: JavaInstallation?
}

/// Recent React Native projects and their doctor reports.
@Observable
final class ProjectStore {
    struct Entry: Equatable {
        var report: ProjectReport?
        var error: String?
        var buildFolders: [MaintenanceStore.Item] = []
        var isChecking = false
    }

    private(set) var recents: [String]
    private(set) var entries: [String: Entry] = [:]

    private static let recentsKey = "recentProjects"
    private static let maxRecents = 5

    init() {
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    func entry(_ path: String) -> Entry { entries[path] ?? Entry() }

    /// Adds a project to the top of the recents list.
    func remember(_ path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func forget(_ path: String) {
        recents.removeAll { $0 == path }
        entries[path] = nil
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func check(_ path: String, context: ProjectContext) async {
        entries[path, default: Entry()].isChecking = true
        defer { entries[path]?.isChecking = false }
        let result = await Task.detached { () -> Result<(ProjectReport, [CleanupTarget]), any Error> in
            do {
                let project = try AndroidProject.load(path, environment: context.environment)
                let report = ProjectDoctor().check(.init(
                    project: project,
                    sdk: context.sdk,
                    installed: context.installed,
                    catalog: context.catalog,
                    javaInstallations: context.javaInstallations,
                    environment: context.environment,
                    devices: context.devices,
                    defaultJava: context.defaultJava
                ))
                return .success((report, Cleanup.projectTargets(project)))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success((report, targets)):
            entries[path, default: Entry()].report = report
            entries[path]?.error = nil
            await measure(targets, for: path)
        case let .failure(error):
            entries[path, default: Entry()].report = nil
            entries[path]?.error = error.localizedDescription
        }
    }

    private func measure(_ targets: [CleanupTarget], for path: String) async {
        var items = targets.map { MaintenanceStore.Item(target: $0, size: nil) }
        entries[path]?.buildFolders = items
        for index in items.indices {
            let target = items[index].target
            items[index].size = await Task.detached { Cleanup.size(of: target) }.value
            entries[path]?.buildFolders = items
        }
    }

    /// Writes `sdk.dir` to the project's local.properties.
    func writeLocalProperties(_ path: String, sdkPath: String) throws {
        guard let project = entries[path]?.report?.project else { return }
        try project.writeLocalSDKDir(sdkPath)
    }
}

extension AndroidProject {
    var symbolName: String {
        switch framework {
        case .reactNative: "atom"
        case .flutter: "bird"
        case .android: "hammer"
        }
    }

    /// The project folder's name, which reads better than package.json's lowercase name.
    var folderName: String { (root as NSString).lastPathComponent }

    /// "React Native 0.85.3 · Expo · Gradle 9.3.1", "Flutter 3.47.5 · Gradle 9.3.1"
    var summary: String {
        let framework: String? = switch self.framework {
        case .reactNative: reactNativeVersion.map { "React Native \($0)" } ?? "React Native"
        case .flutter: flutterVersion.map { "Flutter \($0)" } ?? "Flutter"
        case .android: nil
        }
        let parts = [framework, isExpo ? "Expo" : nil, gradleVersion.map { "Gradle \($0)" }]
        let text = parts.compactMap(\.self).joined(separator: " · ")
        return text.isEmpty ? "Android project" : text
    }
}
