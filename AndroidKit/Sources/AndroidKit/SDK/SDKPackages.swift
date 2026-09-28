import CryptoKit
import Foundation

/// One package as the SDK tab shows it: what's installed, and the newest available version.
public struct SDKPackage: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var installed: LocalPackage?
    /// Newest version on the chosen channel, if the repository offers one for this Mac.
    public var available: RemotePackage?

    public var category: PackageCategory { PackageCategory(packageID: id) }
    public var isInstalled: Bool { installed != nil }

    public var updateAvailable: Bool {
        guard let installed, let available else { return false }
        return installed.revision < available.revision
    }

    public var isObsolete: Bool { available?.obsolete ?? installed?.obsolete ?? false }
}

/// Combines the repository catalog with what's installed.
public struct SDKPackageList: Sendable, Equatable, Codable {
    public var packages: [SDKPackage]
    public var channel: PackageChannel

    public init(catalog: RepositoryCatalog?, installed: [LocalPackage], channel: PackageChannel = .stable) {
        self.channel = channel
        var byID: [String: SDKPackage] = [:]
        for remote in catalog?.latestPackages(channel: channel) ?? [] {
            byID[remote.id] = SDKPackage(id: remote.id, displayName: remote.displayName, installed: nil, available: remote)
        }
        for local in installed {
            if byID[local.id] != nil {
                byID[local.id]?.installed = local
            } else {
                byID[local.id] = SDKPackage(id: local.id, displayName: local.displayName, installed: local, available: nil)
            }
        }
        // Obsolete packages only matter if they're installed; so do previews on the stable
        // channel (old NDK RCs and codenamed platforms are published as "stable").
        packages = byID.values
            .filter { $0.isInstalled || !$0.isObsolete }
            .filter { $0.isInstalled || channel != .stable || $0.available?.isPreview != true }
            .sorted(by: Self.newestFirst)
    }

    /// Platforms and images by API level (previews after the final release of the same
    /// level), everything else by id, newest first.
    /// A total order (every pair compares consistently), which `sort` requires: packages
    /// with an API level come before those without, so the two kinds never interleave.
    static func newestFirst(_ lhs: SDKPackage, _ rhs: SDKPackage) -> Bool {
        let (leftAPI, rightAPI) = (lhs.available?.apiNumber, rhs.available?.apiNumber)
        switch (leftAPI, rightAPI) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let (leftPreview, rightPreview) = (lhs.available?.isPreview ?? false, rhs.available?.isPreview ?? false)
        if leftPreview != rightPreview { return !leftPreview }
        return VersionComparator.isLess(rhs.id, lhs.id)
    }

    public var updates: [SDKPackage] { packages.filter(\.updateAvailable) }

    public func packages(in category: PackageCategory) -> [SDKPackage] {
        packages.filter { $0.category == category }
    }

    public func package(_ id: String) -> SDKPackage? {
        let normalized = SDKPackageID.normalize(id)
        return packages.first { $0.id == normalized }
    }
}

public enum SDKPackageID {
    /// Accepts `platforms/android-36` (Android CLI style) as well as `platforms;android-36`.
    public static func normalize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: ";")
    }
}

/// What installing a set of packages involves: the packages (dependencies first), their
/// licenses, and how much will be downloaded.
public struct InstallPlan: Sendable, Equatable, Codable {
    public var packages: [RemotePackage]
    public var licenses: [SDKLicense]
    public var downloadSize: Int64

    public var isEmpty: Bool { packages.isEmpty }
}

public enum InstallPlanError: Error, Sendable, Equatable, LocalizedError {
    case unknownPackage(String)
    case unavailableHere(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownPackage(id): "There's no SDK package named \(id)."
        case let .unavailableHere(id): "\(id) isn't available for this Mac."
        }
    }
}

extension RepositoryCatalog {
    /// Resolves `ids` plus any dependencies that are missing or too old. Packages already at
    /// the newest version are skipped.
    public func installPlan(for ids: [String], installed: [LocalPackage], channel: PackageChannel = .stable) throws -> InstallPlan {
        var installedRevisions = Dictionary(installed.map { ($0.id, $0.revision) }, uniquingKeysWith: max)
        var ordered: [RemotePackage] = []
        var visiting = Set<String>()

        func add(_ id: String, minimum: PackageRevision?, requested: Bool) throws {
            guard !visiting.contains(id), !ordered.contains(where: { $0.id == id }) else { return }
            let current = installedRevisions[id]
            // A dependency that's already installed and new enough needs nothing.
            if !requested, let current, minimum.map({ current >= $0 }) ?? true { return }

            // Prefer the chosen channel; fall back to a less stable one only if that's the
            // only way to meet a minimum version (or the package exists nowhere else).
            var candidate = latest(id, channel: channel)
            if candidate == nil || minimum.map({ candidate!.revision < $0 }) == true {
                candidate = latest(id, channel: .canary) ?? candidate
            }
            guard let package = candidate else {
                if packages.contains(where: { $0.id == id }) { throw InstallPlanError.unavailableHere(id) }
                throw InstallPlanError.unknownPackage(id)
            }
            // Already at the newest version.
            if let current, current >= package.revision { return }

            visiting.insert(id)
            for dependency in package.dependencies {
                try add(dependency.id, minimum: dependency.minRevision, requested: false)
            }
            visiting.remove(id)
            ordered.append(package)
            installedRevisions[id] = package.revision
        }

        for id in ids.map(SDKPackageID.normalize) {
            try add(id, minimum: nil, requested: true)
        }
        let licenseIDs = Set(ordered.compactMap(\.licenseID))
        return InstallPlan(
            packages: ordered,
            licenses: licenseIDs.sorted().compactMap { licenses[$0] },
            downloadSize: ordered.compactMap(\.archive?.size).reduce(0, +)
        )
    }
}

/// Which SDK licenses have been accepted, recorded in `<sdk>/licenses/<id>` as sdkmanager does.
public struct LicenseStore: Sendable {
    public let sdkRoot: URL

    public init(sdkRoot: URL) {
        self.sdkRoot = sdkRoot
    }

    private var directory: URL { sdkRoot.appending(path: "licenses", directoryHint: .isDirectory) }

    public var acceptedIDs: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { !$0.hasPrefix(".") } ?? [])
    }

    public func isAccepted(_ id: String) -> Bool { acceptedIDs.contains(id) }

    public func unaccepted(in plan: InstallPlan) -> [SDKLicense] {
        let accepted = acceptedIDs
        return plan.licenses.filter { !accepted.contains($0.id) }
    }

    /// Records acceptance by adding the SHA-1 of the license text to its file.
    public func accept(_ license: SDKLicense) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: license.id)
        let hash = Insecure.SHA1.hash(data: Data(license.text.utf8)).map { String(format: "%02x", $0) }.joined()
        let existing = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !existing.contains(hash) else { return }
        try ((existing + [hash]).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
