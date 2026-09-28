import Foundation

/// An Android Virtual Device, read from `<name>.ini` and `<folder>/config.ini`.
public struct VirtualDevice: Sendable, Equatable, Codable, Identifiable {
    /// Device categories, matching Android Studio's device picker (Legacy profiles are
    /// old phones and tablets, so they map to those).
    public enum FormFactor: String, Sendable, Codable, CaseIterable {
        case phone, foldable, tablet, wear, desktop, tv, automotive, xr, glasses

        public var title: String {
            switch self {
            case .phone: "Phone"
            case .foldable: "Foldable"
            case .tablet: "Tablet"
            case .wear: "Wear OS"
            case .desktop: "Desktop"
            case .tv: "TV"
            case .automotive: "Automotive"
            case .xr: "XR Headset"
            case .glasses: "Glasses"
            }
        }
    }

    /// Encodes as `{"code": "system_image_missing", "package": "…"}` for the CLI's JSON.
    public enum Problem: Sendable, Equatable, Codable {
        /// The system image the AVD boots from isn't installed in the SDK.
        case systemImageMissing(package: String)
        /// `config.ini` is missing or unreadable.
        case configMissing

        private enum CodingKeys: String, CodingKey { case code, package }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .code) {
            case "system_image_missing": self = .systemImageMissing(package: try container.decode(String.self, forKey: .package))
            default: self = .configMissing
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .systemImageMissing(package):
                try container.encode("system_image_missing", forKey: .code)
                try container.encode(package, forKey: .package)
            case .configMissing:
                try container.encode("config_missing", forKey: .code)
            }
        }
    }

    /// The AVD name used with `emulator -avd` (the `.ini` file's name).
    public var name: String
    public var displayName: String
    /// The `.avd` folder. Its name can differ from `name` after a rename.
    public var path: String
    public var iniPath: String
    /// API level as written in `target`, e.g. `36` or `37.1`.
    public var apiLevel: String?
    public var abi: String?
    /// `google_apis`, `google_apis_playstore`, `default`, `android-tv`…
    public var tagID: String?
    public var tagDisplay: String?
    public var playStore: Bool
    public var deviceName: String?
    public var manufacturer: String?
    public var formFactor: FormFactor
    public var ramMB: Int?
    public var screenWidth: Int?
    public var screenHeight: Int?
    public var screenDensity: Int?
    public var dataPartitionSize: String?
    /// `system-images;android-36;google_apis_playstore;arm64-v8a`
    public var systemImagePackage: String?
    public var problems: [Problem]

    public var id: String { name }
    public var canLaunch: Bool { problems.isEmpty }

    /// "Android 16", or nil for unknown API levels.
    public var androidVersion: String? {
        apiLevel.flatMap { AndroidRelease.versionName(forAPILevel: $0) }.map { "Android \($0)" }
    }

    /// "Android 16 · API 36 · Google Play" style summary.
    public var summary: String {
        var parts: [String] = []
        if let androidVersion { parts.append(androidVersion) }
        if let apiLevel { parts.append("API \(apiLevel)") }
        if playStore {
            parts.append("Google Play")
        } else if let tagDisplay, !tagDisplay.isEmpty {
            parts.append(tagDisplay)
        }
        return parts.joined(separator: " · ")
    }
}

public enum AndroidRelease {
    private static let versions: [Int: String] = [
        21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9",
        29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17",
    ]

    /// Marketing version for an API level like `36` or `36.1`.
    public static func versionName(forAPILevel apiLevel: String) -> String? {
        guard let major = Int(apiLevel.split(separator: ".").first ?? "") else { return nil }
        return versions[major]
    }
}
