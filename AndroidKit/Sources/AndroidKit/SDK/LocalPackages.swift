import Foundation

/// A package installed in the SDK, read from its `package.xml` (or a legacy `source.properties`).
public struct LocalPackage: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var revision: PackageRevision
    public var path: String
    public var obsolete: Bool
}

public enum LocalPackages {
    /// Folders never containing packages; skipped to keep the scan quick.
    static let skipped: Set<String> = ["licenses", "skins", "fonts", "patcher", "temp", "icons"]

    /// All installed packages. Stops descending at the first folder with a `package.xml`,
    /// so large packages (NDKs, system images) cost one lookup each.
    public static func scan(sdkRoot: URL, maxDepth: Int = 4) -> [LocalPackage] {
        var packages: [LocalPackage] = []
        var queue: [(URL, Int)] = [(sdkRoot, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            if depth > 0, let package = package(at: directory) {
                packages.append(package)
                continue
            }
            guard depth < maxDepth else { continue }
            for child in SDKInspector.childDirectories(of: directory) where !skipped.contains(child.lastPathComponent) {
                queue.append((child, depth + 1))
            }
        }
        return packages.sorted { $0.id < $1.id }
    }

    static func package(at directory: URL) -> LocalPackage? {
        let packageXML = directory.appending(path: "package.xml")
        if let data = try? Data(contentsOf: packageXML), let package = parsePackageXML(data, path: directory.path) {
            return package
        }
        // Very old installs only have source.properties.
        guard let properties = PropertiesFile.load(directory.appending(path: "source.properties")),
              let id = properties["Pkg.Path"],
              let revision = properties["Pkg.Revision"].flatMap(PackageRevision.init)
        else { return nil }
        return LocalPackage(id: id, displayName: properties["Pkg.Desc"] ?? id, revision: revision, path: directory.path, obsolete: false)
    }

    static func parsePackageXML(_ data: Data, path: String) -> LocalPackage? {
        let text = String(decoding: data, as: UTF8.self)
        guard let local = text.firstMatch(of: /<localPackage\s+path="([^"]+)"(?:\s+obsolete="(true|false)")?/) else { return nil }

        // The package's own <revision> comes before any dependency's <min-revision>.
        func number(_ name: String, in block: Substring) -> Int? {
            guard let match = block.firstMatch(of: try! Regex("<\(name)>\\s*(\\d+)\\s*</\(name)>")) else { return nil }
            return Int(match.output[1].substring ?? "")
        }
        guard let revisionStart = text.range(of: "<revision>"),
              let revisionEnd = text.range(of: "</revision>", range: revisionStart.upperBound..<text.endIndex)
        else { return nil }
        let block = text[revisionStart.upperBound..<revisionEnd.lowerBound]
        guard let major = number("major", in: block) else { return nil }
        let revision = PackageRevision(
            major: major,
            minor: number("minor", in: block) ?? 0,
            micro: number("micro", in: block) ?? 0,
            preview: number("preview", in: block)
        )

        let displayName = text.firstMatch(of: /<display-name>([^<]*)<\/display-name>/).map { String($0.1) } ?? String(local.1)
        return LocalPackage(
            id: String(local.1),
            displayName: displayName,
            revision: revision,
            path: path,
            obsolete: local.2 == "true"
        )
    }
}
