import AndroidKit
import ArgumentParser
import Foundation

extension PackageChannel: ExpressibleByArgument {
    public init?(argument: String) {
        guard let channel = PackageChannel.named(argument.lowercased()) else { return nil }
        self = channel
    }

    public static var allValueStrings: [String] { allCases.map(\.name) }
    public var defaultValueDescription: String { name }
}

extension PackageCategory: ExpressibleByArgument {}

/// Options for commands that read the repository catalog.
struct CatalogOptions: ParsableArguments {
    @Option(name: .customLong("channel"), help: "Release channel: stable (default), beta, dev or canary.") var channelOption: PackageChannel?
    var channel: PackageChannel { channelOption ?? .stable }
    @Flag(help: "Re-download the package catalog instead of using the cached copy (refreshed daily).") var refresh = false
}

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "List, install, update and remove SDK packages.",
        discussion: """
        Package IDs use sdkmanager syntax (platforms;android-36) or Android CLI syntax \
        (platforms/android-36). Installing a package whose license hasn't been accepted fails \
        with exit code 4; review it with `andyman licenses show <id>`, then pass --accept-licenses.
        """,
        subcommands: [List.self, Install.self, Update.self, Uninstall.self]
    )
}

extension CommandContext {
    func catalog(_ options: CatalogOptions) async throws -> RepositoryCatalog {
        try await catalog(refresh: options.refresh)
    }

    func catalog(refresh: Bool = false) async throws -> RepositoryCatalog {
        do {
            return try await RepositoryClient().catalog(forceRefresh: refresh)
        } catch {
            throw CLIError(code: "repository_unavailable", message: error.localizedDescription, hint: "Check your internet connection.")
        }
    }

    func installer() async throws -> SDKInstaller {
        SDKInstaller(sdkRoot: try requireSDK().url, java: await java(), environment: environment)
    }
}

extension SDKCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List SDK packages.",
            discussion: "Without filters, lists installed packages and marks available updates."
        )

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions
        @Flag(help: "Only packages with updates.") var updates = false
        @Flag(help: "Packages available to install (not installed).") var available = false
        @Flag(help: "Installed and available packages.") var all = false
        @Option(help: "Only this category: \(PackageCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
        var category: PackageCategory?

        func run() async throws {
            let context = CommandContext(options)
            let sdk = try context.requireSDK()
            let catalog = try await context.catalog(catalogOptions)
            let list = SDKPackageList(catalog: catalog, installed: LocalPackages.scan(sdkRoot: sdk.url), channel: catalogOptions.channel)

            var packages = list.packages.sorted { VersionComparator.isLess($0.id, $1.id) }
            if let category { packages = packages.filter { $0.category == category } }
            if updates {
                packages = packages.filter(\.updateAvailable)
            } else if available {
                packages = packages.filter { !$0.isInstalled }
            } else if !all {
                packages = packages.filter(\.isInstalled)
            }

            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var channel: String
                    var packages: [SDKPackage]
                }
                try Output.json(Payload(channel: catalogOptions.channel.name, packages: packages))
                return
            }
            guard !packages.isEmpty else {
                Output.line(updates ? "Everything is up to date." : "No matching packages.")
                return
            }
            let style = Style.current
            Output.table(
                header: ["PACKAGE", "INSTALLED", "LATEST", "SIZE"],
                rows: packages.map { package in
                    let latest = package.available.map { "\($0.revision)" } ?? "–"
                    return [
                        package.id,
                        package.installed.map { "\($0.revision)" } ?? style.dim("–"),
                        package.updateAvailable ? style.yellow(latest) : latest,
                        package.available?.archive.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? "–",
                    ]
                }
            )
            let updateCount = packages.filter(\.updateAvailable).count
            if updateCount > 0, !updates {
                Output.line()
                Output.line(style.yellow("\(updateCount) update(s) available.") + style.dim(" Run `andyman sdk update` to install them."))
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install SDK packages (and any dependencies they need).",
            discussion: """
            With --json, prints one JSON object per line as the install progresses (events: \
            plan, started, progress, unpacking, finished), ending with a `done` event.
            """
        )

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions
        @Argument(help: "Package IDs, e.g. \"platforms;android-36\" or ndk/27.1.12297006.") var packages: [String]
        @Flag(help: "Accept the licenses of the packages being installed.") var acceptLicenses = false
        @Flag(help: "Show what would be installed (packages, sizes, licenses) without installing.") var dryRun = false

        func run() async throws {
            if dryRun {
                let plan = try await SDKCommand.plan(packages, options: options, refresh: catalogOptions.refresh, channel: catalogOptions.channel)
                try plan.print(json: options.json)
                return
            }
            try await SDKCommand.install(packages, options: options, catalogOptions: catalogOptions, acceptLicenses: acceptLicenses)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update installed packages to their newest versions.")

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions
        @Argument(help: "Packages to update. Updates everything with an update if omitted.") var packages: [String] = []
        @Flag(help: "Accept the licenses of the packages being updated.") var acceptLicenses = false

        func run() async throws {
            var ids = packages
            if ids.isEmpty {
                let context = CommandContext(options)
                let catalog = try await context.catalog(catalogOptions)
                let list = SDKPackageList(catalog: catalog, installed: LocalPackages.scan(sdkRoot: try context.requireSDK().url), channel: catalogOptions.channel)
                ids = list.updates.map(\.id)
            }
            guard !ids.isEmpty else {
                try Output.result(json: options.json, message: "Everything is up to date.", fields: ["installed": [String]()])
                return
            }
            try await SDKCommand.install(ids, options: options, catalogOptions: catalogOptions, acceptLicenses: acceptLicenses)
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove SDK packages.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "Package IDs to remove.") var packages: [String]
        @Flag(help: "Confirm the removal.") var yes = false

        func run() async throws {
            guard yes else { throw CLIError.confirmationRequired("Removing \(packages.joined(separator: ", "))") }
            let context = CommandContext(options)
            let installed = LocalPackages.scan(sdkRoot: try context.requireSDK().url)
            let ids = packages.map(SDKPackageID.normalize)
            for id in ids where !installed.contains(where: { $0.id == id }) {
                throw CLIError(code: "not_installed", message: "\(id) isn't installed.", exitStatus: .notFound)
            }
            do {
                try await context.installer().uninstall(ids)
            } catch {
                throw CLIError(sdkError: error)
            }
            try Output.result(json: options.json, message: "Removed \(ids.joined(separator: ", ")).", fields: ["removed": ids])
        }
    }

    /// What installing `ids` involves, without installing: for `--dry-run`.
    struct PlanPreview: Encodable {
        struct Package: Encodable { var id: String; var displayName: String; var size: Int64? }
        struct License: Encodable { var id: String; var accepted: Bool }
        var schemaVersion = Output.schemaVersion
        var dryRun = true
        var packages: [Package]
        var downloadSize: Int64
        var downloadSizeText: String { ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file) }
        var licenses: [License]
        /// True when a license needs accepting first (ask the user, then pass --accept-licenses).
        var needsLicenseAcceptance: Bool { licenses.contains { !$0.accepted } }

        private enum CodingKeys: String, CodingKey { case schemaVersion, dryRun, packages, downloadSize, downloadSizeText, licenses, needsLicenseAcceptance }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(dryRun, forKey: .dryRun)
            try container.encode(packages, forKey: .packages)
            try container.encode(downloadSize, forKey: .downloadSize)
            try container.encode(downloadSizeText, forKey: .downloadSizeText)
            try container.encode(licenses, forKey: .licenses)
            try container.encode(needsLicenseAcceptance, forKey: .needsLicenseAcceptance)
        }

        func print(json: Bool) throws {
            if json { try Output.json(self); return }
            guard !packages.isEmpty else { Output.line("Already installed and up to date."); return }
            let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            Output.line("Would install:")
            for package in packages { Output.line("  \(package.id)" + (package.size.map { " (\(size($0)))" } ?? "")) }
            Output.line("Download: \(size(downloadSize))")
            let unaccepted = licenses.filter { !$0.accepted }.map(\.id)
            Output.line(unaccepted.isEmpty ? "Licenses: all accepted" : "Licenses to accept: \(unaccepted.joined(separator: ", ")) (see `andyman licenses show <id>`)")
        }
    }

    static func plan(_ ids: [String], options: GlobalOptions, refresh: Bool = false, channel: PackageChannel = .stable) async throws -> PlanPreview {
        let context = CommandContext(options)
        let sdk = try context.requireSDK()
        let catalog = try await context.catalog(refresh: refresh)
        let plan: InstallPlan
        do {
            plan = try catalog.installPlan(for: ids, installed: LocalPackages.scan(sdkRoot: sdk.url), channel: channel)
        } catch {
            throw CLIError(sdkError: error)
        }
        let accepted = LicenseStore(sdkRoot: sdk.url).acceptedIDs
        return PlanPreview(
            packages: plan.packages.map { .init(id: $0.id, displayName: $0.displayName, size: $0.archive?.size) },
            downloadSize: plan.downloadSize,
            licenses: plan.licenses.map { .init(id: $0.id, accepted: accepted.contains($0.id)) }
        )
    }

    static func install(_ ids: [String], options: GlobalOptions, catalogOptions: CatalogOptions, acceptLicenses: Bool) async throws {
        try await install(ids, options: options, refresh: catalogOptions.refresh, channel: catalogOptions.channel, acceptLicenses: acceptLicenses)
    }

    /// - Parameter silent: install without printing progress or a result (for commands that
    ///   report on their own, like `project check --fix --json`).
    static func install(
        _ ids: [String],
        options: GlobalOptions,
        refresh: Bool = false,
        channel: PackageChannel = .stable,
        acceptLicenses: Bool,
        silent: Bool = false
    ) async throws {
        let context = CommandContext(options)
        let sdk = try context.requireSDK()
        let catalog = try await context.catalog(refresh: refresh)

        let plan: InstallPlan
        do {
            plan = try catalog.installPlan(for: ids, installed: LocalPackages.scan(sdkRoot: sdk.url), channel: channel)
        } catch {
            throw CLIError(sdkError: error)
        }
        guard !plan.isEmpty else {
            if !silent {
                try Output.result(json: options.json, message: "Already installed and up to date.", fields: ["installed": [String]()])
            }
            return
        }

        let licenses = LicenseStore(sdkRoot: sdk.url)
        let unaccepted = licenses.unaccepted(in: plan)
        if !unaccepted.isEmpty {
            guard acceptLicenses else {
                throw CLIError(
                    code: "license_not_accepted",
                    message: "These packages need licenses that haven't been accepted: \(unaccepted.map(\.id).joined(separator: ", ")).",
                    hint: "Review them with `andyman licenses show <id>`, then rerun with --accept-licenses.",
                    exitStatus: .licenseRequired
                )
            }
            for license in unaccepted { try licenses.accept(license) }
        }

        let reporter = silent ? nil : InstallReporter(json: options.json, plan: plan)
        reporter?.planned()
        do {
            for try await event in try await context.installer().install(plan) {
                reporter?.handle(event)
            }
        } catch {
            throw CLIError(sdkError: error)
        }
        reporter?.done()
    }
}

/// Prints install progress: NDJSON events with --json, a compact progress display otherwise.
private final class InstallReporter {
    private let json: Bool
    private let plan: InstallPlan
    private var lastPercent: [String: Int] = [:]
    private var finished: [String] = []
    private let interactive = isatty(STDERR_FILENO) == 1

    init(json: Bool, plan: InstallPlan) {
        self.json = json
        self.plan = plan
    }

    private struct Event: Encodable {
        var event: String
        var package: String?
        var received: Int64?
        var total: Int64?
        var percent: Int?
        var packages: [String]?
        var downloadSize: Int64?
    }

    private func emit(_ event: Event) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(event) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    func planned() {
        if json {
            emit(Event(event: "plan", packages: plan.packages.map(\.id), downloadSize: plan.downloadSize))
        } else {
            let size = ByteCountFormatter.string(fromByteCount: plan.downloadSize, countStyle: .file)
            Output.errorLine("Installing \(plan.packages.map(\.id).joined(separator: ", ")) (\(size) to download)")
        }
    }

    func handle(_ event: InstallEvent) {
        switch event {
        case let .started(id):
            if json { emit(Event(event: "started", package: id)) }
        case let .downloading(id, received, total):
            let percent = total > 0 ? Int(received * 100 / total) : 0
            guard lastPercent[id] != percent else { return }
            lastPercent[id] = percent
            if json {
                emit(Event(event: "progress", package: id, received: received, total: total, percent: percent))
            } else if interactive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K  \(id)  \(percent)%".utf8))
            }
        case let .unpacking(id):
            if json {
                emit(Event(event: "unpacking", package: id))
            } else if interactive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K  \(id)  unpacking…".utf8))
            }
        case let .finished(id):
            finished.append(id)
            if json {
                emit(Event(event: "finished", package: id))
            } else {
                if interactive { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
                Output.errorLine("  ✓ \(id)")
            }
        case .output:
            break
        }
    }

    func done() {
        if json {
            struct Done: Encodable {
                var event = "done"
                var schemaVersion = Output.schemaVersion
                var ok = true
                var installed: [String]
            }
            try? Output.json(Done(installed: finished))
        } else {
            Output.line("Installed \(finished.joined(separator: ", ")).")
        }
    }
}

struct LicensesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "licenses",
        abstract: "Review and accept SDK package licenses.",
        subcommands: [List.self, Show.self, Accept.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List licenses and whether they're accepted.")

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions

        func run() async throws {
            let context = CommandContext(options)
            let store = LicenseStore(sdkRoot: try context.requireSDK().url)
            let catalog = try await context.catalog(catalogOptions)
            let accepted = store.acceptedIDs
            let ids = Set(catalog.licenses.keys).union(accepted).sorted()

            if options.json {
                struct Entry: Encodable { var id: String; var accepted: Bool }
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var licenses: [Entry]
                }
                try Output.json(Payload(licenses: ids.map { Entry(id: $0, accepted: accepted.contains($0)) }))
                return
            }
            Output.table(header: ["LICENSE", "STATUS"], rows: ids.map { [$0, accepted.contains($0) ? "accepted" : Style.current.yellow("not accepted")] })
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a license's full text.")

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions
        @Argument(help: "License ID, e.g. android-sdk-license.") var id: String

        func run() async throws {
            let catalog = try await CommandContext(options).catalog(catalogOptions)
            guard let license = catalog.licenses[id] else {
                throw CLIError(code: "license_not_found", message: "No license with ID \(id).", hint: "Run `andyman licenses list`.", exitStatus: .notFound)
            }
            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var id: String
                    var text: String
                }
                try Output.json(Payload(id: license.id, text: license.text))
            } else {
                Output.line(license.text)
            }
        }
    }

    struct Accept: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Accept licenses.",
            discussion: "Agents: show the license text to the user and get their agreement before running this."
        )

        @OptionGroup var options: GlobalOptions
        @OptionGroup var catalogOptions: CatalogOptions
        @Argument(help: "License IDs to accept.") var ids: [String]

        func run() async throws {
            let context = CommandContext(options)
            let store = LicenseStore(sdkRoot: try context.requireSDK().url)
            let catalog = try await context.catalog(catalogOptions)
            for id in ids {
                guard let license = catalog.licenses[id] else {
                    throw CLIError(code: "license_not_found", message: "No license with ID \(id).", exitStatus: .notFound)
                }
                try store.accept(license)
            }
            try Output.result(json: options.json, message: "Accepted \(ids.joined(separator: ", ")).", fields: ["accepted": ids])
        }
    }
}

extension CLIError {
    init(sdkError error: any Error) {
        switch error {
        case let error as CLIError:
            self = error
        case let error as InstallPlanError:
            self.init(code: "package_not_found", message: error.localizedDescription, hint: "Run `andyman sdk list --available`.", exitStatus: .notFound)
        case let error as SDKInstallError:
            switch error {
            case .toolsMissing: self.init(code: "cmdline_tools_missing", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .javaMissing: self.init(code: "java_missing", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .locked: self.init(code: "sdk_locked", message: error.localizedDescription, hint: "Wait for the other install (in the app or another terminal) to finish.")
            case .failed: self.init(code: "install_failed", message: error.localizedDescription)
            }
        default:
            self.init(error)
        }
    }
}
