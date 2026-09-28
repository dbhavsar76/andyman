import AndroidKit
import SwiftUI

/// "Agents": put andyman on PATH and install the skill that teaches coding agents to use it.
struct AgentsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: AgentsStore { model.agents }

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            Text("Let coding agents like Claude Code and Codex start emulators, install SDK packages and diagnose Android builds for you, through the andyman command.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            if let notice = store.notice {
                NoticeRow(systemImage: "checkmark.circle.fill", title: notice, message: "") { store.notice = nil }
            }
            if let failure = store.failure ?? store.loadError {
                NoticeRow(systemImage: "exclamationmark.triangle.fill", title: "Something went wrong", message: failure) {
                    store.failure = nil
                }
            }

            commandLineSection
            skillSection
            shareSection
        }
        .task { await store.refresh(environment: model.environment) }
    }

    // MARK: - Command-line tool

    private var commandLineSection: some View {
        PanelSection("Command-Line Tool") {
            PanelRow {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("andyman")
                        .font(.body.monospaced())
                    Text(cliSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                switch store.cliStatus {
                case .installed:
                    Button("Remove") { store.uninstallCLI() }
                        .controlSize(.small)
                case .notInstalled, .otherCopy:
                    Button("Install") { store.installCLI(environment: model.environment) }
                        .controlSize(.small)
                case .conflict:
                    EmptyView()
                }
            }
            if store.cliStatus == .installed && !store.cliOnPath {
                Button { confirmPathFix() } label: {
                    PanelRow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add ~/.local/bin to PATH…")
                            Text("It isn't on your PATH yet, so terminals won't find andyman.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.row)
            }
        }
    }

    private var cliSubtitle: String {
        switch store.cliStatus {
        case .installed: store.cliOnPath ? "In ~/.local/bin. Try andyman doctor in a terminal." : "Linked in ~/.local/bin."
        case .notInstalled: "Links it into ~/.local/bin (no admin password needed)."
        case let .otherCopy(path): "~/.local/bin/andyman points to another copy (\(abbreviatedPath(path))). Install to use this one."
        case .conflict: "~/.local/bin/andyman is a different program, so it's left alone."
        }
    }

    private func confirmPathFix() {
        let change = model.shellProfileChange()
        let profile = model.shell.profilePath
        panel.confirm(
            "Add ~/.local/bin to PATH in \(profile)?",
            detail: (change.replacesExisting ? "Updates the Andyman block" : "Adds these lines")
                + " (the file is backed up first). New terminal windows pick them up:\n\n"
                + change.block.dropFirst().dropLast().joined(separator: "\n"),
            confirmTitle: "Update \(profile)"
        ) {
            Task {
                store.failure = await model.writeShellProfile()
                await store.refresh(environment: model.environment)
            }
        }
    }

    // MARK: - Skill

    private var skillSection: some View {
        PanelSection("Agent Skill") {
            if let version = store.skillVersion {
                Text(version.components(separatedBy: "+").first.map { "v\($0)" } ?? version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Skill version \(version)")
            }
        } content: {
            ForEach(store.visibleEntries) { entry in
                SkillTargetRow(entry: entry)
            }
            Button { installInProject() } label: {
                PanelRow {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install in a Project…")
                        Text("Adds it to the project's .claude/skills and .agents/skills, to commit for your team.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.row)
            .disabled(store.skill == nil)
        }
    }

    private func installInProject() {
        guard let url = panel.chooseFolder(title: "Choose a Project to Add the Skill To", startingAt: model.projects.recents.first) else { return }
        store.install(inProject: url)
    }

    // MARK: - Share

    private var shareSection: some View {
        PanelSection("Share") {
            ActionRow("Copy Skill", systemImage: "doc.on.doc") { store.copySkill() }
                .disabled(store.skill == nil)
            ActionRow("Save Skill To…", systemImage: "square.and.arrow.down") {
                if let url = panel.chooseFolder(title: "Choose a Skills Folder", startingAt: nil) { store.save(to: url) }
            }
            .disabled(store.skill == nil)
            ActionRow("Copy AGENTS.md Snippet", systemImage: "text.badge.plus") { store.copyAgentsSnippet() }
                .disabled(store.agentsSnippet == nil)
        }
    }
}

private struct SkillTargetRow: View {
    @Environment(AppModel.self) private var model
    let entry: AgentsStore.Entry

    private var store: AgentsStore { model.agents }

    var body: some View {
        PanelRow {
            Image(systemName: symbol)
                .foregroundStyle(entry.state == .current ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.target.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(entry.state == .outdated ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(AgentSkills.skillFile(in: AgentSkills.userSkillsFolder(entry.target)).path)
            }
            Spacer(minLength: 8)
            switch entry.state {
            case .notInstalled:
                Button("Install") { store.install(entry.target) }
                    .controlSize(.small)
                    .disabled(store.skill == nil)
            case .outdated:
                Button("Update") { store.install(entry.target) }
                    .controlSize(.small)
                    .disabled(store.skill == nil)
            case .current:
                Menu {
                    Button("Show in Finder") { store.showInFinder(entry.target) }
                    Button("Remove", role: .destructive) { store.uninstall(entry.target) }
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
                .accessibilityLabel("More options for \(entry.target.name)")
            case .foreign:
                EmptyView()
            }
        }
    }

    private var symbol: String {
        switch entry.state {
        case .current: "checkmark.circle.fill"
        case .outdated: "arrow.triangle.2.circlepath"
        default: "sparkles"
        }
    }

    private var subtitle: String {
        let folder = abbreviatedPath(AgentSkills.userSkillsFolder(entry.target).path)
        return switch entry.state {
        case .current: "Installed · \(folder)"
        case .outdated: "Update available · \(folder)"
        case .notInstalled: folder
        case .foreign: "A different skill named \(AgentSkills.skillName) is there"
        }
    }
}
