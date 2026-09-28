import Foundation

/// Settings shared between the app and the `andyman` CLI.
///
/// Both read the app's defaults domain, so a path chosen in the app's settings is also what
/// the CLI uses. This works because the app isn't sandboxed.
public struct SharedPreferences: Sendable {
    public static let suiteName = "dev.dhruvbhavsar.Andyman"

    enum Key {
        static let sdkPath = "sdkPathOverride"
        static let javaHome = "javaHomeOverride"
        static let sdkChannel = "sdkChannel"
    }

    private let suiteName: String

    public init(suiteName: String = SharedPreferences.suiteName) {
        self.suiteName = suiteName
    }

    /// `UserDefaults` isn't `Sendable`, so each access gets its own instance.
    private var defaults: UserDefaults {
        // Using your own bundle identifier as a suite name isn't allowed; use `.standard` there.
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    public var sdkPathOverride: String? {
        get { nonEmpty(defaults.string(forKey: Key.sdkPath)) }
        nonmutating set { defaults.set(nonEmpty(newValue), forKey: Key.sdkPath) }
    }

    public var javaHomeOverride: String? {
        get { nonEmpty(defaults.string(forKey: Key.javaHome)) }
        nonmutating set { defaults.set(nonEmpty(newValue), forKey: Key.javaHome) }
    }

    /// Release channel for SDK packages shown in the app.
    public var sdkChannel: PackageChannel {
        get { PackageChannel(rawValue: defaults.integer(forKey: Key.sdkChannel)) ?? .stable }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.sdkChannel) }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
