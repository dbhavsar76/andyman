import Foundation

/// An installed system image (`system-images;android-36;google_apis_playstore;arm64-v8a`).
public struct SystemImage: Sendable, Equatable, Codable, Identifiable {
    /// The `sdkmanager` package id.
    public var id: String
    public var apiLevel: String
    public var tagIDs: [String]
    public var tagDisplay: String
    public var abi: String
    public var revision: String?
    public var path: String

    public init(id: String, apiLevel: String, tagIDs: [String], tagDisplay: String, abi: String, revision: String?, path: String) {
        self.id = id
        self.apiLevel = apiLevel
        self.tagIDs = tagIDs
        self.tagDisplay = tagDisplay
        self.abi = abi
        self.revision = revision
        self.path = path
    }

    /// A not-yet-installed image from the repository catalog.
    public init?(remote package: RemotePackage) {
        guard package.category == .systemImages, let abi = package.abi, let apiLevel = package.apiLevel else { return nil }
        self.init(
            id: package.id, apiLevel: apiLevel, tagIDs: package.tagIDs, tagDisplay: package.tagDisplay ?? "",
            abi: abi, revision: "\(package.revision)", path: ""
        )
    }

    public var androidVersion: String? {
        AndroidRelease.versionName(forAPILevel: apiLevel).map { "Android \($0)" }
    }

    public var hasPlayStore: Bool { tagIDs.contains { $0.contains("playstore") } }

    /// Phone-like images have no form-factor tag; others are TV, Wear OS, Automotive…
    public var formFactor: VirtualDevice.FormFactor {
        AVDCatalog.formFactor(config: [:], tagIDs: tagIDs)
    }

    /// Whether this image is only for tablets (`google_apis_playstore_tablet`).
    public var isTabletOnly: Bool { tagIDs.contains { $0.hasSuffix("_tablet") } }

    /// Numeric API level for sorting and profile constraints (`36.1` → 36.1).
    public var apiNumber: Double { Double(apiLevel) ?? Double(apiLevel.prefix { $0.isNumber || $0 == "." }) ?? 0 }

    /// `Android 16 · API 36 · Google Play`
    public var summary: String {
        [androidVersion, "API \(apiLevel)", tagDisplay].compactMap(\.self).joined(separator: " · ")
    }

    /// Whether an AVD with this profile can boot this image on this Mac.
    public func isCompatible(with profile: DeviceProfile, hostABIs: [String] = SystemImage.hostABIs) -> Bool {
        guard hostABIs.contains(abi) else { return false }
        if let minimum = profile.minAPILevel, apiNumber < minimum { return false }

        let imageKind = formFactor
        switch profile.category {
        case .phone, .foldable:
            return imageKind == .phone && !isTabletOnly
        case .tablet:
            return imageKind == .phone || imageKind == .tablet
        default:
            return imageKind == profile.category
        }
    }

    /// ABIs the emulator can run here: arm64 images on Apple silicon, x86 images on Intel.
    public static var hostABIs: [String] {
        #if arch(arm64)
        ["arm64-v8a"]
        #else
        ["x86_64", "x86"]
        #endif
    }
}

public enum SystemImages {
    /// Installed images, newest API first, Play Store images before others at the same level.
    public static func installed(in sdkRoot: URL) -> [SystemImage] {
        SDKInspector.systemImages(in: sdkRoot).compactMap { package -> SystemImage? in
            let folder = URL(fileURLWithPath: package.path, isDirectory: true)
            guard let properties = PropertiesFile.load(folder.appending(path: "source.properties")) else { return nil }
            let components = package.id.split(separator: ";").map(String.init)
            guard components.count == 4 else { return nil }

            let tagIDs = (properties["SystemImage.TagId"] ?? components[2]).split(separator: ",").map(String.init)
            return SystemImage(
                id: package.id,
                apiLevel: properties["AndroidVersion.ApiLevel"] ?? components[1].replacingOccurrences(of: "android-", with: ""),
                tagIDs: tagIDs,
                tagDisplay: properties["SystemImage.TagDisplay"]?.replacingOccurrences(of: ",", with: ", ") ?? components[2],
                abi: properties["SystemImage.Abi"] ?? components[3],
                revision: properties["Pkg.Revision"],
                path: folder.path
            )
        }
        .sorted { lhs, rhs in
            if lhs.apiNumber != rhs.apiNumber { return lhs.apiNumber > rhs.apiNumber }
            if lhs.hasPlayStore != rhs.hasPlayStore { return lhs.hasPlayStore }
            return lhs.id < rhs.id
        }
    }
}
