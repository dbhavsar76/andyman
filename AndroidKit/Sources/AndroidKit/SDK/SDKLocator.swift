import Foundation

public struct SDKLocation: Sendable, Equatable, Codable {
    public var path: String
    public var source: LocationSource

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(path: String, source: LocationSource) {
        self.path = path
        self.source = source
    }
}

/// Finds the Android SDK root.
///
/// Order: `--sdk` flag → app settings → `ANDROID_HOME` → `ANDROID_SDK_ROOT` → `~/Library/Android/sdk`.
/// An explicit choice (flag or settings) is returned even when it's invalid, so the user
/// hears about their broken setting instead of silently getting a different SDK.
/// Environment variables and the default location are skipped when they don't hold an SDK.
public struct SDKLocator: Sendable {
    public struct Candidate: Sendable, Equatable, Codable {
        public var path: String
        public var source: LocationSource
        public var problem: Problem?

        public enum Problem: String, Sendable, Codable {
            case missing
            case notAnSDK = "not_an_sdk"
        }
    }

    public struct Resolution: Sendable, Equatable {
        /// The SDK to use, if any. Check `selectedCandidate.problem` before trusting it.
        public var location: SDKLocation?
        /// Every place that was considered, in priority order.
        public var candidates: [Candidate]

        public var selectedCandidate: Candidate? {
            guard let location else { return nil }
            return candidates.first { $0.path == location.path && $0.source == location.source }
        }

        public var isValid: Bool { location != nil && selectedCandidate?.problem == nil }
    }

    /// Top-level folders an SDK usually has; any one of them is enough to recognise it.
    static let markerDirectories = [
        "platform-tools", "cmdline-tools", "emulator", "platforms",
        "build-tools", "system-images", "licenses", "ndk",
    ]

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Android/sdk", directoryHint: .isDirectory).path
    }

    public init() {}

    public func resolve(
        flag: String? = nil,
        settings: String? = nil,
        environment: [String: String],
        defaultPath: String = SDKLocator.defaultPath
    ) -> Resolution {
        var candidates: [Candidate] = []

        for (path, source) in [(flag, LocationSource.flag), (settings, .settings)] {
            guard let path else { continue }
            let candidate = inspect(path, source: source)
            candidates.append(candidate)
            return Resolution(location: SDKLocation(path: candidate.path, source: source), candidates: candidates)
        }

        var fallbacks: [(String, LocationSource)] = []
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[variable], !value.isEmpty {
                fallbacks.append((value, .environment(variable)))
            }
        }
        fallbacks.append((defaultPath, .defaultLocation))

        for (path, source) in fallbacks {
            let candidate = inspect(path, source: source)
            candidates.append(candidate)
            if candidate.problem == nil {
                return Resolution(location: SDKLocation(path: candidate.path, source: source), candidates: candidates)
            }
        }
        return Resolution(location: nil, candidates: candidates)
    }

    func inspect(_ rawPath: String, source: LocationSource) -> Candidate {
        let path = URL(fileURLWithPath: ShellEnvironment.expandTilde(rawPath)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Candidate(path: path, source: source, problem: .missing)
        }
        let looksLikeSDK = Self.markerDirectories.contains {
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
        return Candidate(path: path, source: source, problem: looksLikeSDK ? nil : .notAnSDK)
    }
}
