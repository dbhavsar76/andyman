import AndroidKit
import SwiftUI

/// "Project Doctor": what a React Native or Flutter project needs to build, what's missing, and fixes.
struct ProjectPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let path: String
    @State private var cleaned: String?

    private var entry: ProjectStore.Entry { model.projects.entry(path) }

    var body: some View {
        Group {
            if let report = entry.report {
                content(report)
            } else if let error = entry.error {
                VStack(spacing: 8) {
                    PanelPlaceholder(systemImage: "questionmark.folder", title: "Not an Android Project", message: error)
                    Button("Choose Another Folder…") { chooseAnother() }
                }
                .padding(.bottom, 12)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .accessibilityLabel("Checking project")
            }
        }
        // Re-check when packages are installed or removed, or the environment changes.
        .task(id: "\(model.sdk.installed.count)|\(model.emulators.devices.count)|\(model.report?.java.selected?.home ?? "")|\(model.environment["JAVA_HOME"] ?? "")") {
            await check()
        }
    }

    private func check() async {
        if model.sdk.catalog == nil { await model.sdk.loadCatalog() }
        await model.projects.check(path, context: model.projectContext)
        if model.projects.entry(path).report != nil { model.projects.remember(path) }
    }

    private func chooseAnother() {
        guard let url = panel.chooseFolder(title: "Choose a React Native or Flutter Project", startingAt: (path as NSString).deletingLastPathComponent) else { return }
        panel.pop()
        panel.push(.project(url.path))
    }

    private func content(_ report: ProjectReport) -> some View {
        let project = report.project
        let missing = report.missingPackages
        return VStack(spacing: PanelMetrics.sectionSpacing) {
            summary(report)

            if let failure = model.sdk.failure {
                NoticeRow(systemImage: "exclamationmark.triangle.fill", title: "Couldn't install", message: failure) { model.sdk.failure = nil }
            }

            PanelSection("Requirements") {
                if entry.isChecking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking requirements")
                } else {
                    IconButton("arrow.clockwise", help: "Check Again") {
                        Task { await model.refresh(reloadShell: true); await check() }
                    }
                }
            } content: {
                ForEach(report.checks) { check in
                    RequirementRow(check: check, path: path)
                }
            }

            if missing.count > 1, !missing.allSatisfy({ model.sdk.queueItem($0) != nil }) {
                VStack(spacing: 6) {
                    Button {
                        if model.sdk.install(missing) { panel.push(.sdkLicenses) }
                    } label: {
                        Text("Install All Missing").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let size = downloadSize(missing) {
                        Text("\(formatBytes(size)) to download")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let cleaned {
                NoticeRow(systemImage: "checkmark.circle.fill", title: cleaned, message: "The next build recreates them.") { self.cleaned = nil }
            }
            if !entry.buildFolders.isEmpty {
                PanelSection("Clean Build") {
                    ForEach(entry.buildFolders) { item in
                        BuildFolderRow(item: item, projectName: project.folderName) {
                            Task {
                                if let freed = await model.maintenance.clean([item.target]) {
                                    cleaned = "Freed \(formatBytes(freed))."
                                } else if let failure = model.maintenance.failure {
                                    model.sdk.failure = failure
                                }
                                await check()
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ report: ProjectReport) -> some View {
        let project = report.project
        return PanelSection("Project") {
            switch project.framework {
            case .reactNative:
                InfoRow("React Native", value: project.reactNativeVersion.map { project.isExpo ? "\($0) (Expo)" : $0 } ?? "–")
            case .flutter:
                InfoRow("Flutter", value: project.flutterVersion ?? "–")
            case .android:
                EmptyView()
            }
            if let gradle = project.gradleVersion {
                InfoRow("Gradle", value: gradle)
            }
            InfoRow("Android SDK", value: sdkLevels(project))
            if let architectures = project.architectures {
                InfoRow("Builds For", value: architectures.joined(separator: ", "))
            }
            PanelRow {
                Text("Folder")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(abbreviatedPath(project.root))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(project.root)
                IconButton("folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.root)])
                }
            }
        }
    }

    private func sdkLevels(_ project: AndroidProject) -> String {
        let parts = [
            project.compileSdk.map { "compile \($0.value)" },
            project.targetSdk.map { "target \($0.value)" },
            project.minSdk.map { "min \($0.value)" },
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    private func downloadSize(_ ids: [String]) -> Int64? {
        guard let catalog = model.sdk.catalog else { return nil }
        let sizes = ids.compactMap { catalog.latest($0, channel: .canary)?.archive?.size }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// A requirement with its status and, when something's wrong, a button that fixes it.
private struct RequirementRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let check: ProjectCheck
    let path: String

    var body: some View {
        PanelRow {
            StatusIcon(status: check.status)
                .frame(width: 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = check.hint, check.status != .ok {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let fix = check.fix {
                fixControl(fix)
            }
        }
    }

    @ViewBuilder private func fixControl(_ fix: ProjectFix) -> some View {
        switch fix {
        case let .installPackages(ids):
            if let item = ids.lazy.compactMap({ model.sdk.queueItem($0) }).first {
                QueueStatus(item: item)
            } else {
                Button("Install") {
                    if model.sdk.install(ids) { panel.push(.sdkLicenses) }
                }
                .controlSize(.small)
            }
        case let .writeLocalProperties(sdkPath):
            Button("Fix…") { confirmLocalProperties(sdkPath) }
                .controlSize(.small)
        case let .installJDK(major), let .useJDK(major):
            if let install = model.java.install, install.major == major {
                ProgressView().controlSize(.small).help(install.detail)
                    .accessibilityLabel("Installing JDK \(major)")
            } else if let java = model.report?.java.installations.first(where: { $0.majorVersion == major }) {
                Button("Use JDK \(major)…") { confirmUseJDK(java) }
                    .controlSize(.small)
            } else {
                Button("Install JDK \(major)") { model.java.install(major: major) }
                    .controlSize(.small)
            }
        }
    }

    private func confirmLocalProperties(_ sdkPath: String) {
        panel.confirm(
            "Point this project at \(abbreviatedPath(sdkPath))?",
            detail: "Writes sdk.dir=\(sdkPath) to android/local.properties, which Gradle reads before ANDROID_HOME. The file is machine-specific and not committed.",
            confirmTitle: "Write File"
        ) {
            do {
                try model.projects.writeLocalProperties(path, sdkPath: sdkPath)
                Task { await model.projects.check(path, context: model.projectContext) }
            } catch {
                model.sdk.failure = error.localizedDescription
            }
        }
    }

    private func confirmUseJDK(_ java: JavaInstallation) {
        let change = model.shellProfileChange(java: java)
        let profile = model.shell.profilePath
        panel.confirm(
            "Use \(java.displayName) in terminals?",
            detail: "Sets JAVA_HOME in \(profile) (backed up first), so Gradle uses it. New terminal windows pick it up:\n\n"
                + change.block.dropFirst().dropLast().joined(separator: "\n"),
            confirmTitle: "Update \(profile)"
        ) {
            Task {
                if let problem = await model.writeShellProfile(java: java) {
                    model.sdk.failure = problem
                }
            }
        }
    }
}

private struct QueueStatus: View {
    let item: SDKStore.QueueItem

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = item.state.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .help(item.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Installing \(item.displayName)")
    }
}

private struct BuildFolderRow: View {
    @Environment(PanelState.self) private var panel
    @Environment(AppModel.self) private var model
    let item: MaintenanceStore.Item
    let projectName: String
    let clean: () -> Void

    var body: some View {
        PanelRow {
            Image(systemName: item.target.kind == .projectLibraries ? "shippingbox" : "hammer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.target.title)
                Text(item.target.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let size = item.size {
                Button("Clean \(formatBytes(size))") { confirm(size) }
                    .controlSize(.small)
                    .disabled(model.maintenance.isCleaning || size == 0)
                    .fixedSize()
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Measuring size")
            }
        }
    }

    private func confirm(_ size: Int64) {
        let what = item.target.kind == .projectLibraries ? "the native libraries' build folders" : "the Android build folders"
        let daemons = model.maintenance.daemons.isEmpty ? "" : " Running Gradle daemons are stopped first."
        panel.confirm(
            "Delete \(what) of \(projectName)?",
            detail: "Frees \(formatBytes(size)). The next build rebuilds everything, so it takes longer.\(daemons)",
            confirmTitle: "Delete",
            destructive: true,
            onConfirm: clean
        )
    }
}
