import Foundation

/// An installed SDK package, identified the way `sdkmanager` names it (e.g. `ndk;27.1.12297006`).
public struct InstalledPackage: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var version: String?
    public var path: String

    public init(id: String, version: String?, path: String) {
        self.id = id
        self.version = version
        self.path = path
    }
}

/// What's installed in an SDK, read straight from disk (no JVM tools involved).
public struct SDKInventory: Sendable, Equatable, Codable {
    public var cmdlineTools: [InstalledPackage]
    public var platformTools: InstalledPackage?
    public var emulator: InstalledPackage?
    public var buildTools: [InstalledPackage]
    public var platforms: [InstalledPackage]
    public var ndks: [InstalledPackage]
    public var cmake: [InstalledPackage]
    public var systemImages: [InstalledPackage]

    /// The `sdkmanager` to use: `cmdline-tools/latest` if present, otherwise the newest version.
    public var sdkmanagerPath: String? { preferredCmdlineTools.map { "\($0.path)/bin/sdkmanager" } }
    public var avdmanagerPath: String? { preferredCmdlineTools.map { "\($0.path)/bin/avdmanager" } }

    var preferredCmdlineTools: InstalledPackage? {
        cmdlineTools.first { $0.id == "cmdline-tools;latest" }
            ?? cmdlineTools.max { VersionComparator.isLess($0.version ?? "", $1.version ?? "") }
    }
}

public enum SDKInspector {
    public static func inventory(at root: URL) -> SDKInventory {
        SDKInventory(
            cmdlineTools: subpackages(of: root, folder: "cmdline-tools") { dir in
                FileManager.default.isExecutableFile(atPath: dir.appending(path: "bin/sdkmanager").path)
            },
            platformTools: package(at: root.appending(path: "platform-tools"), id: "platform-tools"),
            emulator: package(at: root.appending(path: "emulator"), id: "emulator"),
            buildTools: subpackages(of: root, folder: "build-tools"),
            platforms: subpackages(of: root, folder: "platforms"),
            ndks: subpackages(of: root, folder: "ndk"),
            cmake: subpackages(of: root, folder: "cmake"),
            systemImages: systemImages(in: root)
        )
    }

    /// A package living directly in a folder with a `source.properties`.
    static func package(at directory: URL, id: String) -> InstalledPackage? {
        guard let properties = PropertiesFile.load(directory.appending(path: "source.properties")) else { return nil }
        return InstalledPackage(id: id, version: properties["Pkg.Revision"], path: directory.path)
    }

    /// Side-by-side packages: `<folder>/<version>/source.properties` → `<folder>;<version>`.
    static func subpackages(
        of root: URL,
        folder: String,
        where include: (URL) -> Bool = { _ in true }
    ) -> [InstalledPackage] {
        let parent = root.appending(path: folder, directoryHint: .isDirectory)
        return childDirectories(of: parent)
            .filter(include)
            .compactMap { package(at: $0, id: "\(folder);\($0.lastPathComponent)") }
            .sorted { VersionComparator.isLess($1.id, $0.id) }
    }

    /// `system-images/<platform>/<tag>/<abi>` → `system-images;<platform>;<tag>;<abi>`.
    static func systemImages(in root: URL) -> [InstalledPackage] {
        let base = root.appending(path: "system-images", directoryHint: .isDirectory)
        var images: [InstalledPackage] = []
        for platform in childDirectories(of: base) {
            for tag in childDirectories(of: platform) {
                for abi in childDirectories(of: tag) {
                    let id = ["system-images", platform.lastPathComponent, tag.lastPathComponent, abi.lastPathComponent]
                        .joined(separator: ";")
                    if let image = package(at: abi, id: id) { images.append(image) }
                }
            }
        }
        return images.sorted { VersionComparator.isLess($1.id, $0.id) }
    }

    /// Child folders, with paths built from `url` so they keep the SDK root the user chose
    /// (`contentsOfDirectory(at:)` would resolve symlinks like `/var` → `/private/var`).
    static func childDirectories(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { url.appending(path: $0, directoryHint: .isDirectory) }
            .filter { child in
                // Follows symlinks (some people link cmdline-tools/latest or an NDK in).
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }
}
