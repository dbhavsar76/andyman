import AndroidKit
import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var notificationsEnabled = Notifier.shared.isEnabled
    @State private var notificationsBlocked = false

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            sdkSection
            packagesSection
            javaSection
            generalSection
            PanelSection("Coding Agents") {
                DrillRow("Command-Line Tool & Agent Skill", systemImage: "sparkles") { panel.push(.agents) }
            }
            aboutSection
        }
        .task {
            // Re-checked while Settings is showing, so the notice goes away once the user
            // allows notifications in System Settings.
            while !Task.isCancelled {
                notificationsBlocked = await Notifier.shared.isBlockedBySystem()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Android SDK

    private var sdkSection: some View {
        PanelSection("Android SDK") {
            PanelRow {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let location = model.report?.sdk.location {
                        Text(location.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(location.path)
                        Text(location.source.displayName.capitalizedFirst)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No SDK found")
                        Text("Choose the folder that contains platform-tools and emulator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            PanelRow {
                Spacer()
                if model.sdkPathOverride != nil {
                    Button("Use Automatic") { model.setSDKPathOverride(nil) }
                }
                Button("Choose…") {
                    if let url = panel.chooseFolder(title: "Choose Android SDK Folder", startingAt: model.report?.sdk.location?.path) {
                        model.setSDKPathOverride(url.path)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Packages

    private var packagesSection: some View {
        PanelSection("SDK Packages") {
            PanelRow {
                Text("Release Channel")
                Spacer()
                Picker("Release Channel", selection: Binding(get: { model.sdk.channel }, set: { model.sdk.setChannel($0) })) {
                    Text("Stable").tag(PackageChannel.stable)
                    Text("Beta").tag(PackageChannel.beta)
                    Text("Dev").tag(PackageChannel.dev)
                    Text("Canary").tag(PackageChannel.canary)
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Preview channels offer newer emulators, NDKs and system images before they're stable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Java

    private var javaSection: some View {
        PanelSection("Java") {
            PanelRow {
                Image(systemName: "cup.and.heat.waves")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Picker("JDK", selection: javaSelection) {
                    Text(automaticJavaLabel).tag(String?.none)
                    if let installations = model.report?.java.installations, !installations.isEmpty {
                        Divider()
                        ForEach(installations) { java in
                            Text(java.displayName).tag(Optional(java.home))
                        }
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
            }
            Text("Used to run sdkmanager and avdmanager. Needs JDK \(JavaLocator.minimumMajorVersion) or newer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
    }

    private var javaSelection: Binding<String?> {
        Binding(
            get: { model.javaHomeOverride },
            set: { model.setJavaHomeOverride($0) }
        )
    }

    private var automaticJavaLabel: String {
        guard model.javaHomeOverride == nil, let selected = model.report?.java.selected else { return "Automatic" }
        return "Automatic (\(selected.displayName))"
    }

    // MARK: - General

    private var generalSection: some View {
        PanelSection("General") {
            PanelRow {
                Text("Open at Login")
                Spacer()
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            PanelRow {
                Text("Notifications")
                Spacer()
                Toggle("Notifications", isOn: $notificationsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: notificationsEnabled) { _, enabled in Notifier.shared.isEnabled = enabled }
            }
            Text("When installs or setup finish, or an emulator boots or quits unexpectedly, while the panel is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            if notificationsEnabled, notificationsBlocked {
                HStack(alignment: .firstTextBaseline) {
                    Text("Notifications are turned off for Andyman in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open System Settings") { Notifier.shared.openSystemSettings() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            PanelRow {
                Text("Keyboard Shortcut")
                Spacer()
                ShortcutRecorder()
                    .controlSize(.small)
            }
            Text("Opens or closes the panel from any app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        PanelSection("About") {
            PanelRow {
                Text("Andyman")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                PanelRow {
                    Text("Quit Andyman")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.row)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
