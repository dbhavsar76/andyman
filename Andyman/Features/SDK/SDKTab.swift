import AndroidKit
import SwiftUI

/// SDK overview: installs in progress, available updates, and categories to browse.
struct SDKTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: SDKStore { model.sdk }

    var body: some View {
        if model.report?.sdk.inventory == nil {
            if model.report == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .accessibilityLabel("Loading SDK")
            } else {
                VStack(spacing: 4) {
                    PanelPlaceholder(
                        systemImage: "shippingbox",
                        title: "No Android SDK",
                        message: "Set one up from scratch, or choose an existing SDK folder in Settings."
                    )
                    Button("Set Up Android Development…") { panel.push(.setup) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 12)
            }
        } else {
            VStack(spacing: PanelMetrics.sectionSpacing) {
                if !store.hasTools {
                    NoticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Command-line Tools needed",
                        message: "Installing packages needs the Android SDK Command-line Tools."
                    )
                }
                if let failure = store.failure {
                    NoticeRow(systemImage: "xmark.octagon.fill", title: "Couldn't install", message: failure) { store.failure = nil }
                }

                if !store.queue.isEmpty {
                    PanelSection("Installing") {
                        Button("Cancel") { store.cancelAll() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(!store.isBusy)
                    } content: {
                        ForEach(store.queue) { item in
                            QueueRow(item: item)
                        }
                    }
                }

                if !store.list.updates.isEmpty {
                    PanelSection("Updates") {
                        Button("Update All") { requestInstall(store.list.updates.map(\.id)) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(!store.hasTools)
                    } content: {
                        ForEach(store.list.updates) { package in
                            SDKPackageRow(package: package, showCategoryIcon: true)
                        }
                    }
                }

                PanelSection("Packages") {
                    ForEach(PackageCategory.allCases, id: \.self) { category in
                        let packages = store.list.packages(in: category)
                        if !packages.isEmpty {
                            CategoryRow(category: category, packages: packages) {
                                panel.push(.sdkCategory(category))
                            }
                        }
                    }
                }

                CatalogFooter()
            }
        }
    }

    private func requestInstall(_ ids: [String]) {
        if store.install(ids) { panel.push(.sdkLicenses) }
    }
}

private struct CategoryRow: View {
    let category: PackageCategory
    let packages: [SDKPackage]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow {
                Image(systemName: category.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(category.title)
                Spacer(minLength: 8)
                let installed = packages.filter(\.isInstalled).count
                let updates = packages.filter(\.updateAvailable).count
                if updates > 0 {
                    Text("\(updates) update\(updates == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                Text(installed == 0 ? "None" : "\(installed) installed")
                    .foregroundStyle(installed == 0 ? .tertiary : .secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.row)
    }
}

/// Progress for one queued install or removal.
struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let item: SDKStore.QueueItem

    var body: some View {
        PanelRow {
            Image(systemName: PackageCategory(packageID: item.id).symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .lineLimit(1)
                switch item.state {
                case let .downloading(received, total):
                    ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                        .controlSize(.small)
                        .accessibilityLabel("Downloading \(item.displayName)")
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .unpacking:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                case .removing:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Removing…").font(.caption).foregroundStyle(.secondary)
                case .waiting:
                    Text("Waiting" + (item.size.map { " · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if item.isFailed {
                IconButton("xmark", help: "Dismiss") { model.sdk.dismissFailure(item.id) }
            }
        }
    }
}

/// Catalog freshness and a refresh button.
private struct CatalogFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.sdk
        HStack(spacing: 6) {
            if store.isLoadingCatalog {
                ProgressView().controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Checking for packages…")
            } else if let error = store.catalogError, store.catalog == nil {
                Text(error).lineLimit(2)
            } else if let fetchedAt = store.catalog?.fetchedAt {
                Text("Checked \(fetchedAt.formatted(.relative(presentation: .named)))")
                if store.channel != .stable {
                    Text("· \(store.channel.name.capitalized) channel")
                }
            }
            Spacer()
            Button("Check Now") { Task { await store.loadCatalog(force: true) } }
                .buttonStyle(.borderless)
                .disabled(store.isLoadingCatalog)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

/// A dismissible (or not) notice with an icon, title and message.
struct NoticeRow: View {
    let systemImage: String
    let title: String
    let message: String
    var dismiss: (() -> Void)?

    var body: some View {
        PanelRow {
            Image(systemName: systemImage)
                .symbolRenderingMode(.multicolor)
                .frame(width: 20)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let dismiss {
                IconButton("xmark", help: "Dismiss", action: dismiss)
            }
        }
        .background(.quinary, in: .rect(cornerRadius: PanelMetrics.groupCornerRadius, style: .continuous))
    }
}

extension PackageCategory {
    var symbolName: String {
        switch self {
        case .platforms: "square.stack.3d.up"
        case .systemImages: "externaldrive"
        case .buildTools: "hammer"
        case .ndk: "cpu"
        case .cmake: "gearshape.2"
        case .tools: "wrench.and.screwdriver"
        case .sources: "doc.text"
        case .other: "shippingbox"
        }
    }
}
