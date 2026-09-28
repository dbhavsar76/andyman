import AndroidKit
import SwiftUI

/// Step 3 of "New Virtual Device": name and hardware settings, then Create.
struct NewDeviceSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    @State private var values: DeviceFormValues?
    @State private var isCreating = false
    @State private var error: String?

    private var store: EmulatorStore { model.emulators }

    var body: some View {
        if let profile = store.draft.profile, let image = store.draft.image {
            VStack(spacing: PanelMetrics.sectionSpacing) {
                ChosenProfileHeader(profile: profile, image: image)

                if let binding = Binding($values) {
                    DeviceSettingsForm(values: binding, nameProblem: nameProblem, isNewDevice: true)
                        .disabled(isCreating)
                }

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }

                Button {
                    create(profile: profile, image: image)
                } label: {
                    HStack(spacing: 8) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text(isCreating ? "Creating…" : "Create Virtual Device")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || nameProblem != nil || values == nil)
            }
            .onAppear {
                if values == nil {
                    values = DeviceFormValues(
                        profile: profile,
                        image: image,
                        suggestedName: store.suggestedName(profile: profile, image: image),
                        frameAvailable: store.hasFrame(for: profile)
                    )
                }
            }
        }
    }

    private var nameProblem: String? {
        guard let name = values?.name else { return nil }
        if !AVDCatalog.isValidName(name) { return "Use letters, numbers, dots, dashes and underscores (no spaces)." }
        if store.device(named: name) != nil { return "A device named \(name) already exists." }
        return nil
    }

    private func create(profile: DeviceProfile, image: SystemImage) {
        guard let values else { return }
        isCreating = true
        error = nil
        Task {
            do {
                let device = try await store.create(AVDSpec(
                    name: values.name, profileID: profile.id, systemImage: image.id, settings: values.settings
                ))
                panel.show([.emulator(device.name)])
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// Edit an existing device's name and hardware settings.
struct EditDevicePage: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        if let device = model.emulators.device(named: name) {
            // The form's values are ready on the first render, so the page slides in at its
            // full height (filling them in onAppear made the form pop in mid-transition).
            EditDeviceForm(device: device, initial: DeviceFormValues(device: device, settings: model.emulators.settings(of: device)))
        } else {
            PanelPlaceholder(systemImage: "questionmark.square.dashed", title: "Device Not Found", message: "It may have been deleted or renamed.")
        }
    }
}

private struct EditDeviceForm: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: VirtualDevice
    @State private var values: DeviceFormValues
    @State private var original: DeviceFormValues
    @State private var error: String?

    private var store: EmulatorStore { model.emulators }

    init(device: VirtualDevice, initial: DeviceFormValues) {
        self.device = device
        _values = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    var body: some View {
        let isActive = store.state(of: device).isActive
        VStack(spacing: PanelMetrics.sectionSpacing) {
            if isActive {
                Text("Stop \(device.displayName) to change its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }

            DeviceSettingsForm(values: $values, nameProblem: nameProblem, isNewDevice: false)
                .disabled(isActive)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }

            Button { save() } label: {
                Text("Save Changes").frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isActive || values == original || nameProblem != nil)
        }
    }

    private var nameProblem: String? {
        let name = values.name
        guard name != device.name else { return nil }
        if !AVDCatalog.isValidName(name) { return "Use letters, numbers, dots, dashes and underscores (no spaces)." }
        if store.device(named: name) != nil { return "A device named \(name) already exists." }
        return nil
    }

    private func save() {
        do {
            let saved = try store.save(device, name: values.name, settings: values.settings)
            panel.show([.emulator(saved.name)])
        } catch {
            self.error = error.localizedDescription
        }
    }
}
