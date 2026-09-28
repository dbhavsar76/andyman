import AndroidKit
import SwiftUI

struct EmulatorsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: EmulatorStore { model.emulators }

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            if model.report?.checks.first(where: { $0.id == "sdk.location" })?.status == .error {
                SetupNeededBanner { panel.push(.setup) }
            }
            if let failure = store.failure {
                FailureBanner(failure: failure) { store.failure = nil }
            }
            if let notice = store.notice {
                NoticeBanner(notice: notice) { store.notice = nil }
            }
            if !store.issues.isEmpty {
                PanelSection("Needs Attention") {
                    ForEach(store.issues) { issue in
                        IssueRow(issue: issue)
                    }
                }
            }

            if store.devices.isEmpty {
                if store.hasLoaded {
                    VStack(spacing: 4) {
                        PanelPlaceholder(
                            systemImage: "smartphone",
                            title: "No Virtual Devices",
                            message: "Create one to run your app in the emulator."
                        )
                        Button("Create Virtual Device…") { startNewDevice() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canCreate)
                    }
                    .padding(.bottom, 12)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityLabel("Loading virtual devices")
                }
            } else {
                PanelSection("Virtual Devices") {
                    IconButton("plus", help: "New Virtual Device") { startNewDevice() }
                        .disabled(!store.canCreate)
                } content: {
                    ForEach(store.devices) { device in
                        EmulatorRow(device: device)
                    }
                }
            }
        }
    }
}

extension EmulatorsTab {
    private func startNewDevice() {
        store.beginNewDevice()
        panel.push(.newDeviceProfile)
    }
}

// MARK: - Rows

private struct EmulatorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: VirtualDevice
    @State private var isHovered = false
    @State private var isDropTarget = false

    private var store: EmulatorStore { model.emulators }
    private var state: EmulatorStore.DeviceState { store.state(of: device) }

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(device: device, state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleStyle)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            PrimaryAction(device: device, state: state)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: PanelMetrics.rowCornerRadius, style: .continuous)
                .fill(.quaternary)
                .opacity(isHovered ? 1 : 0)
        }
        .overlay {
            // Drop an APK on a running emulator to install it.
            RoundedRectangle(cornerRadius: PanelMetrics.rowCornerRadius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .onTapGesture { panel.push(.emulator(device.name)) }
        .contextMenu { EmulatorActionsMenu(device: device) }
        .dropDestination(for: URL.self) { urls, _ in
            let apks = EmulatorStore.apks(in: urls)
            guard state == .running, !apks.isEmpty else { return false }
            apks.forEach { store.run(.install($0), on: device) }
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted && state == .running
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { panel.push(.emulator(device.name)) }
        .accessibilityAction(named: "Show Details") { panel.push(.emulator(device.name)) }
    }

    private var subtitle: String {
        if let action = store.actionsInProgress[device.name] { return action }
        return switch state {
        case .starting: "Starting…"
        case .booting: "Booting…"
        case .running: store.instance(of: device).map { "Running · \($0.serial)" } ?? "Running"
        case .stopping: "Stopping…"
        case let .unavailable(reason): reason
        case .stopped: device.summary
        }
    }

    private var subtitleStyle: AnyShapeStyle {
        switch state {
        case .running: AnyShapeStyle(.green)
        case .unavailable: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.secondary)
        }
    }
}

/// Form-factor symbol with a small status dot while the emulator is active.
struct DeviceIcon: View {
    let device: VirtualDevice
    let state: EmulatorStore.DeviceState
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: device.formFactor.symbolName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(state.isActive ? .primary : .secondary)
            .frame(width: size + 6, height: size + 6)
            .overlay(alignment: .bottomTrailing) {
                if state.isActive {
                    Circle()
                        .fill(state == .running ? Color.green : Color.orange)
                        .frame(width: size * 0.45, height: size * 0.45)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: state)
            .accessibilityHidden(true)
    }
}

/// Start / stop button, or a spinner while a transition is in progress.
private struct PrimaryAction: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let state: EmulatorStore.DeviceState

    var body: some View {
        Group {
            switch state {
            case .stopped:
                IconButton("play.fill", help: "Start \(device.displayName)") { model.emulators.start(device) }
            case .booting, .running:
                IconButton("stop.fill", help: "Stop \(device.displayName)") { model.emulators.stop(device) }
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(state == .starting ? "Starting" : "Stopping")
            case let .unavailable(reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 26, height: 26)
                    .help("Can't start: \(reason)")
                    .accessibilityLabel("Can't start: \(reason)")
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: state)
    }
}

/// Launch and management actions, shared by the row's context menu and the status item menu.
struct EmulatorActionsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: VirtualDevice

    private var store: EmulatorStore { model.emulators }

    var body: some View {
        let state = store.state(of: device)
        if state.isActive {
            Button("Stop") { store.stop(device) }
                .disabled(state == .stopping || state == .starting)
            if state == .running {
                QuickActionsMenuItems(device: device)
            }
        } else {
            Button("Start") { store.start(device) }
            Button("Cold Boot") { store.start(device, options: .init(coldBoot: true)) }
            Button("Start Without Window") { store.start(device, options: .init(headless: true)) }
        }
        Divider()
        Button("Show Details") { panel.push(.emulator(device.name)) }
        Button("Edit…") { panel.push(.editEmulator(device.name)) }
            .disabled(state.isActive)
        Button("Duplicate") { duplicate(device, store: store, panel: panel) }
            .disabled(state.isActive)
        Button("Show in Finder") { store.showInFinder(device) }
        Button("Open Log") { store.openLog(device) }
            .disabled(!store.hasLog(device))
        Divider()
        Button("Wipe Data…") { confirmWipe(device, store: store, panel: panel) }
            .disabled(state.isActive)
        Button("Move to Trash…", role: .destructive) { confirmDelete(device, store: store, panel: panel) }
            .disabled(state.isActive)
    }
}

@MainActor func duplicate(_ device: VirtualDevice, store: EmulatorStore, panel: PanelState) {
    do {
        let copy = try store.duplicate(device)
        panel.push(.emulator(copy.name))
    } catch {
        store.failure = .init(message: error.localizedDescription)
    }
}

@MainActor func confirmWipe(_ device: VirtualDevice, store: EmulatorStore, panel: PanelState) {
    panel.confirm(
        "Wipe data on \(device.displayName)?",
        detail: "Apps, settings and files on this device are erased, and its next start is a fresh cold boot.",
        confirmTitle: "Wipe Data",
        destructive: true
    ) {
        store.wipeData(device)
    }
}

@MainActor func confirmDelete(_ device: VirtualDevice, store: EmulatorStore, panel: PanelState) {
    panel.confirm(
        "Move \(device.displayName) to the Trash?",
        detail: "Its files are moved to the Trash, so you can restore them until you empty it.",
        confirmTitle: "Move to Trash",
        destructive: true
    ) {
        if panel.pages.last == .emulator(device.name) { panel.pop() }
        store.delete(device)
    }
}

private struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: AVDIssue

    var body: some View {
        PanelRow {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(width: 22)
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.name.replacingOccurrences(of: "_", with: " "))
                    .lineLimit(1)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(issue.fixTitle) { model.emulators.fix(issue) }
                .controlSize(.small)
        }
    }
}

/// React Native helpers for a running emulator, as menu items.
struct QuickActionsMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: VirtualDevice

    var body: some View {
        let store = model.emulators
        Divider()
        Button("Open Developer Menu") { store.run(.devMenu, on: device) }
        Button("Reload App") { store.run(.reload, on: device) }
        Button("Forward Metro Port (8081)") { store.run(.reverse(port: 8081), on: device) }
        Divider()
        Button("Take Screenshot") { store.run(.screenshot, on: device) }
        Button("Install APK…") { installAPK(on: device, store: store, panel: panel) }
    }
}

@MainActor func installAPK(on device: VirtualDevice, store: EmulatorStore, panel: PanelState) {
    guard let apk = panel.chooseFile(title: "Install an APK on \(device.displayName)", prompt: "Install", allowedExtensions: ["apk"]) else { return }
    store.run(.install(apk), on: device)
}

/// A success message with an optional file to reveal; dismisses itself after a few seconds.
struct NoticeBanner: View {
    let notice: EmulatorStore.Notice
    let dismiss: () -> Void

    var body: some View {
        PanelRow {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let file = notice.file {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .controlSize(.small)
            }
            IconButton("xmark", help: "Dismiss", action: dismiss)
        }
        .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
        .transition(.opacity)
    }
}

private struct FailureBanner: View {
    @Environment(AppModel.self) private var model
    let failure: EmulatorStore.Failure
    let dismiss: () -> Void

    var body: some View {
        PanelRow {
            StatusIcon(status: .error)
                .frame(width: 22)
            Text(failure.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let logPath = failure.logPath {
                Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                    .controlSize(.small)
            }
            IconButton("xmark", help: "Dismiss", action: dismiss)
        }
        .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
    }
}

/// Shown when there's no usable SDK; points to the Tools tab for details.
private struct SetupNeededBanner: View {
    let showDetails: () -> Void

    var body: some View {
        Button(action: showDetails) {
            PanelRow {
                StatusIcon(status: .error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Android Development")
                    Text("No Android SDK found. Install everything in one go.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.row)
        .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
    }
}

extension VirtualDevice.FormFactor {
    var symbolName: String {
        switch self {
        case .phone: "smartphone"
        case .foldable: "rectangle.portrait.split.2x1"
        case .tablet: "ipad.landscape"
        case .wear: "watch.analog"
        case .desktop: "display"
        case .tv: "tv"
        case .automotive: "car"
        case .xr: "visionpro"
        case .glasses: "eyeglasses"
        }
    }
}
