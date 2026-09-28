import AndroidKit
import SwiftUI

struct ToolsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            if !model.agents.outdated.isEmpty {
                SkillUpdateBanner()
            }
            PanelSection("Setup") {
                DrillRow(
                    model.setup.isRunning ? "Setting Up…" : "Set Up Android Development",
                    subtitle: "Install or repair the JDK, SDK tools, packages and shell environment.",
                    systemImage: "wand.and.stars"
                ) { panel.push(.setup) }
            }
            ProjectsSection()
            JavaSection()
            EnvironmentSection()
            MaintenanceSection()
            PanelSection("Coding Agents") {
                DrillRow(
                    "Command-Line Tool & Agent Skill",
                    subtitle: agentsSubtitle,
                    systemImage: "sparkles"
                ) { panel.push(.agents) }
            }
        }
    }

    private var agentsSubtitle: String {
        let installed = model.agents.entries.filter { $0.state == .current || $0.state == .outdated }.map(\.target.name)
        guard !installed.isEmpty else { return "Let Claude Code, Codex and other agents manage emulators and the SDK." }
        return "Skill installed for \(ListFormatter.localizedString(byJoining: installed))."
    }
}

/// Shown after an app update when installed copies of the agent skill are older than this version's.
private struct SkillUpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelRow {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Skill Update")
                Text("The copy installed for \(ListFormatter.localizedString(byJoining: model.agents.outdated.map(\.target.name))) is from an older version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Update") { model.agents.updateAll() }
                .controlSize(.small)
        }
        .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
    }
}

// MARK: - Projects

private struct ProjectsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        PanelSection("Projects") {
            ForEach(model.projects.recents, id: \.self) { path in
                ProjectRow(path: path)
            }
            Button { chooseProject() } label: {
                PanelRow {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check a Project…")
                        if model.projects.recents.isEmpty {
                            Text("React Native or Flutter: see whether it has the SDK, NDK, build tools and JDK it needs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.row)
        }
    }

    private func chooseProject() {
        guard let url = panel.chooseFolder(title: "Choose a React Native or Flutter Project", startingAt: model.projects.recents.first.map { ($0 as NSString).deletingLastPathComponent }) else { return }
        panel.push(.project(url.path))
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let path: String

    var body: some View {
        let entry = model.projects.entry(path)
        DrillRow(
            (path as NSString).lastPathComponent,
            subtitle: subtitle(entry),
            systemImage: entry.report?.project.symbolName ?? "folder"
        ) {
            if let status = entry.report?.status {
                StatusIcon(status: status)
            }
        } action: {
            panel.push(.project(path))
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Remove from List") { model.projects.forget(path) }
        }
    }

    private func subtitle(_ entry: ProjectStore.Entry) -> String {
        guard let report = entry.report else { return abbreviatedPath(path) }
        let problems = report.checks.filter { $0.status != .ok }.count
        return problems == 0 ? "\(report.project.summary) · Ready" : "\(report.project.summary) · \(problems) to fix"
    }
}

// MARK: - Java

private struct JavaSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let installations = model.report?.java.installations ?? []
        PanelSection("Java") {
            ForEach(installations) { java in
                JavaRow(java: java)
            }
            if let install = model.java.install {
                PanelRow {
                    ProgressView().controlSize(.small).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installing JDK \(install.major)")
                        if let fraction = install.fraction {
                            ProgressView(value: fraction).controlSize(.small)
                                .accessibilityLabel("Installing JDK \(install.major)")
                        }
                        Text(install.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    IconButton("xmark", help: "Cancel") { model.java.cancel() }
                }
            } else {
                Menu {
                    ForEach(JDKInstaller.installableMajors, id: \.self) { major in
                        Button(major == JDKInstaller.recommendedMajor ? "JDK \(major) (Recommended)" : "JDK \(major)") {
                            model.java.install(major: major)
                        }
                    }
                } label: {
                    PanelRow {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text("Install a JDK")
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.row)
                .menuIndicator(.hidden)
            }
            if let failure = model.java.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct JavaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let java: JavaInstallation

    private var usedByTerminals: Bool { AppModel.sameJDK(model.environment["JAVA_HOME"], java.home) }
    private var usedByApp: Bool { model.report?.java.selected?.home == java.home }
    private var isTooOld: Bool { (java.majorVersion ?? 0) < JavaLocator.minimumMajorVersion }

    var body: some View {
        PanelRow {
            Image(systemName: "cup.and.saucer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(java.majorVersion.map { "JDK \($0)" } ?? "JDK")
                    if usedByTerminals { Badge("Terminals").accessibilityLabel("Used in terminals") }
                    if usedByApp { Badge("App").accessibilityLabel("Used by Andyman") }
                }
                Text([java.name ?? java.vendor, java.version].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(java.home)
            }
            Spacer(minLength: 8)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More options for \(java.majorVersion.map { "JDK \($0)" } ?? "this JDK")")
        }
        .contextMenu { menuItems }
        .opacity(isTooOld ? 0.6 : 1)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Use in Terminals…") { confirmUseInTerminals() }
            .disabled(usedByTerminals || isTooOld)
        Button("Use in Andyman") { model.setJavaHomeOverride(java.home) }
            .disabled(isTooOld || model.javaHomeOverride == java.home)
        Divider()
        Button("Show in Finder") {
            // Reveal the .jdk bundle rather than its Contents/Home.
            let url = URL(fileURLWithPath: java.home)
            let bundle = url.path.hasSuffix("/Contents/Home") ? url.deletingLastPathComponent().deletingLastPathComponent() : url
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        }
    }

    private func confirmUseInTerminals() {
        let change = model.shellProfileChange(java: java)
        let profile = model.shell.profilePath
        panel.confirm(
            "Use \(java.majorVersion.map { "JDK \($0)" } ?? "this JDK") in terminals?",
            detail: (change.replacesExisting ? "Updates the Andyman block in \(profile)" : "Adds an Andyman block to \(profile)")
                + " (backed up first), setting JAVA_HOME, ANDROID_HOME and PATH. New terminal windows pick it up:\n\n"
                + change.block.dropFirst().dropLast().joined(separator: "\n"),
            confirmTitle: "Update \(profile)"
        ) {
            Task {
                model.java.failure = await model.writeShellProfile(java: java)
            }
        }
    }
}

struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: .capsule)
    }
}

// MARK: - Environment

private struct EnvironmentSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    @State private var copied = false
    @State private var fixProblem: String?

    /// The shell doesn't point at the SDK (ANDROID_HOME or PATH checks fail).
    private var needsShellFix: Bool {
        guard let report = model.report, report.sdk.location != nil else { return false }
        return report.checks.contains { $0.id.hasPrefix("env.") && $0.status != .ok }
    }

    var body: some View {
        PanelSection("Environment") {
            if model.isRefreshing && model.report == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking environment")
            } else {
                IconButton("arrow.clockwise", help: "Check Again") {
                    Task { await model.refresh(reloadShell: true) }
                }
                .disabled(model.isRefreshing)
            }
        } content: {
            if let report = model.report {
                ForEach(report.checks) { check in
                    CheckRow(check: check)
                }
            } else {
                PanelRow {
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
            if needsShellFix {
                Button { confirmFix() } label: {
                    PanelRow {
                        Image(systemName: "wand.and.rays")
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fix in \(model.shell.profilePath)…")
                            Text("Set ANDROID_HOME and PATH for terminals.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.row)
            }
            if let fixProblem {
                Text(fixProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            Button {
                model.copyShellExports()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                PanelRow {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copied ? "Copied" : "Copy Shell Exports")
                        Text("ANDROID_HOME, JAVA_HOME and PATH for \(model.shell.profilePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.row)
            .disabled(model.report?.sdk.location == nil)
        }
    }

    private func confirmFix() {
        let change = model.shellProfileChange()
        let profile = model.shell.profilePath
        panel.confirm(
            "Add the Android SDK to \(profile)?",
            detail: (change.replacesExisting ? "Updates the Andyman block" : "Adds these lines")
                + " (the file is backed up first). New terminal windows pick them up:\n\n"
                + change.block.dropFirst().dropLast().joined(separator: "\n"),
            confirmTitle: "Update \(profile)"
        ) {
            Task { fixProblem = await model.writeShellProfile() }
        }
    }
}

private struct CheckRow: View {
    let check: DoctorCheck

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
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let hint = check.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Maintenance

private struct MaintenanceSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: MaintenanceStore { model.maintenance }

    var body: some View {
        PanelSection("Maintenance") {
            PanelRow {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gradle Daemons")
                    Text(daemonSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.isStoppingDaemons {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Stopping daemons")
                } else if !store.daemons.isEmpty {
                    Button("Stop") { Task { await store.stopDaemons() } }
                        .controlSize(.small)
                        .help("Stop every Gradle and Kotlin daemon, freeing their memory. Builds in progress fail.")
                }
            }
            DrillRow(
                "Free Up Space",
                subtitle: store.totalSize.map { "\(formatBytes($0)) of caches, old Gradle versions and snapshots" }
                    ?? "Gradle caches, old Gradle versions, emulator snapshots, Metro",
                systemImage: "externaldrive.badge.minus"
            ) { panel.push(.cleanup) }
        }
        .task { await store.refreshDaemons() }
    }

    private var daemonSummary: String {
        guard store.hasLoadedDaemons else { return "Checking…" }
        guard !store.daemons.isEmpty else { return "None running" }
        let memory = ByteCountFormatter.string(fromByteCount: store.daemonMemory, countStyle: .memory)
        return "\(store.daemons.count) running · \(memory) of memory"
    }
}
