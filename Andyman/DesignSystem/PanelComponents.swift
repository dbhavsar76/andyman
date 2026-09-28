import AndroidKit
import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 380
    static let cornerRadius: CGFloat = 18
    static let outerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let groupCornerRadius: CGFloat = 12
    /// Tallest the panel gets before its content scrolls (also capped by the screen).
    static let maxHeight: CGFloat = 640
    /// Transparent space around the glass inside the window, so its shadow isn't clipped.
    static let shadowMargin: CGFloat = 24
    static let navigationAnimation: Animation = .snappy(duration: 0.3)
    /// Tabs or page title row, including padding.
    static let headerHeight: CGFloat = 50
    /// The home header: the app's title row above the tabs.
    static let tabsHeaderHeight: CGFloat = 86
}

/// A titled group of rows on a subtle plate, like a Control Center module.
struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                content
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
        }
    }
}

/// Row padding shared by static rows and hoverable button rows.
struct PanelRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-width row button with a rounded hover highlight, like menu items and Control Center rows.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    private struct RowButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(.rect)
                .background {
                    RoundedRectangle(cornerRadius: PanelMetrics.rowCornerRadius, style: .continuous)
                        .fill(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                        .opacity(isHovered || configuration.isPressed ? 1 : 0)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// Small circular icon button (header actions, refresh).
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .contentShape(.circle)
                .background {
                    Circle()
                        .fill(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                        .opacity(isHovered || configuration.isPressed ? 1 : 0)
                }
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// Coloured status glyph for doctor checks.
struct StatusIcon: View {
    let status: CheckStatus

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .font(.system(size: 15))
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private var label: String {
        switch status {
        case .ok: "OK"
        case .warning: "Warning"
        case .error: "Problem"
        }
    }
}

/// Centered empty state for tabs that don't have content yet.
struct PanelPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// A row that opens a page: icon, title, subtitle, optional trailing content and a chevron.
struct DrillRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, systemImage: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            PanelRow {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.row)
    }
}

/// A path shortened with `~` for the home folder.
func abbreviatedPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
