import Foundation

/// Every package Google's SDK repository offers (all versions and channels), plus license texts.
public struct RepositoryCatalog: Sendable, Codable, Equatable {
    public var packages: [RemotePackage]
    public var licenses: [String: SDKLicense]
    public var fetchedAt: Date

    public init(packages: [RemotePackage], licenses: [String: SDKLicense], fetchedAt: Date) {
        self.packages = packages
        self.licenses = licenses
        self.fetchedAt = fetchedAt
    }

    /// Newest version of a package available on `channel` (or a more stable one) for this Mac.
    public func latest(_ id: String, channel: PackageChannel = .stable) -> RemotePackage? {
        packages
            .filter { $0.id == id && $0.channel <= channel && $0.archive != nil }
            .max { $0.revision < $1.revision }
    }

    /// One entry per package id: its newest version on `channel`.
    public func latestPackages(channel: PackageChannel = .stable) -> [RemotePackage] {
        var best: [String: RemotePackage] = [:]
        for package in packages where package.channel <= channel && package.archive != nil {
            if let current = best[package.id], current.revision >= package.revision { continue }
            best[package.id] = package
        }
        return Array(best.values)
    }
}

public enum RepositoryError: Error, Sendable, LocalizedError {
    case offline(String)

    public var errorDescription: String? {
        switch self {
        case let .offline(reason): "Couldn't reach Google's SDK repository: \(reason)"
        }
    }
}

/// Downloads and caches the SDK repository catalog.
public struct RepositoryClient: Sendable {
    public static let baseURL = URL(string: "https://dl.google.com/android/repository/")!
    public static let repositoryFile = "repository2-3.xml"
    public static let siteListFile = "addons_list-5.xml"

    /// Shared by the app and the CLI so either benefits from the other's download.
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/\(SharedPreferences.suiteName)/repository", directoryHint: .isDirectory)
    }

    public var cacheDirectory: URL
    public var host: HostPlatform

    public init(cacheDirectory: URL = RepositoryClient.defaultCacheDirectory, host: HostPlatform = .current) {
        self.cacheDirectory = cacheDirectory
        self.host = host
    }

    /// Bump the version when `RemotePackage` gains fields, so stale caches are re-downloaded.
    private var cacheFile: URL { cacheDirectory.appending(path: "catalog-v2.json") }

    /// The cached catalog if it's younger than `maxAge`, otherwise a fresh download.
    /// If the download fails, falls back to an older cache rather than failing.
    public func catalog(maxAge: TimeInterval = 24 * 60 * 60, forceRefresh: Bool = false) async throws -> RepositoryCatalog {
        let cached = cachedCatalog()
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached
        }
        do {
            let fresh = try await download()
            try? save(fresh)
            return fresh
        } catch {
            if let cached { return cached }
            throw RepositoryError.offline(error.localizedDescription)
        }
    }

    public func cachedCatalog() -> RepositoryCatalog? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RepositoryCatalog.self, from: data)
    }

    private func save(_ catalog: RepositoryCatalog) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(to: cacheFile, options: .atomic)
    }

    /// Fetches the main repository and every system image / add-on site in parallel.
    func download() async throws -> RepositoryCatalog {
        let base = Self.baseURL
        let siteList = try await fetch(base.appending(path: Self.siteListFile))
        let sites = [base.appending(path: Self.repositoryFile)] + SiteListParser.siteURLs(siteList, baseURL: base)
        let host = host

        let results = try await withThrowingTaskGroup(of: (Int, RepositoryParser.Result).self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    let data = try await fetch(site)
                    return (index, RepositoryParser.parse(data, baseURL: site.deletingLastPathComponent(), host: host))
                }
            }
            var collected: [(Int, RepositoryParser.Result)] = []
            for try await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var licenses: [String: SDKLicense] = [:]
        for license in results.flatMap(\.licenses) where licenses[license.id] == nil {
            licenses[license.id] = license
        }
        return RepositoryCatalog(packages: results.flatMap(\.packages), licenses: licenses, fetchedAt: Date())
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Andyman", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        return data
    }
}
