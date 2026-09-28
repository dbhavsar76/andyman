import AndroidKit
import SwiftUI

/// Step 2 of "New Virtual Device": choose an installed system image that fits the profile.
struct ImagePickerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    private var store: EmulatorStore { model.emulators }

    @State private var showAllDownloads = false

    var body: some View {
        if let profile = store.draft.profile {
            // Reading `sdk.installed` re-renders this page when a download finishes.
            let _ = model.sdk.installed.count
            let images = store.installedImages().filter { $0.isCompatible(with: profile) }
            let downloadable = model.sdk.downloadableImages(for: profile)
            VStack(spacing: PanelMetrics.sectionSpacing) {
                ChosenProfileHeader(profile: profile)

                if images.isEmpty && downloadable.isEmpty {
                    PanelPlaceholder(
                        systemImage: "externaldrive.badge.xmark",
                        title: "No Compatible Images",
                        message: noImagesMessage(for: profile)
                    )
                }
                if !images.isEmpty {
                    PanelSection("Installed") {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            ImageRow(image: image, isRecommended: index == 0) {
                                store.draft.image = image
                                panel.push(.newDeviceSettings)
                            }
                        }
                    }
                }
                if !downloadable.isEmpty {
                    let shown = showAllDownloads ? downloadable : Array(downloadable.prefix(4))
                    PanelSection("Available to Download") {
                        ForEach(shown, id: \.package.id) { entry in
                            DownloadImageRow(package: entry.package, image: entry.image)
                        }
                        if downloadable.count > 4 {
                            Button(showAllDownloads ? "Show Fewer" : "Show All \(downloadable.count)") {
                                withAnimation(PanelMetrics.navigationAnimation) { showAllDownloads.toggle() }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        } else {
            PanelPlaceholder(systemImage: "questionmark.square.dashed", title: "No Device Chosen", message: "Go back and choose a device.")
        }
    }

    private func noImagesMessage(for profile: DeviceProfile) -> String {
        var message = "Install a \(profile.category.title) system image"
        if let minimum = profile.minAPILevel {
            message += " (API \(DeviceProfile.formatInches(minimum)) or newer)"
        }
        return message + " for this Mac to create this device. Check the SDK tab once the package list has loaded."
    }
}

private struct ImageRow: View {
    let image: SystemImage
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text([image.androidVersion, "API \(image.apiLevel)"].compactMap(\.self).joined(separator: " · "))
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                    }
                    Text("\(image.tagDisplay) · \(image.abi)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

/// A system image that can be downloaded, with its progress while downloading.
private struct DownloadImageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let package: RemotePackage
    let image: SystemImage

    var body: some View {
        PanelRow {
            VStack(alignment: .leading, spacing: 2) {
                Text([image.androidVersion, "API \(image.apiLevel)"].compactMap(\.self).joined(separator: " · "))
                Text([image.tagDisplay, package.archive.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) }]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let item = model.sdk.queueItem(package.id) {
                if let fraction = item.state.fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                        .accessibilityLabel("Downloading")
                } else if item.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        .help("Download failed")
                        .accessibilityLabel("Download failed")
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Installing")
                }
            } else {
                Button("Download") {
                    if model.sdk.install([package.id]) { panel.push(.sdkLicenses) }
                }
                .controlSize(.small)
                .disabled(!model.sdk.hasTools)
            }
        }
    }
}

/// Compact summary of the profile chosen in step 1.
struct ChosenProfileHeader: View {
    let profile: DeviceProfile
    var image: SystemImage?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.category.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quinary, in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                Text(image?.summary ?? profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}
