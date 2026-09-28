import AndroidKit
import SwiftUI

/// Review the licenses a pending install needs, then accept and install (or cancel).
struct LicensePage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: SDKStore { model.sdk }

    var body: some View {
        if let request = store.licenseRequest {
            LicenseReview(
                summary: "Installing \(LicenseReview.packageList(request.plan.packages.map(\.displayName)))",
                licenses: request.licenses,
                acceptTitle: "Accept & Install",
                onDecline: {
                    store.licenseRequest = nil
                    panel.pop()
                },
                onAccept: {
                    store.acceptLicensesAndInstall()
                    panel.pop()
                }
            )
        } else {
            PanelPlaceholder(systemImage: "checkmark.seal", title: "Nothing to Accept", message: "There's no install waiting for a license.")
        }
    }
}

/// License texts with Decline / Accept buttons, shared by package installs and setup.
struct LicenseReview: View {
    let summary: String
    let licenses: [SDKLicense]
    let acceptTitle: String
    let onDecline: () -> Void
    let onAccept: () -> Void
    /// The text viewers appear after the push finishes: they're AppKit scroll views, which
    /// can't follow SwiftUI's slide transition.
    @State private var showText = false

    var body: some View {
        VStack(spacing: PanelMetrics.sectionSpacing) {
            Text("\(summary) requires accepting \(licenses.count == 1 ? "this license" : "these licenses").")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            ForEach(licenses) { license in
                PanelSection(Self.title(for: license.id)) {
                    Group {
                        if showText {
                            LicenseText(text: license.text)
                                .transition(.opacity)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: licenses.count == 1 ? 300 : 200)
                }
            }

            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button(action: onAccept) {
                    Text(acceptTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.15)) { showText = true }
        }
    }

    static func packageList(_ names: [String]) -> String {
        if names.count <= 2 { return names.joined(separator: " and ") }
        return "\(names[0]) and \(names.count - 1) other packages"
    }

    static func title(for id: String) -> String {
        switch id {
        case "android-sdk-license": "Android SDK License"
        case "android-sdk-preview-license": "Android SDK Preview License"
        case "android-sdk-arm-dbt-license": "Android SDK ARM System Image License"
        case "android-googletv-license": "Google TV License"
        case "android-googlexr-license": "Android XR License"
        case "intel-android-sysimage-license": "Intel System Image License"
        default: id.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

/// Scrollable, selectable license text.
private struct LicenseText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            textView.textColor = .secondaryLabelColor
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
