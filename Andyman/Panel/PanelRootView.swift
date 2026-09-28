import AndroidKit
import SwiftUI

/// Root of the panel: a header (tabs, or a page title with Back) above one scrolling body.
///
/// Drawn inside a fixed, transparent window: the glass hugs the content, sits at the top, and
/// animates its height when the content changes.
///
/// Navigation slides the header and the body side by side. The body's scroll view is shared by
/// every page and never moves itself: it's an AppKit `NSScrollView`, which can't follow
/// SwiftUI's slide transitions, while SwiftUI content sliding *inside* it animates fine. So
/// long pages slide as smoothly as short ones.
struct PanelRootView: View {
    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The page on top, or nil for the tabs.
    private var top: PanelPage? { panel.pages.last }

    var body: some View {
        PanelScrollContainer(maxHeight: panel.maxHeight, headerHeight: headerHeight, resetKey: top) {
            ZStack(alignment: .top) {
                Group {
                    if let top {
                        PageContent(page: top)
                    } else {
                        TabContent()
                    }
                }
                .padding(.horizontal, PanelMetrics.outerPadding)
                .padding(.bottom, PanelMetrics.outerPadding)
                .id(top)
                .transition(slide)
            }
        } header: {
            ZStack {
                Group {
                    if let top {
                        PageHeader(page: top)
                    } else {
                        TabsHeader()
                    }
                }
                .id(top)
                .transition(slide)
            }
            .frame(height: headerHeight)
        }
        .frame(width: PanelMetrics.width)
        .overlay {
            if let confirmation = panel.confirmation {
                ConfirmationOverlay(confirmation: confirmation)
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .padding(PanelMetrics.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerHeight: CGFloat { top == nil ? PanelMetrics.tabsHeaderHeight : PanelMetrics.headerHeight }

    /// Forward: new page in from the right, old out to the left. Back: the reverse. With
    /// Reduce Motion on, pages cross-fade instead.
    private var slide: AnyTransition {
        if reduceMotion { return .opacity }
        return switch panel.direction {
        case .forward: .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        case .backward: .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        }
    }
}

/// One scroll view for every page, with the header in its top bar: content scrolls up
/// underneath the header and softly blurs out there, like System Settings. Sized to its
/// content up to `maxHeight`, with height changes animated so the glass grows and shrinks
/// smoothly; scrolls back to the top when `resetKey` changes (i.e. on navigation).
private struct PanelScrollContainer<Content: View, Header: View, Key: Hashable>: View {
    let maxHeight: CGFloat
    let headerHeight: CGFloat
    let resetKey: Key
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header

    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)

    @State private var hasMoreBelow = false
    @Environment(PanelState.self) private var panel
    /// Scroll offset, inset and visible height, for scrolling focused controls into view.
    @State private var viewport = FocusScrolling.Viewport()

    private var fullHeight: CGFloat { contentHeight + headerHeight }

    var body: some View {
        ScrollView(.vertical) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    if contentHeight == 0 {
                        contentHeight = height
                    } else {
                        withAnimation(PanelMetrics.navigationAnimation) { contentHeight = height }
                    }
                }
        }
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The system edge effect only renders under a bar, so the bottom edge gets a short
        // fade instead, shown only while there's more to scroll to.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The offset starts at -inset.top (content begins below the header); `containerSize`
            // excludes the insets, so the end is reached at this offset.
            let insets = geometry.contentInsets
            let maxOffset = geometry.contentSize.height - geometry.containerSize.height - insets.top + insets.bottom
            return geometry.contentOffset.y < maxOffset - 1
        } action: { _, more in
            withAnimation(.easeOut(duration: 0.15)) { hasMoreBelow = more }
        }
        .onScrollGeometryChange(for: FocusScrolling.Viewport.self) { geometry in
            FocusScrolling.Viewport(
                offset: geometry.contentOffset.y,
                topInset: geometry.contentInsets.top,
                height: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height
            )
        } action: { _, new in
            viewport = new
        }
        .onChange(of: panel.focusedArea) { _, area in
            guard let area, let offset = viewport.offsetRevealing(area.rect) else { return }
            // `scrollTo(y:)` measures from the top of the content, below the header's inset.
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: offset + viewport.topInset) }
        }
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: hasMoreBelow ? 36 : 0)
            }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(fullHeight > maxHeight ? .automatic : .never)
        .frame(height: min(max(fullHeight, headerHeight), maxHeight))
        .onChange(of: resetKey) {
            withAnimation(PanelMetrics.navigationAnimation) { position.scrollTo(edge: .top) }
        }
    }
}

private struct TabsHeader: View {
    @Environment(PanelState.self) private var panel

    var body: some View {
        @Bindable var panel = panel
        VStack(spacing: 0) {
            // Laid out like a page header: the title centred, the button at the edge.
            ZStack {
                HStack(spacing: 6) {
                    Image(nsImage: MenuBarIcon.image(running: false))
                        .renderingMode(.template)
                        .accessibilityHidden(true)
                    Text("Andyman")
                        .font(.headline)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
                .accessibilityElement(children: .combine)
                HStack {
                    Spacer()
                    IconButton("gearshape", help: "Settings") { panel.push(.settings) }
                }
            }
            .frame(height: PanelMetrics.headerHeight)

            Picker("Section", selection: $panel.tab.animation(PanelMetrics.navigationAnimation)) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, PanelMetrics.outerPadding)
    }
}

private struct TabContent: View {
    @Environment(PanelState.self) private var panel

    var body: some View {
        Group {
            switch panel.tab {
            case .emulators: EmulatorsTab()
            case .sdk: SDKTab()
            case .tools: ToolsTab()
            }
        }
        // Fade the old tab out quickly and the new one in just after, so the two barely
        // overlap while the glass resizes.
        .transition(.asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.07)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        ))
    }
}

private struct PageHeader: View {
    @Environment(PanelState.self) private var panel
    @Environment(AppModel.self) private var model
    let page: PanelPage

    private var title: String {
        switch page {
        case .settings: "Settings"
        case let .emulator(name): model.emulators.device(named: name)?.displayName ?? name.replacingOccurrences(of: "_", with: " ")
        case .editEmulator: "Edit Device"
        case .newDeviceProfile: "New Virtual Device"
        case .newDeviceImage: "System Image"
        case .newDeviceSettings: "Configure"
        case let .sdkCategory(category): category.title
        case .sdkLicenses, .setupLicenses: "License Agreements"
        case .setup: "Set Up Android"
        case let .project(path): model.projects.entry(path).report?.project.folderName ?? (path as NSString).lastPathComponent
        case .cleanup: "Free Up Space"
        case .agents: "Coding Agents"
        }
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 36)
            HStack {
                IconButton("chevron.left", help: "Back") { panel.pop() }
                    .keyboardShortcut("[", modifiers: .command)
                Spacer()
            }
        }
        .padding(.horizontal, PanelMetrics.outerPadding)
    }
}

private struct PageContent: View {
    let page: PanelPage

    var body: some View {
        switch page {
        case .settings: SettingsPage()
        case let .emulator(name): EmulatorDetailPage(name: name)
        case let .editEmulator(name): EditDevicePage(name: name)
        case .newDeviceProfile: ProfilePickerPage()
        case .newDeviceImage: ImagePickerPage()
        case .newDeviceSettings: NewDeviceSettingsPage()
        case let .sdkCategory(category): SDKCategoryPage(category: category)
        case .sdkLicenses: LicensePage()
        case .setup: SetupPage()
        case .setupLicenses: SetupLicensePage()
        case let .project(path): ProjectPage(path: path)
        case .cleanup: CleanupPage()
        case .agents: AgentsPage()
        }
    }
}

/// Dims the panel and asks a yes/no question in a card, like an alert scoped to the panel.
private struct ConfirmationOverlay: View {
    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: PanelState.ConfirmationButton?
    let confirmation: PanelState.Confirmation

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.3))
                .contentShape(.rect)
                .onTapGesture { panel.resolveConfirmation(false) }
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Image(systemName: confirmation.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                Text(confirmation.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(confirmation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { panel.resolveConfirmation(false) } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.cancelAction)
                    .focused($focused, equals: .cancel)

                    Button { panel.resolveConfirmation(true) } label: {
                        Text(confirmation.confirmTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(confirmation.destructive ? .red : .accentColor)
                    .keyboardShortcut(.defaultAction)
                    .focused($focused, equals: .confirm)
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            .padding(18)
            .frame(width: 290)
            .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            .accessibilityAddTraits(.isModal)
            .onAppear { focused = panel.confirmationFocus }
            .onChange(of: panel.confirmationFocus) { _, button in focused = button }
            .onChange(of: focused) { _, button in
                if let button { panel.confirmationFocus = button }
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
        }
    }
}
