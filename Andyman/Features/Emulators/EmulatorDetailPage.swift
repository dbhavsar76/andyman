import AndroidKit
import SwiftUI

struct EmulatorDetailPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let name: String

    @State private var snapshots: [AVDSnapshot] = []

    private var store: EmulatorStore { model.emulators }

    var body: some View {
        if let device = store.device(named: name) {
            content(device)
                .task(id: "\(device.path)|\(store.state(of: device))") {
                    await store.loadDiskUsage(for: device)
                    snapshots = await store.snapshots(of: device)
                }
        } else {
            PanelPlaceholder(systemImage: "questionmark.square.dashed", title: "Device Not Found", message: "It may have been deleted or renamed.")
        }
    }

    private func content(_ device: VirtualDevice) -> some View {
        let state = store.state(of: device)
        return VStack(spacing: PanelMetrics.sectionSpacing) {
            header(device, state: state)

            if let failure = store.failure {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if let notice = store.notice {
                NoticeBanner(notice: notice) { store.notice = nil }
            }

            if state == .running {
                PanelSection("Quick Actions") {
                    if let progress = store.actionsInProgress[device.name] {
                        ProgressView().controlSize(.small).help(progress)
                            .accessibilityLabel(progress)
                    }
                } content: {
                    ActionRow("Open Developer Menu", systemImage: "filemenu.and.selection") { store.run(.devMenu, on: device) }
                    ActionRow("Reload App", systemImage: "arrow.clockwise") { store.run(.reload, on: device) }
                    ActionRow("Forward Metro Port (8081)", systemImage: "arrow.left.arrow.right") { store.run(.reverse(port: 8081), on: device) }
                    ActionRow("Take Screenshot", systemImage: "camera.viewfinder") { store.run(.screenshot, on: device) }
                    ActionRow("Install APK…", systemImage: "square.and.arrow.down.on.square") { installAPK(on: device, store: store, panel: panel) }
                }
            }

            PanelSection("Details") {
                InfoRow("Android", value: [device.androidVersion, device.apiLevel.map { "API \($0)" }].compactMap(\.self).joined(separator: ", "))
                InfoRow("Services", value: device.playStore ? "Google Play" : (device.tagDisplay ?? "–"))
                InfoRow("Architecture", value: device.abi ?? "–")
                InfoRow("Device", value: deviceDescription(device))
                if let screen = screenDescription(device) {
                    InfoRow("Screen", value: screen)
                }
                InfoRow("Memory", value: device.ramMB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1_048_576, countStyle: .memory) } ?? "–")
                InfoRow("Storage", value: device.dataPartitionSize.map { $0.replacingOccurrences(of: "G", with: " GB").replacingOccurrences(of: "M", with: " MB") } ?? "–")
                InfoRow("Disk Usage", value: store.diskUsage[device.name].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                if let instance = store.instance(of: device) {
                    InfoRow("Serial", value: instance.serial)
                }
            }

            if !snapshots.isEmpty {
                PanelSection("Snapshots") {
                    ForEach(snapshots) { snapshot in
                        SnapshotRow(snapshot: snapshot, canDelete: !state.isActive) {
                            panel.confirm(
                                "Delete snapshot “\(snapshot.name)”?",
                                detail: snapshot.isQuickBoot
                                    ? "The next start is a cold boot. The emulator saves a new quick-boot snapshot when it shuts down."
                                    : "The snapshot is moved to the Trash.",
                                confirmTitle: "Move to Trash",
                                destructive: true
                            ) {
                                store.deleteSnapshot(snapshot, of: device)
                                Task {
                                    snapshots = await store.snapshots(of: device)
                                    await store.loadDiskUsage(for: device)
                                }
                            }
                        }
                    }
                }
            }

            PanelSection("Manage") {
                ActionRow("Edit…", systemImage: "slider.horizontal.3") { panel.push(.editEmulator(device.name)) }
                    .disabled(state.isActive)
                ActionRow("Duplicate", systemImage: "plus.square.on.square") { duplicate(device, store: store, panel: panel) }
                    .disabled(state.isActive)
                ActionRow("Show in Finder", systemImage: "folder") { store.showInFinder(device) }
                ActionRow("Open Log", systemImage: "doc.text") { store.openLog(device) }
                    .disabled(!store.hasLog(device))
                ActionRow("Wipe Data…", systemImage: "eraser") { confirmWipe(device, store: store, panel: panel) }
                    .disabled(state.isActive)
                ActionRow("Move to Trash…", systemImage: "trash", destructive: true) { confirmDelete(device, store: store, panel: panel) }
                    .disabled(state.isActive)
            }
        }
    }

    private func header(_ device: VirtualDevice, state: EmulatorStore.DeviceState) -> some View {
        HStack(spacing: 12) {
            DeviceIcon(device: device, state: state, size: 26)
                .frame(width: 44, height: 44)
                .background(.quinary, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText(device, state: state))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state == .running ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.opacity)
                Text(device.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            LaunchControl(device: device, state: state)
        }
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.15), value: state)
    }

    private func statusText(_ device: VirtualDevice, state: EmulatorStore.DeviceState) -> String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .booting: "Booting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case let .unavailable(reason): reason
        }
    }

    private func deviceDescription(_ device: VirtualDevice) -> String {
        // "pixel_10a" → "Pixel 10a" (`.capitalized` would give "10A").
        let name = device.deviceName.map { profile in
            profile.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        } ?? "Custom"
        guard let manufacturer = device.manufacturer, !name.lowercased().hasPrefix(manufacturer.lowercased()) else { return name }
        return "\(manufacturer) \(name)"
    }

    private func screenDescription(_ device: VirtualDevice) -> String? {
        guard let width = device.screenWidth, let height = device.screenHeight else { return nil }
        return "\(width) × \(height)" + (device.screenDensity.map { ", \($0) dpi" } ?? "")
    }
}

/// Start button with launch variants (split button), or Stop while running.
private struct LaunchControl: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let state: EmulatorStore.DeviceState

    var body: some View {
        switch state {
        case .stopped:
            Menu {
                Button("Cold Boot") { model.emulators.start(device, options: .init(coldBoot: true)) }
                Button("Start Without Window") { model.emulators.start(device, options: .init(headless: true)) }
                Button("Start Without Saving State") { model.emulators.start(device, options: .init(saveSnapshot: false)) }
                Divider()
                Button("Wipe Data and Start") { model.emulators.start(device, options: .init(wipeData: true)) }
            } label: {
                Text("Start")
            } primaryAction: {
                model.emulators.start(device)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
        case .booting, .running:
            Button("Stop") { model.emulators.stop(device) }
                .buttonStyle(.bordered)
        case .starting, .stopping:
            ProgressView().controlSize(.small)
                .accessibilityLabel(state == .starting ? "Starting" : "Stopping")
        case .unavailable:
            EmptyView()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        PanelRow {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct ActionRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    init(_ title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            PanelRow {
                Image(systemName: systemImage)
                    .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.row)
    }
}

private struct SnapshotRow: View {
    let snapshot: AVDSnapshot
    let canDelete: Bool
    let delete: () -> Void

    var body: some View {
        PanelRow {
            Image(systemName: snapshot.isQuickBoot ? "bolt.fill" : "camera")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.isQuickBoot ? "Quick Boot" : snapshot.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            IconButton("trash", help: "Delete Snapshot", action: delete)
                .disabled(!canDelete)
        }
    }

    private var detail: String {
        var parts = [ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file)]
        if let date = snapshot.date { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
