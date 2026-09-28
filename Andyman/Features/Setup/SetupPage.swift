import AndroidKit
import SwiftUI

/// "Set Up Android Development": choose what to install, watch it happen, see the result.
struct SetupPage: View {
    @Environment(AppModel.self) private var model

    private var setup: SetupStore { model.setup }

    var body: some View {
        Group {
            switch setup.phase {
            case .configuring:
                SetupOptionsView()
            case .running:
                SetupProgressView()
            case .finished:
                SetupFinishedView()
            case let .failed(message):
                SetupFailedView(message: message)
            }
        }
        .task { if setup.plan == nil { await setup.makePlan() } }
    }
}

// MARK: - Options

private struct SetupOptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var setup: SetupStore { model.setup }

    var body: some View {
        @Bindable var setup = setup
        let plan = setup.plan
        VStack(spacing: PanelMetrics.sectionSpacing) {
            Text("Installs everything needed to build and run Android apps, without Android Studio. Anything already installed is skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            PanelSection("On This Mac") {
                StatusLine(
                    title: "Java",
                    done: plan?.existingJava != nil,
                    detail: plan?.existingJava?.displayName ?? plan?.jdk.map { "Temurin \($0.version) · \(formatBytes($0.size))" } ?? "Not installed"
                )
                StatusLine(
                    title: "Command-line Tools",
                    done: plan.map { !$0.bootstrapTools } ?? false,
                    detail: plan.map { $0.bootstrapTools ? "To install · \(formatBytes($0.toolsSize))" : "Installed" } ?? "Checking…"
                )
                StatusLine(
                    title: "SDK Packages",
                    done: plan?.install.isEmpty ?? false,
                    detail: plan.map { $0.install.isEmpty ? "All installed" : "\($0.install.packages.count) to install" } ?? "Checking…"
                )
                if let packages = plan?.install.packages, !packages.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(packages, id: \.id) { package in
                            PackageLine(package: package)
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
            }

            PanelSection("SDK Location") {
                PanelRow {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(setup.sdkPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(setup.sdkPath)
                    Spacer(minLength: 8)
                    Button("Change…") {
                        if let url = panel.chooseFolder(title: "Choose Where to Put the Android SDK", startingAt: setup.sdkPath) {
                            setup.sdkPath = url.path
                        }
                    }
                    .controlSize(.small)
                }
            }

            if plan?.existingJava == nil {
                PanelSection("Java") {
                    PanelRow {
                        Text("Install")
                        Spacer()
                        Picker("JDK", selection: $setup.jdkMajor) {
                            ForEach(JDKInstaller.offeredMajors, id: \.self) { major in
                                Text(major == JDKInstaller.recommendedMajor ? "JDK \(major) (Recommended)" : "JDK \(major)").tag(major)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Caption("Eclipse Temurin, free and open source. Gradle and the SDK tools need it.")
                }
            }

            PanelSection("Packages") {
                ForEach(setup.presets) { preset in
                    PresetRow(preset: preset, isSelected: setup.presetID == preset.id) {
                        setup.presetID = preset.id
                    }
                }
                if setup.presets.contains(where: { $0.requirements?.isFallback == true }), !setup.isPlanning {
                    Caption("Couldn't check for newer React Native and Flutter releases, so these are the versions built into the app.")
                }
            }

            PanelSection("Also") {
                PanelRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create an Emulator")
                        Text(emulatorDetail(plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Shown off when the preset has no image to run, whatever the saved choice.
                    Toggle("Create an Emulator", isOn: Binding(
                        get: { setup.createEmulator && setup.options.emulatorImage != nil },
                        set: { setup.createEmulator = $0 }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(setup.options.emulatorImage == nil)
                }
                PanelRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to \(setup.shellProfilePath)")
                        Text("Sets ANDROID_HOME, JAVA_HOME and PATH for terminals. Backed up first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Add to shell profile", isOn: $setup.writeShellProfile)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if setup.writeShellProfile, let change = plan?.shellChange {
                    Text(change.block.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quinary, in: .rect(cornerRadius: 8))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                } else if setup.writeShellProfile, plan != nil {
                    Caption("\(setup.shellProfilePath) is already set up.")
                }
            }

            if let error = setup.planError {
                NoticeRow(systemImage: "wifi.exclamationmark", title: "Couldn't prepare setup", message: error)
            }

            VStack(spacing: 8) {
                Button {
                    if setup.start() { panel.push(.setupLicenses) }
                } label: {
                    HStack(spacing: 8) {
                        if setup.isPlanning { ProgressView().controlSize(.small) }
                        Text(startTitle(plan))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || setup.isPlanning)

                if let plan, plan.downloadSize > 0 {
                    Text("\(formatBytes(plan.downloadSize)) to download in total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func startTitle(_ plan: SetupPlan?) -> String {
        guard let plan else { return "Preparing…" }
        return plan.steps == [.verify] ? "Check Setup" : "Start Setup"
    }

    private func emulatorDetail(_ plan: SetupPlan?) -> String {
        if setup.options.emulatorImage == nil { return "This preset doesn't include a system image." }
        if plan?.existingJava == nil && plan?.jdk == nil { return "Needs Java." }
        return "A Medium Phone running the preset's system image."
    }
}

private struct StatusLine: View {
    let title: String
    let done: Bool
    let detail: String

    var body: some View {
        PanelRow {
            Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .frame(width: 18)
                .accessibilityLabel(done ? "Installed" : "To install")
            Text(title)
            Spacer(minLength: 8)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A package setup will download, listed under "SDK Packages".
private struct PackageLine: View {
    let package: RemotePackage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(package.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(package.id)
            Spacer(minLength: 8)
            if let size = package.archive?.size {
                Text(formatBytes(size))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PresetRow: View {
    let preset: SetupPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 15))
                    .frame(width: 18)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.row)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }
}

// MARK: - Progress

private struct SetupProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        VStack(spacing: PanelMetrics.sectionSpacing) {
            PanelSection("Setting Up") {
                ForEach(setup.plan?.steps ?? [], id: \.self) { step in
                    StepRow(step: step, state: setup.steps[step] ?? .pending)
                }
            }
            Text("You can close this panel; setup keeps going and the menu bar icon shows progress.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            Button("Cancel") { setup.cancel() }
                .controlSize(.large)
        }
    }
}

private struct StepRow: View {
    let step: SetupStep
    let state: SetupStore.StepState

    var body: some View {
        PanelRow {
            Group {
                switch state {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .frame(width: 18)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stateLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                switch state {
                case let .running(detail, fraction):
                    if let fraction {
                        ProgressView(value: fraction).controlSize(.small)
                            .accessibilityLabel(step.title)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                case let .done(summary):
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .pending:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: state)
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String {
        switch state {
        case .pending: "Pending"
        case .running: "In progress"
        case .done: "Done"
        }
    }
}

// MARK: - Result

private struct SetupFinishedView: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let setup = model.setup
        let result = setup.result
        let ok = result?.report.status != .error
        VStack(spacing: PanelMetrics.sectionSpacing) {
            VStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(ok ? .green : .orange)
                    .accessibilityHidden(true)
                Text(ok ? "Android Development Is Ready" : "Almost There")
                    .font(.headline)
                Text(ok ? "Everything's installed." : "Some checks still need attention. See Tools for details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            PanelSection("Done") {
                ForEach(setup.plan?.steps ?? [], id: \.self) { step in
                    StepRow(step: step, state: setup.steps[step] ?? .pending)
                }
            }

            if result?.shellBackup != nil || setup.plan?.shellChange != nil {
                NoticeRow(
                    systemImage: "terminal",
                    title: "Open a new terminal window",
                    message: "Terminals that were already open won't see the new ANDROID_HOME and PATH."
                )
            }

            HStack(spacing: 10) {
                Button {
                    setup.reset()
                    panel.popToRoot()
                    panel.tab = .emulators
                } label: {
                    Text(result?.emulator != nil ? "Show Emulators" : "Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct SetupFailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            NoticeRow(systemImage: "xmark.octagon.fill", title: "Setup stopped", message: message)
            if let steps = model.setup.plan?.steps {
                PanelSection("Progress") {
                    ForEach(steps, id: \.self) { step in
                        StepRow(step: step, state: model.setup.steps[step] ?? .pending)
                    }
                }
            }
            Text("Finished steps are kept. Trying again picks up where it stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try Again") { model.setup.reset() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// Licenses setup needs, reviewed before anything is downloaded.
struct SetupLicensePage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let setup = model.setup
        if setup.pendingLicenses.isEmpty {
            PanelPlaceholder(systemImage: "checkmark.seal", title: "Nothing to Accept", message: "Setup doesn't need any more licenses.")
        } else {
            LicenseReview(
                summary: "Setting up the Android SDK",
                licenses: setup.pendingLicenses,
                acceptTitle: "Accept & Start",
                onDecline: {
                    setup.declineLicenses()
                    panel.pop()
                },
                onAccept: {
                    setup.acceptLicensesAndStart()
                    panel.pop()
                }
            )
        }
    }
}
