import AndroidKit
import ArgumentParser
import Foundation

/// Hardware options shared by `avd create` and `avd edit`.
struct HardwareOptions: ParsableArguments {
    @Option(help: "Name shown in the UI (spaces allowed).") var displayName: String?
    @Option(help: ArgumentHelp("Memory, e.g. 2048 or 4G.", valueName: "size")) var ram: String?
    @Option(help: ArgumentHelp("Java heap for apps, e.g. 512M.", valueName: "size")) var heap: String?
    @Option(help: ArgumentHelp("Internal storage, e.g. 8G.", valueName: "size")) var storage: String?
    @Option(help: ArgumentHelp("SD card size, e.g. 512M; 0 for none.", valueName: "size")) var sdcard: String?
    @Option(help: "CPU cores.") var cores: Int?
    @Option(help: ArgumentHelp("Hardware keyboard input: on or off.", valueName: "on|off")) var keyboard: Toggle?
    @Option(help: ArgumentHelp("Device frame around the window: on or off.", valueName: "on|off")) var frame: Toggle?
    @Option(help: "Initial orientation: portrait or landscape.") var orientation: AVDSettings.Orientation?
    @Option(help: "GPU mode: auto, host or swiftshader_indirect.") var gpu: EmulatorLaunchOptions.GPUMode?

    enum Toggle: String, ExpressibleByArgument {
        case on, off
        var isOn: Bool { self == .on }
    }

    func settings() throws -> AVDSettings {
        func size(_ value: String?, _ name: String) throws -> Int? {
            guard let value else { return nil }
            guard let megabytes = AVDCatalog.megabytes(value) else { throw CLIError.usage("Invalid \(name) size: \(value)") }
            return megabytes
        }
        return AVDSettings(
            displayName: displayName,
            ramMB: try size(ram, "RAM"),
            heapMB: try size(heap, "heap"),
            storageMB: try size(storage, "storage"),
            sdCardMB: try size(sdcard, "SD card"),
            cpuCores: cores,
            hardwareKeyboard: keyboard?.isOn,
            showFrame: frame?.isOn,
            orientation: orientation,
            gpu: gpu
        )
    }
}

extension AVDSettings.Orientation: ExpressibleByArgument {}

extension AVDCommand {
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a virtual device.",
            discussion: """
            Defaults to the Medium Phone profile and the newest installed system image that fits \
            it (Google Play images first). See `andyman devices` and `andyman images --device <id>`.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name (letters, numbers, . _ -). Suggested from the profile and image if omitted.")
        var name: String?
        @Option(help: ArgumentHelp("Hardware profile ID.", valueName: "profile-id")) var device = "medium_phone"
        @Option(help: ArgumentHelp("System image package ID.", valueName: "package")) var image: String?
        @OptionGroup var hardware: HardwareOptions

        func run() async throws {
            let context = CommandContext(options)
            let sdk = try context.requireSDK()
            let profile = try await context.profile(id: device)
            let images = SystemImages.installed(in: sdk.url)

            let systemImage: SystemImage
            if let image {
                guard let match = images.first(where: { $0.id == image }) else {
                    throw CLIError(
                        code: "image_not_installed", message: "\(image) isn't installed.",
                        hint: "Run `andyman images` to see installed images.", exitStatus: .missingPrerequisite
                    )
                }
                guard match.isCompatible(with: profile) else {
                    throw CLIError(code: "image_incompatible", message: "\(image) can't run a \(profile.name) on this Mac.", exitStatus: .usage)
                }
                systemImage = match
            } else {
                guard let best = images.first(where: { $0.isCompatible(with: profile) }) else {
                    throw CLIError(
                        code: "image_not_installed",
                        message: "No installed system image can run a \(profile.name).",
                        hint: "Install a \(profile.category.title) system image for \(SystemImage.hostABIs.joined(separator: "/")).",
                        exitStatus: .missingPrerequisite
                    )
                }
                systemImage = best
            }

            let catalog = context.catalog
            let avdName = name ?? catalog.suggestedName(profile: profile, image: systemImage)
            var settings = try hardware.settings()
            if settings.displayName == nil && name == nil {
                settings.displayName = "\(profile.name) API \(systemImage.apiLevel)"
            }

            let device: VirtualDevice
            do {
                device = try await catalog.create(
                    AVDSpec(name: avdName, profileID: profile.id, systemImage: systemImage.id, settings: settings),
                    java: await context.java(),
                    environment: context.environment
                )
            } catch let error as AVDEditError {
                throw CLIError(editError: error)
            }

            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var device: VirtualDevice
                }
                try Output.json(Payload(device: device))
            } else {
                Output.line("Created \(device.displayName) (\(device.name)) · \(systemImage.summary).")
                Output.line(Style.current.dim("Start it with: andyman emulator start \(device.name)"))
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a virtual device's hardware settings.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name.") var name: String
        @OptionGroup var hardware: HardwareOptions

        func run() async throws {
            let context = CommandContext(options)
            let device = try context.device(named: name)
            let settings = try hardware.settings()
            guard settings != AVDSettings() else { throw CLIError.usage("Pass at least one setting to change, e.g. --ram 4G.") }
            let updated: VirtualDevice
            do {
                updated = try context.catalog.update(device, settings: settings)
            } catch {
                throw CLIError(error)
            }
            try Output.result(json: options.json, message: "Updated \(updated.displayName).", fields: ["device": updated.name])
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a virtual device.",
            discussion: "Changes the name used with `emulator -avd`. The folder on disk keeps its name, as in Android Studio."
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "Current AVD name.") var name: String
        @Argument(help: "New AVD name (letters, numbers, . _ -).") var newName: String
        @Option(help: "Also change the name shown in the UI.") var displayName: String?

        func run() async throws {
            let context = CommandContext(options)
            let device = try context.device(named: name)
            var renamed: VirtualDevice
            do {
                renamed = try context.catalog.rename(device, to: newName)
                if let displayName {
                    renamed = try context.catalog.update(renamed, settings: AVDSettings(displayName: displayName))
                }
            } catch let error as AVDEditError {
                throw CLIError(editError: error)
            } catch {
                throw CLIError(error)
            }
            try Output.result(json: options.json, message: "Renamed \(name) to \(renamed.name).", fields: ["from": name, "to": renamed.name])
        }
    }

    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a virtual device, including its apps and data.",
            discussion: "Snapshots aren't copied, so the copy's first start is a cold boot."
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD to copy.") var name: String
        @Argument(help: "Name for the copy (letters, numbers, . _ -).") var newName: String
        @Option(help: "Name shown in the UI for the copy.") var displayName: String?

        func run() async throws {
            let context = CommandContext(options)
            let device = try context.device(named: name)
            let copy: VirtualDevice
            do {
                copy = try context.catalog.duplicate(device, as: newName, displayName: displayName)
            } catch let error as AVDEditError {
                throw CLIError(editError: error)
            } catch {
                throw CLIError(error)
            }
            try Output.result(json: options.json, message: "Created \(copy.displayName) (\(copy.name)).", fields: ["device": copy.name])
        }
    }

    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List or delete a virtual device's snapshots.",
            subcommands: [List.self, Delete.self]
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List snapshots (default_boot is the quick-boot state).")

            @OptionGroup var options: GlobalOptions
            @Argument(help: "AVD name.") var name: String

            func run() async throws {
                let context = CommandContext(options)
                let snapshots = context.catalog.snapshots(of: try context.device(named: name))
                if options.json {
                    struct Payload: Encodable {
                        var schemaVersion = Output.schemaVersion
                        var snapshots: [AVDSnapshot]
                    }
                    try Output.json(Payload(snapshots: snapshots))
                    return
                }
                guard !snapshots.isEmpty else {
                    Output.line("No snapshots.")
                    return
                }
                Output.table(header: ["NAME", "SIZE", "SAVED"], rows: snapshots.map {
                    [$0.name, ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file),
                     $0.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–"]
                })
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Move a snapshot to the Trash.")

            @OptionGroup var options: GlobalOptions
            @Argument(help: "AVD name.") var name: String
            @Argument(help: "Snapshot name.") var snapshot: String
            @Flag(help: "Confirm the deletion.") var yes = false

            func run() async throws {
                guard yes else { throw CLIError.confirmationRequired("Deleting snapshot \(snapshot)") }
                let context = CommandContext(options)
                let device = try context.device(named: name)
                guard let match = context.catalog.snapshots(of: device).first(where: { $0.name == snapshot }) else {
                    throw CLIError(code: "snapshot_not_found", message: "\(name) has no snapshot named \(snapshot).", exitStatus: .notFound)
                }
                do {
                    try context.catalog.deleteSnapshot(match, of: device)
                } catch {
                    throw CLIError(error)
                }
                try Output.result(json: options.json, message: "Moved snapshot \(snapshot) to the Trash.", fields: ["deleted": snapshot])
            }
        }
    }
}

extension CLIError {
    init(editError error: AVDEditError) {
        switch error {
        case .invalidName: self.init(code: "invalid_name", message: error.localizedDescription, exitStatus: .usage)
        case .nameTaken: self.init(code: "name_taken", message: error.localizedDescription, exitStatus: .usage)
        case .javaMissing: self.init(code: "java_missing", message: error.localizedDescription, hint: "Run `andyman doctor`.", exitStatus: .missingPrerequisite)
        case .toolsMissing: self.init(code: "cmdline_tools_missing", message: error.localizedDescription, exitStatus: .missingPrerequisite)
        case .avdmanagerFailed: self.init(code: "avdmanager_failed", message: error.localizedDescription)
        }
    }
}
