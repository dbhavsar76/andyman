import AndroidKit
import SwiftUI

/// Packages in one category: installed ones first, then what's available.
struct SDKCategoryPage: View {
    @Environment(AppModel.self) private var model
    let category: PackageCategory
    @State private var showAllVersions = false

    private var store: SDKStore { model.sdk }

    var body: some View {
        let packages = store.list.packages(in: category)
        let installed = packages.filter(\.isInstalled)
        let available = packages.filter { !$0.isInstalled }

        VStack(spacing: PanelMetrics.sectionSpacing) {
            if let failure = store.failure {
                NoticeRow(systemImage: "xmark.octagon.fill", title: "Couldn't install", message: failure) { store.failure = nil }
            }

            if category == .systemImages {
                SystemImagesContent(installed: installed, available: available)
            } else {
                if !installed.isEmpty {
                    PanelSection("Installed") {
                        ForEach(installed) { SDKPackageRow(package: $0, title: title(for: $0)) }
                    }
                }
                if !available.isEmpty {
                    let shown = showAllVersions ? available : Array(available.prefix(Self.collapsedCount))
                    PanelSection("Available") {
                        ForEach(shown) { SDKPackageRow(package: $0, title: title(for: $0)) }
                        if available.count > Self.collapsedCount {
                            Button(showAllVersions ? "Show Fewer" : "Show All \(available.count)") {
                                withAnimation(PanelMetrics.navigationAnimation) { showAllVersions.toggle() }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                    }
                }
                if packages.isEmpty {
                    PanelPlaceholder(systemImage: category.symbolName, title: "Nothing Here Yet", message: "The package catalog is still loading.")
                }
            }
        }
        .task(id: installed.map(\.id)) { await store.loadDiskUsage(for: installed) }
    }

    static let collapsedCount = 6

    /// Platforms read better as "Android 16 · API 36" than "Android SDK Platform 36".
    private func title(for package: SDKPackage) -> String? {
        guard category == .platforms, let api = package.available?.apiLevel ?? package.id.split(separator: "-").last.map(String.init),
              let version = AndroidRelease.versionName(forAPILevel: api), package.available?.isPreview != true
        else { return nil }
        return "Android \(version) · API \(api)"
    }
}

/// System images grouped by Android version, limited to images that run on this Mac.
private struct SystemImagesContent: View {
    @Environment(AppModel.self) private var model
    let installed: [SDKPackage]
    let available: [SDKPackage]
    @State private var showOlder = false

    var body: some View {
        let hostABIs = SystemImage.hostABIs
        let runnable = available.filter { $0.available?.abi.map(hostABIs.contains) ?? false }
        let groups = Dictionary(grouping: runnable) { $0.available?.apiLevel ?? "?" }
            .sorted { VersionComparator.isLess($1.key, $0.key) }
        let recent = groups.filter { (Double($0.key) ?? 0) >= 30 }
        let shown = showOlder ? groups : recent

        if !installed.isEmpty {
            PanelSection("Installed") {
                ForEach(installed) { SDKPackageRow(package: $0, title: imageTitle($0)) }
            }
        }
        ForEach(shown, id: \.key) { api, packages in
            PanelSection(apiTitle(api)) {
                ForEach(packages.sorted(by: imageOrder)) { SDKPackageRow(package: $0, title: variantTitle($0)) }
            }
        }
        if groups.count > recent.count {
            Button(showOlder ? "Hide Older Versions" : "Show Older Versions") {
                withAnimation(PanelMetrics.navigationAnimation) { showOlder.toggle() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private func apiTitle(_ api: String) -> String {
        AndroidRelease.versionName(forAPILevel: api).map { "Android \($0) · API \(api)" } ?? "API \(api)"
    }

    private func variantTitle(_ package: SDKPackage) -> String {
        tagName(package) ?? package.displayName
    }

    private func imageTitle(_ package: SDKPackage) -> String {
        let components = package.id.split(separator: ";")
        let api = components.count > 1 ? String(components[1]).replacingOccurrences(of: "android-", with: "") : ""
        let variant = tagName(package) ?? package.installed?.displayName ?? package.id
        return "\(variant) · API \(api)"
    }

    /// The image's variant ("Google Play"). Some catalog entries leave it empty, like older
    /// `default` images.
    private func tagName(_ package: SDKPackage) -> String? {
        if let display = package.available?.tagDisplay, !display.isEmpty { return display }
        let components = package.id.split(separator: ";")
        if components.count > 2, components[2] == "default" { return "Default Android System Image" }
        return nil
    }

    /// Google Play first, then Google APIs, then the rest.
    private func imageOrder(_ lhs: SDKPackage, _ rhs: SDKPackage) -> Bool {
        func rank(_ package: SDKPackage) -> Int {
            let tags = package.available?.tagIDs ?? []
            if tags.contains(where: { $0.contains("playstore") }) { return 0 }
            if tags.contains("google_apis") { return 1 }
            return 2
        }
        return (rank(lhs), lhs.id) < (rank(rhs), rhs.id)
    }
}

/// One package with its version, size and an Install / Update / Remove action.
struct SDKPackageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let package: SDKPackage
    var title: String?
    var showCategoryIcon = false

    private var store: SDKStore { model.sdk }

    var body: some View {
        PanelRow {
            if showCategoryIcon {
                Image(systemName: package.category.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? package.displayName)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            action
        }
        .contextMenu {
            if let path = package.installed?.path {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy Package ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.id, forType: .string)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let installed = package.installed {
            parts.append(package.updateAvailable ? "\(installed.revision) → \(package.available!.revision)" : "\(installed.revision)")
            if let bytes = store.diskUsage[package.id] {
                parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
        } else if let available = package.available {
            parts.append("\(available.revision)")
            if let size = available.archive?.size {
                parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if available.channel != .stable { parts.append(available.channel.name.capitalized) }
        }
        if package.isObsolete { parts.append("Obsolete") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        if let item = store.queueItem(package.id) {
            if let fraction = item.state.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("Installing \(package.displayName)")
            } else if item.isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 26, height: 26)
                    .help("Install failed")
                    .accessibilityLabel("Install failed")
            } else {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    .accessibilityLabel("Waiting to install")
            }
        } else if package.updateAvailable {
            Button("Update") { requestInstall() }
                .controlSize(.small)
                .disabled(!store.hasTools)
        } else if package.isInstalled {
            IconButton("trash", help: "Remove") { confirmRemove() }
                .disabled(!store.hasTools)
        } else {
            IconButton("arrow.down.circle", help: "Install") { requestInstall() }
                .disabled(!store.hasTools)
        }
    }

    private func requestInstall() {
        if store.install([package.id]) { panel.push(.sdkLicenses) }
    }

    private func confirmRemove() {
        let size = store.diskUsage[package.id].map { " and frees \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? ""
        panel.confirm(
            "Remove \(package.displayName)?",
            detail: "This deletes it from the SDK\(size). You can install it again later.",
            confirmTitle: "Remove",
            destructive: true
        ) {
            store.uninstall(package.id)
        }
    }
}
