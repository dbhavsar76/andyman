import Foundation

/// A JDK build offered by Eclipse Adoptium (Temurin).
public struct JDKRelease: Sendable, Equatable, Codable {
    public var major: Int
    /// `jdk-17.0.20.1+1`
    public var name: String
    public var url: URL
    public var size: Int64
    public var sha256: String

    /// `17.0.20.1`
    public var version: String {
        name.replacingOccurrences(of: "jdk-", with: "").components(separatedBy: "+").first ?? name
    }
}

public enum JDKInstallError: Error, Sendable, Equatable, LocalizedError {
    case noRelease(Int)
    case unexpectedArchive

    public var errorDescription: String? {
        switch self {
        case let .noRelease(major): "Couldn't find a JDK \(major) download for this Mac."
        case .unexpectedArchive: "The JDK download didn't contain a JDK."
        }
    }
}

/// Downloads and installs Eclipse Temurin JDKs where macOS (and `/usr/libexec/java_home`) finds them.
public struct JDKInstaller: Sendable {
    /// JDK versions offered in setup. 17 is what React Native's docs recommend.
    public static let offeredMajors = [17, 21]
    public static let recommendedMajor = 17
    /// Versions offered when adding a JDK from the Java section (current LTS releases).
    public static let installableMajors = [17, 21, 25]

    public static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Java/JavaVirtualMachines", directoryHint: .isDirectory)
    }

    public var destination: URL
    private let runner = ProcessRunner()

    public init(destination: URL = JDKInstaller.defaultDestination) {
        self.destination = destination
    }

    static var architecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x64"
        #endif
    }

    /// The newest build of a JDK major version for this Mac.
    public func latestRelease(major: Int) async throws -> JDKRelease {
        var components = URLComponents(string: "https://api.adoptium.net/v3/assets/latest/\(major)/hotspot")!
        components.queryItems = [
            .init(name: "architecture", value: Self.architecture),
            .init(name: "image_type", value: "jdk"),
            .init(name: "os", value: "mac"),
            .init(name: "vendor", value: "eclipse"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let release = Self.parseRelease(data, major: major) else { throw JDKInstallError.noRelease(major) }
        return release
    }

    static func parseRelease(_ data: Data, major: Int) -> JDKRelease? {
        struct Asset: Decodable {
            struct Binary: Decodable {
                struct Package: Decodable {
                    var link: URL
                    var size: Int64
                    var checksum: String
                }
                var package: Package
            }
            var binary: Binary
            var release_name: String
        }
        guard let asset = try? JSONDecoder().decode([Asset].self, from: data).first else { return nil }
        return JDKRelease(
            major: major,
            name: asset.release_name,
            url: asset.binary.package.link,
            size: asset.binary.package.size,
            sha256: asset.binary.package.checksum
        )
    }

    /// Downloads, verifies and installs a JDK as `<destination>/temurin-<major>.jdk`.
    public func install(
        _ release: JDKRelease,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void,
        extracting: @escaping @Sendable () -> Void = {}
    ) async throws -> JavaInstallation {
        let archive = try await Downloader().download(release.url, expectedSize: release.size, checksum: .sha256(release.sha256), progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        extracting()

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", staging.path], timeout: .seconds(300))
        guard result.succeeded,
              let bundle = SDKInspector.childDirectories(of: staging).first(where: {
                  FileManager.default.isExecutableFile(atPath: $0.appending(path: "Contents/Home/bin/java").path)
              })
        else { throw JDKInstallError.unexpectedArchive }

        var target = destination.appending(path: "temurin-\(release.major).jdk", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path) {
            target = destination.appending(path: "temurin-\(release.version).jdk", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
        }
        try FileManager.default.moveItem(at: bundle, to: target)

        let home = target.appending(path: "Contents/Home").path
        guard let installation = JavaLocator.installation(at: home, source: .javaHomeTool) else { throw JDKInstallError.unexpectedArchive }
        var named = installation
        named.name = "Eclipse Temurin \(release.major)"
        return named
    }
}
