import Foundation

/// A package version, compared numerically (`27.1.12297006`, `36.0.0 rc3`).
public struct PackageRevision: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var micro: Int
    /// Release-candidate number; `nil` for a final release (which sorts after any preview).
    public var preview: Int?

    public init(major: Int, minor: Int = 0, micro: Int = 0, preview: Int? = nil) {
        self.major = major
        self.minor = minor
        self.micro = micro
        self.preview = preview
    }

    /// Parses `37.0.1`, `23.0`, `36.0.0 rc3` or `36.0.0-rc3`.
    public init?(_ string: String) {
        let lower = string.lowercased().trimmingCharacters(in: .whitespaces)
        var preview: Int?
        var numbers = lower
        if let range = lower.range(of: "rc") {
            preview = Int(lower[range.upperBound...].trimmingCharacters(in: .whitespaces))
            numbers = String(lower[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        }
        let parts = numbers.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(
            major: major,
            minor: parts.count > 1 ? parts[1]! : 0,
            micro: parts.count > 2 ? parts[2]! : 0,
            preview: preview
        )
    }

    public var description: String {
        var text = "\(major).\(minor).\(micro)"
        if let preview { text += " rc\(preview)" }
        return text
    }

    public static func < (lhs: PackageRevision, rhs: PackageRevision) -> Bool {
        if (lhs.major, lhs.minor, lhs.micro) != (rhs.major, rhs.minor, rhs.micro) {
            return (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro)
        }
        switch (lhs.preview, rhs.preview) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        default: return false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let revision = PackageRevision(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad revision \(text)"))
        }
        self = revision
    }
}

/// Release channel of a remote package.
public enum PackageChannel: Int, Sendable, Codable, Comparable, CaseIterable, CustomStringConvertible {
    case stable = 0, beta, dev, canary

    public var description: String { name }

    public var name: String {
        switch self {
        case .stable: "stable"
        case .beta: "beta"
        case .dev: "dev"
        case .canary: "canary"
        }
    }

    public static func < (lhs: PackageChannel, rhs: PackageChannel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Groups packages the way the SDK tab shows them.
public enum PackageCategory: String, Sendable, Codable, CaseIterable {
    case platforms, systemImages = "system-images", buildTools = "build-tools", ndk, cmake, tools, sources, other

    public var title: String {
        switch self {
        case .platforms: "SDK Platforms"
        case .systemImages: "System Images"
        case .buildTools: "Build Tools"
        case .ndk: "NDK"
        case .cmake: "CMake"
        case .tools: "SDK Tools"
        case .sources: "Sources"
        case .other: "Other"
        }
    }

    /// Category for a package id like `ndk;27.1.12297006`.
    public init(packageID: String) {
        switch packageID.split(separator: ";").first.map(String.init) ?? packageID {
        case "platforms": self = .platforms
        case "system-images": self = .systemImages
        case "build-tools": self = .buildTools
        case "ndk", "ndk-bundle": self = .ndk
        case "cmake": self = .cmake
        case "platform-tools", "emulator", "cmdline-tools", "tools": self = .tools
        case "sources": self = .sources
        default: self = .other
        }
    }
}

/// A package available from Google's SDK repository.
public struct RemotePackage: Sendable, Equatable, Codable, Identifiable {
    public struct Dependency: Sendable, Equatable, Codable {
        public var id: String
        public var minRevision: PackageRevision?
    }

    public struct Archive: Sendable, Equatable, Codable {
        public var url: URL
        public var size: Int64
        public var sha1: String
    }

    /// `sdkmanager`-style id, e.g. `system-images;android-36;google_apis;arm64-v8a`.
    public var id: String
    public var displayName: String
    public var revision: PackageRevision
    public var channel: PackageChannel
    public var obsolete: Bool
    public var licenseID: String?
    public var dependencies: [Dependency]
    /// The archive for this Mac, or nil if the package isn't available for it.
    public var archive: Archive?
    /// For platforms and system images.
    public var apiLevel: String?
    public var tagIDs: [String]
    public var tagDisplay: String?
    public var abi: String?
    /// Preview platforms and images carry a codename (`CANARY`, `DEV`…).
    public var codename: String? = nil

    public var category: PackageCategory { PackageCategory(packageID: id) }

    /// A pre-release: a release candidate, or a codenamed preview platform/image. Google
    /// publishes some of these on the stable channel; they're hidden there unless installed.
    public var isPreview: Bool { revision.preview != nil || !(codename ?? "").isEmpty }

    /// Numeric API level for sorting (`36.1` → 36.1), or nil for packages without one.
    public var apiNumber: Double? { apiLevel.flatMap(Double.init) }
}

public struct SDKLicense: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var text: String
}
