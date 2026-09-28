import AndroidKit
import SwiftUI

/// Values edited by `DeviceSettingsForm`, for both new and existing devices.
struct DeviceFormValues: Equatable {
    var displayName: String
    /// AVD name used with `emulator -avd`. Follows the display name until edited directly.
    var name: String
    var nameEdited = false
    var ramMB: Int
    var storageMB: Int
    var sdCardMB: Int
    var cpuCores: Int
    var orientation: AVDSettings.Orientation
    var hardwareKeyboard: Bool
    var showFrame: Bool
    var frameAvailable: Bool

    var settings: AVDSettings {
        AVDSettings(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            ramMB: ramMB,
            storageMB: storageMB,
            sdCardMB: sdCardMB,
            cpuCores: cpuCores,
            hardwareKeyboard: hardwareKeyboard,
            showFrame: frameAvailable ? showFrame : nil,
            orientation: orientation
        )
    }

    /// Defaults for a new device, similar to Android Studio's.
    init(profile: DeviceProfile, image: SystemImage, suggestedName: String, frameAvailable: Bool) {
        displayName = "\(profile.name) API \(image.apiLevel)"
        name = suggestedName
        ramMB = 2048
        storageMB = 8192
        sdCardMB = [.wear, .tv, .automotive, .glasses].contains(profile.category) ? 0 : 512
        cpuCores = min(4, ProcessInfo.processInfo.activeProcessorCount)
        let landscape = (profile.screenWidth ?? 0) > (profile.screenHeight ?? 0) && !profile.hasHinge
        orientation = landscape ? .landscape : .portrait
        hardwareKeyboard = true
        showFrame = frameAvailable
        self.frameAvailable = frameAvailable
    }

    /// Current values of an existing device.
    init(device: VirtualDevice, settings: AVDSettings) {
        displayName = device.displayName
        name = device.name
        nameEdited = true
        ramMB = settings.ramMB ?? 2048
        storageMB = settings.storageMB ?? 8192
        sdCardMB = settings.sdCardMB ?? 0
        cpuCores = settings.cpuCores ?? 4
        orientation = settings.orientation ?? .portrait
        hardwareKeyboard = settings.hardwareKeyboard ?? true
        showFrame = settings.showFrame ?? false
        frameAvailable = settings.showFrame != nil
    }
}

struct DeviceSettingsForm: View {
    @Binding var values: DeviceFormValues
    /// Message shown under the AVD name when it's invalid or taken.
    var nameProblem: String?
    /// Changing the SD card size only takes effect for new devices.
    var isNewDevice: Bool

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            PanelSection("Name") {
                PanelRow {
                    TextField("Display Name", text: $values.displayName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: values.displayName) { _, newValue in
                            if !values.nameEdited { values.name = AVDCatalog.sanitizedName(newValue) }
                        }
                }
                PanelRow {
                    Text("AVD Name")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    TextField("AVD Name", text: Binding(
                        get: { values.name },
                        set: { values.name = $0; values.nameEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(maxWidth: 200)
                }
                Text(nameProblem ?? "Used with emulator -avd and andyman. Letters, numbers, dots, dashes and underscores.")
                    .font(.caption)
                    .foregroundStyle(nameProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            PanelSection("Hardware") {
                SizePickerRow("Memory", value: $values.ramMB, options: [1024, 1536, 2048, 3072, 4096, 6144, 8192])
                SizePickerRow("Internal Storage", value: $values.storageMB, options: [2048, 4096, 6144, 8192, 16384, 32768, 65536])
                if isNewDevice {
                    SizePickerRow("SD Card", value: $values.sdCardMB, options: [0, 512, 1024, 2048, 4096], zeroLabel: "None")
                }
                PanelRow {
                    Text("CPU Cores")
                    Spacer()
                    Picker("CPU Cores", selection: $values.cpuCores) {
                        ForEach(Array(1...max(ProcessInfo.processInfo.activeProcessorCount, values.cpuCores)), id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            PanelSection("Display & Input") {
                PanelRow {
                    Text("Orientation")
                    Spacer()
                    Picker("Orientation", selection: $values.orientation) {
                        Label("Portrait", systemImage: "rectangle.portrait").tag(AVDSettings.Orientation.portrait)
                        Label("Landscape", systemImage: "rectangle").tag(AVDSettings.Orientation.landscape)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToggleRow("Device Frame", isOn: $values.showFrame, detail: values.frameAvailable ? nil : "No frame artwork for this device")
                    .disabled(!values.frameAvailable)
                ToggleRow("Hardware Keyboard", isOn: $values.hardwareKeyboard, detail: "Type into the emulator with your Mac's keyboard")
            }
        }
    }
}

private struct SizePickerRow: View {
    let title: String
    @Binding var value: Int
    let options: [Int]
    var zeroLabel: String?

    init(_ title: String, value: Binding<Int>, options: [Int], zeroLabel: String? = nil) {
        self.title = title
        _value = value
        self.options = options
        self.zeroLabel = zeroLabel
    }

    var body: some View {
        PanelRow {
            Text(title)
            Spacer()
            Picker(title, selection: $value) {
                // Keep a custom current value selectable even if it isn't a preset.
                ForEach((options.contains(value) ? options : (options + [value]).sorted()), id: \.self) { megabytes in
                    Text(label(megabytes)).tag(megabytes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func label(_ megabytes: Int) -> String {
        if megabytes == 0, let zeroLabel { return zeroLabel }
        return ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .memory)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?

    init(_ title: String, isOn: Binding<Bool>, detail: String? = nil) {
        self.title = title
        _isOn = isOn
        self.detail = detail
    }

    var body: some View {
        PanelRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
