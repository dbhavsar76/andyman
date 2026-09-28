import Foundation

public enum BootstrapError: Error, Sendable, Equatable, LocalizedError {
    case notInCatalog
    case unexpectedArchive

    public var errorDescription: String? {
        switch self {
        case .notInCatalog: "The Android SDK Command-line Tools aren't available for this Mac."
        case .unexpectedArchive: "The Command-line Tools download didn't have the expected contents."
        }
    }
}

/// Installs the first package into an empty SDK: the command-line tools, which provide the
/// `android` CLI (and `sdkmanager`) that install everything else.
///
/// They can't install themselves, so this downloads the zip directly, then lays it out the way
/// the tools expect: `<sdk>/cmdline-tools/latest/` (the zip contains a bare `cmdline-tools/`
/// folder — putting that directly in the SDK is the classic setup mistake).
public struct CommandLineToolsBootstrap: Sendable {
    public static let packageID = "cmdline-tools;latest"

    public let sdkRoot: URL
    private let runner = ProcessRunner()

    public init(sdkRoot: URL) {
        self.sdkRoot = sdkRoot
    }

    /// Whether the SDK lacks working command-line tools.
    public var isNeeded: Bool {
        !SDKInstaller(sdkRoot: sdkRoot, java: nil, environment: [:]).isAvailable
    }

    public func install(
        from catalog: RepositoryCatalog,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void,
        extracting: @escaping @Sendable () -> Void = {}
    ) async throws {
        guard let package = catalog.latest(Self.packageID), let archive = package.archive else { throw BootstrapError.notInCatalog }
        let zip = try await Downloader().download(archive.url, expectedSize: archive.size, checksum: .sha1(archive.sha1), progress: progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        extracting()

        try FileManager.default.createDirectory(at: sdkRoot, withIntermediateDirectories: true)
        let staging = sdkRoot.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        // ditto keeps the executable bits and symlinks inside the zip.
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, staging.path], timeout: .seconds(300))
        let extracted = staging.appending(path: "cmdline-tools", directoryHint: .isDirectory)
        guard result.succeeded, FileManager.default.fileExists(atPath: extracted.appending(path: "bin").path) else {
            throw BootstrapError.unexpectedArchive
        }

        let parent = sdkRoot.appending(path: "cmdline-tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appending(path: "latest", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path) {
            // A broken leftover (isNeeded was true); keep it out of the way rather than deleting it.
            let aside = parent.appending(path: "latest-old-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.moveItem(at: target, to: aside)
        }
        try FileManager.default.moveItem(at: extracted, to: target)
        try Self.packageXML(for: package).write(to: target.appending(path: "package.xml"), atomically: true, encoding: .utf8)
    }

    /// The metadata the SDK tools write for an installed package, so they (and we) recognise it.
    static func packageXML(for package: RemotePackage) -> String {
        let revision = package.revision
        let license = package.licenseID.map { "\n    <uses-license ref=\"\($0)\" />" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns5="http://schemas.android.com/repository/android/generic/02">
          <localPackage path="\(package.id)" obsolete="false">
            <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns5:genericDetailsType" />
            <revision>
              <major>\(revision.major)</major>
              <minor>\(revision.minor)</minor>
              <micro>\(revision.micro)</micro>
            </revision>
            <display-name>\(package.displayName)</display-name>\(license)
          </localPackage>
        </ns2:repository>

        """
    }
}
