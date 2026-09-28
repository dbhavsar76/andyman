import Foundation

/// Where a resolved path (SDK root, JDK home) came from.
///
/// Encodes to a short string in JSON: `flag`, `settings`, `env:ANDROID_HOME`, `default`,
/// `java_home`, `known_location`.
public enum LocationSource: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Passed explicitly on the command line (`--sdk`).
    case flag
    /// Set in the app's settings.
    case settings
    /// Read from an environment variable.
    case environment(String)
    /// Set by the user's shell profile, but not in the calling process's environment
    /// (see `LoginEnvironment`).
    case shellProfile(String)
    /// The conventional location (`~/Library/Android/sdk`).
    case defaultLocation
    /// Reported by `/usr/libexec/java_home`.
    case javaHomeTool
    /// Found by scanning a well-known install directory.
    case knownLocation

    public var description: String {
        switch self {
        case .flag: "flag"
        case .settings: "settings"
        case let .environment(variable): "env:\(variable)"
        case let .shellProfile(variable): "profile:\(variable)"
        case .defaultLocation: "default"
        case .javaHomeTool: "java_home"
        case .knownLocation: "known_location"
        }
    }

    /// A phrase for UI, e.g. "from ANDROID_HOME".
    public var displayName: String {
        switch self {
        case .flag: "from --sdk"
        case .settings: "set in Settings"
        case let .environment(variable): "from \(variable)"
        case let .shellProfile(variable): "\(variable) from your shell profile"
        case .defaultLocation: "default location"
        case .javaHomeTool: "found by java_home"
        case .knownLocation: "found on disk"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "flag": self = .flag
        case "settings": self = .settings
        case "default": self = .defaultLocation
        case "java_home": self = .javaHomeTool
        case "known_location": self = .knownLocation
        case let value where value.hasPrefix("env:"):
            self = .environment(String(value.dropFirst(4)))
        case let value where value.hasPrefix("profile:"):
            self = .shellProfile(String(value.dropFirst(8)))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown source \(raw)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
