import AndroidKit
import SwiftUI

/// "Free Up Space": pick caches to delete, with sizes measured first.
struct CleanupPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: MaintenanceStore { model.maintenance }

    private static let groups: [(title: String, kinds: Set<CleanupTarget.Kind>)] = [
        ("Gradle", [.gradleCaches, .gradleDistribution, .gradleDaemonLogs]),
        ("Emulators", [.emulatorSnapshots]),
        ("Other", [.metroCache, .androidCache, .sdkLeftovers]),
    ]

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            Text("These are caches: whatever you delete is downloaded or rebuilt when it's next needed, which makes that build or emulator start slower.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            if let result = store.result {
                NoticeRow(systemImage: "checkmark.circle.fill", title: result, message: "Anything still needed is re-created on the next build.") { store.result = nil }
            }
            if let failure = store.failure {
                NoticeRow(systemImage: "exclamationmark.triangle.fill", title: "Couldn't delete everything", message: failure) { store.failure = nil }
            }

            if store.items.isEmpty {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .accessibilityLabel("Measuring caches")
                } else {
                    PanelPlaceholder(systemImage: "sparkles", title: "Nothing to Clean", message: "No caches worth deleting right now.")
                }
            } else {
                ForEach(Self.groups, id: \.title) { group in
                    let items = store.items.filter { group.kinds.contains($0.target.kind) }
                    if !items.isEmpty {
                        PanelSection(group.title) {
                            ForEach(items) { item in
                                CleanupRow(item: item, isSelected: store.selection.contains(item.id)) {
                                    store.toggle(item.id)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 6) {
                    Button { confirm() } label: {
                        HStack(spacing: 8) {
                            if store.isCleaning { ProgressView().controlSize(.small) }
                            Text(store.isCleaning ? "Deleting…" : deleteTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(store.selection.isEmpty || store.isCleaning || store.isScanning)
                }
            }
        }
        .task(id: model.emulators.devices.count) { await model.scanCleanup() }
    }

    private var deleteTitle: String {
        store.selection.isEmpty ? "Delete Selected" : "Delete Selected · \(formatBytes(store.selectedSize))"
    }

    private func confirm() {
        let selected = store.items.filter { store.selection.contains($0.id) }
        let stopsGradle = selected.contains { $0.target.needsGradleStopped } && !store.daemons.isEmpty
        let names = selected.map(\.target.title)
        let list = names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        panel.confirm(
            "Delete \(formatBytes(store.selectedSize)) of caches?",
            detail: "\(list) will be deleted for good." + (stopsGradle ? " Running Gradle daemons are stopped first." : ""),
            confirmTitle: "Delete",
            destructive: true
        ) {
            Task { await model.cleanSelected() }
        }
    }
}

private struct CleanupRow: View {
    let item: MaintenanceStore.Item
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            PanelRow {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 15))
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
                    Text(formatBytes(size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Measuring size")
                }
            }
        }
        .buttonStyle(.row)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
