import Foundation

/// Which archive to pick from a package's per-OS/arch list.
public struct HostPlatform: Sendable, Equatable {
    /// `macosx`, `linux` or `windows`, as used in the repository XML.
    public var os: String
    /// `aarch64` or `x64`.
    public var arch: String

    public static let current: HostPlatform = {
        #if arch(arm64)
        HostPlatform(os: "macosx", arch: "aarch64")
        #else
        HostPlatform(os: "macosx", arch: "x64")
        #endif
    }()
}

/// Parses Google's SDK repository XML (`repository2-3.xml`, `sys-img2-3.xml`, `addon2-3.xml`).
///
/// All three share the same `remotePackage` structure; only `type-details` differ.
final class RepositoryParser: NSObject, XMLParserDelegate {
    struct Result {
        var packages: [RemotePackage] = []
        var licenses: [SDKLicense] = []
    }

    private struct ArchiveDraft {
        var url: String?
        var size: Int64?
        var sha1: String?
        var hostOS: String?
        var hostArch: String?
    }

    private struct PackageDraft {
        var id: String
        var obsolete: Bool
        var displayName = ""
        var revision: [String: Int] = [:]
        var channelRef: String?
        var licenseRef: String?
        var dependencies: [RemotePackage.Dependency] = []
        var currentDependency: (id: String, revision: [String: Int])?
        var archives: [ArchiveDraft] = []
        var currentArchive: ArchiveDraft?
        var apiLevel: String?
        var extensionLevel: String?
        var tagIDs: [String] = []
        var tagDisplays: [String] = []
        var abi: String?
        var codename: String?
    }

    private let baseURL: URL
    private let host: HostPlatform
    private var result = Result()
    private var channels: [String: PackageChannel] = [:]
    private var draft: PackageDraft?
    private var licenseID: String?
    private var channelID: String?
    private var path: [String] = []
    private var text = ""

    private init(baseURL: URL, host: HostPlatform) {
        self.baseURL = baseURL
        self.host = host
    }

    /// - Parameter baseURL: archive URLs in the document are relative to this.
    static func parse(_ data: Data, baseURL: URL, host: HostPlatform = .current) -> Result {
        let delegate = RepositoryParser(baseURL: baseURL, host: host)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(elementName)
        text = ""
        switch elementName {
        case "license":
            licenseID = attributes["id"]
        case "channel":
            channelID = attributes["id"]
        case "remotePackage":
            if let id = attributes["path"] {
                draft = PackageDraft(id: id, obsolete: attributes["obsolete"] == "true")
            }
        case "channelRef":
            draft?.channelRef = attributes["ref"]
        case "uses-license":
            draft?.licenseRef = attributes["ref"]
        case "dependency":
            if let id = attributes["path"] { draft?.currentDependency = (id, [:]) }
        case "archive":
            draft?.currentArchive = ArchiveDraft()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let parent = path.dropLast().last
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if draft == nil {
            switch elementName {
            case "license":
                if let licenseID { result.licenses.append(SDKLicense(id: licenseID, text: text)) }
                licenseID = nil
            case "channel":
                if let channelID, let channel = PackageChannel.named(value) { channels[channelID] = channel }
                channelID = nil
            default:
                break
            }
            return
        }

        switch elementName {
        case "display-name" where parent == "remotePackage":
            draft?.displayName = value
        case "major", "minor", "micro", "preview":
            let number = Int(value) ?? 0
            if parent == "revision" {
                draft?.revision[elementName] = number
            } else if parent == "min-revision" {
                draft?.currentDependency?.revision[elementName] = number
            }
        case "dependency":
            if let dependency = draft?.currentDependency {
                draft?.dependencies.append(.init(id: dependency.id, minRevision: Self.revision(dependency.revision)))
            }
            draft?.currentDependency = nil
        case "api-level" where parent == "type-details":
            draft?.apiLevel = value
        case "extension-level" where parent == "type-details":
            draft?.extensionLevel = value
        case "codename" where parent == "type-details":
            draft?.codename = value
        case "id" where parent == "tag" || parent == "tags":
            draft?.tagIDs.append(value)
        case "display" where parent == "tag":
            draft?.tagDisplays.append(value)
        case "abi" where parent == "type-details" || parent == "abis":
            if draft?.abi == nil { draft?.abi = value }
        case "size" where parent == "complete":
            draft?.currentArchive?.size = Int64(value)
        case "checksum" where parent == "complete":
            draft?.currentArchive?.sha1 = value
        case "url" where parent == "complete":
            draft?.currentArchive?.url = value
        case "host-os":
            draft?.currentArchive?.hostOS = value
        case "host-arch":
            draft?.currentArchive?.hostArch = value
        case "archive":
            if let archive = draft?.currentArchive { draft?.archives.append(archive) }
            draft?.currentArchive = nil
        case "remotePackage":
            if let draft, let package = makePackage(draft) { result.packages.append(package) }
            draft = nil
        default:
            break
        }
    }

    private func makePackage(_ draft: PackageDraft) -> RemotePackage? {
        guard let revision = Self.revision(draft.revision) else { return nil }
        return RemotePackage(
            id: draft.id,
            displayName: draft.displayName,
            revision: revision,
            channel: draft.channelRef.flatMap { channels[$0] } ?? .stable,
            obsolete: draft.obsolete,
            licenseID: draft.licenseRef,
            dependencies: draft.dependencies,
            archive: hostArchive(draft.archives),
            apiLevel: draft.apiLevel,
            tagIDs: draft.tagIDs,
            tagDisplay: draft.tagDisplays.isEmpty ? nil : draft.tagDisplays.joined(separator: ", "),
            abi: draft.abi,
            codename: draft.codename
        )
    }

    /// The archive that runs here: exact OS + arch, then OS only, then platform-independent.
    private func hostArchive(_ archives: [ArchiveDraft]) -> RemotePackage.Archive? {
        // Only `<complete>` downloads are read; incremental `<patches>` are ignored.
        let complete = archives.filter { $0.url != nil && $0.size != nil && $0.sha1 != nil }
        let match = complete.first { $0.hostOS == host.os && $0.hostArch == host.arch }
            ?? complete.first { $0.hostOS == host.os && $0.hostArch == nil }
            ?? complete.first { $0.hostOS == nil }
        guard let match, let urlString = match.url, let size = match.size, let sha1 = match.sha1 else { return nil }
        guard let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL else { return nil }
        return .init(url: url, size: size, sha1: sha1)
    }

    static func revision(_ parts: [String: Int]) -> PackageRevision? {
        guard let major = parts["major"] else { return nil }
        return PackageRevision(major: major, minor: parts["minor"] ?? 0, micro: parts["micro"] ?? 0, preview: parts["preview"])
    }
}

extension PackageChannel {
    public static func named(_ name: String) -> PackageChannel? {
        allCases.first { $0.name == name }
    }
}

/// Parses `addons_list-5.xml`, the index of system image and add-on sites.
enum SiteListParser {
    static func siteURLs(_ data: Data, baseURL: URL) -> [URL] {
        let text = String(decoding: data, as: UTF8.self)
        let pattern = /<url>\s*([^<\s]+)\s*<\/url>/
        return text.matches(of: pattern).compactMap { URL(string: String($0.1), relativeTo: baseURL)?.absoluteURL }
    }
}
