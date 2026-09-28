import AndroidKit
import SwiftUI

/// Step 1 of "New Virtual Device": choose a hardware profile, grouped like Android Studio's picker.
struct ProfilePickerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: EmulatorStore { model.emulators }
    private var draft: NewDeviceDraft { store.draft }

    /// A chip is either a device category or Android Studio's "Legacy" group.
    private enum Group: Hashable {
        case category(VirtualDevice.FormFactor)
        case legacy
    }

    private var groups: [Group] {
        let categories = VirtualDevice.FormFactor.allCases.filter { category in
            store.profiles.contains { $0.category == category && !$0.isLegacy }
        }
        return categories.map(Group.category) + (store.profiles.contains(where: \.isLegacy) ? [.legacy] : [])
    }

    private var selectedGroup: Group { draft.showLegacy ? .legacy : .category(draft.category) }

    private var profiles: [DeviceProfile] {
        let matching = store.profiles.filter { profile in
            switch selectedGroup {
            case .legacy: profile.isLegacy
            case let .category(category): !profile.isLegacy && profile.category == category
            }
        }
        // Generic sizes first (as in Android Studio), then named devices newest first. The SDK
        // lists devices oldest to newest, so reversed file order puts new models on top.
        let generic = matching.filter(\.isGeneric).sorted { !$0.id.hasPrefix("resizable") && $1.id.hasPrefix("resizable") }
        let named = Array(matching.filter { !$0.isGeneric }.reversed())
        return generic + named
    }

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            if !store.canCreate {
                PanelPlaceholder(
                    systemImage: "shippingbox",
                    title: "Command-line Tools Needed",
                    message: "Creating virtual devices needs the Android SDK Command-line Tools. See Tools for details."
                )
            } else if store.profiles.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .accessibilityLabel("Loading device profiles")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(groups, id: \.self) { group in
                        CategoryChip(
                            title: title(for: group),
                            systemImage: symbol(for: group),
                            isSelected: group == selectedGroup
                        ) {
                            select(group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PanelSection(title(for: selectedGroup)) {
                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile) {
                            draft.profile = profile
                            draft.image = nil
                            panel.push(.newDeviceImage)
                        }
                    }
                }
                .id(selectedGroup)
            }
        }
        .task { await store.loadProfiles() }
    }

    private func select(_ group: Group) {
        switch group {
        case .legacy:
            draft.showLegacy = true
        case let .category(category):
            draft.showLegacy = false
            draft.category = category
        }
    }

    private func title(for group: Group) -> String {
        switch group {
        case .legacy: "Legacy"
        case let .category(category): category.title
        }
    }

    private func symbol(for group: Group) -> String {
        switch group {
        case .legacy: "clock.arrow.circlepath"
        case let .category(category): category.symbolName
        }
    }
}

private struct ProfileRow: View {
    let profile: DeviceProfile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow {
                Image(systemName: profile.category.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    let detail = [profile.summary, profile.playStore ? "Google Play" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.row)
    }
}

/// Selectable capsule with an icon, used for categories.
struct CategoryChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(isHovered ? .quaternary : .quinary))
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += (isFirst ? 0 : spacing) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

extension DeviceProfile {
    /// Generic size profiles ("Medium Phone", "Small Tablet", "Wear OS Large Round"…) that
    /// Android Studio lists before named devices.
    var isGeneric: Bool {
        let prefixes = ["small_", "medium_", "large_", "resizable", "desktop_", "tv_", "wearos_", "automotive_", "xr_", "ai_glasses"]
        return manufacturer == "Generic" || prefixes.contains { id.hasPrefix($0) }
    }
}
