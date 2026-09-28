import AndroidKit
import ArgumentParser
import Foundation

extension VirtualDevice.FormFactor: ExpressibleByArgument {}

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List hardware profiles for creating virtual devices.",
        discussion: "Use a profile's ID with `andyman avd create --device <id>`."
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "Only this category: \(VirtualDevice.FormFactor.allCases.map(\.rawValue).joined(separator: ", ")).")
    var category: VirtualDevice.FormFactor?
    @Flag(help: "Include legacy profiles (old Nexus-era devices).") var legacy = false

    func run() async throws {
        let context = CommandContext(options)
        let profiles = try await context.profiles()
            .filter { (legacy || !$0.isLegacy) && (category == nil || $0.category == category) }

        if options.json {
            struct Payload: Encodable {
                var schemaVersion = Output.schemaVersion
                var profiles: [DeviceProfile]
            }
            try Output.json(Payload(profiles: profiles))
            return
        }
        guard !profiles.isEmpty else {
            Output.line("No matching profiles.")
            return
        }
        Output.table(
            header: ["ID", "NAME", "CATEGORY", "SCREEN"],
            rows: profiles.map { [$0.id, $0.name, $0.category.title + ($0.isLegacy ? " (legacy)" : ""), $0.summary] }
        )
    }
}

struct ImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images",
        abstract: "List installed system images.",
        discussion: "Use an image's package ID with `andyman avd create --image <id>`."
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: ArgumentHelp("Only images that can run a device with this profile.", valueName: "profile-id"))
    var device: String?

    func run() async throws {
        let context = CommandContext(options)
        let sdk = try context.requireSDK()
        var images = SystemImages.installed(in: sdk.url)
        if let device {
            let profile = try await context.profile(id: device)
            images = images.filter { $0.isCompatible(with: profile) }
        }

        if options.json {
            struct Payload: Encodable {
                var schemaVersion = Output.schemaVersion
                var images: [SystemImage]
            }
            try Output.json(Payload(images: images))
            return
        }
        guard !images.isEmpty else {
            Output.line(device == nil ? "No system images installed." : "No installed system images can run \(device!).")
            return
        }
        Output.table(
            header: ["PACKAGE", "ANDROID", "SERVICES", "ABI"],
            rows: images.map { image in
                [image.id, [image.androidVersion, "API \(image.apiLevel)"].compactMap(\.self).joined(separator: " · "), image.tagDisplay, image.abi]
            }
        )
    }
}

extension CommandContext {
    func profiles() async throws -> [DeviceProfile] {
        let sdk = try requireSDK()
        let tools = SDKInspector.inventory(at: sdk.url).sdkmanagerPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
        }
        let profiles = await DeviceProfiles.load(sdkRoot: sdk.url, cmdlineTools: tools, environment: environment)
        guard !profiles.isEmpty else {
            throw CLIError(
                code: "cmdline_tools_missing",
                message: "Device profiles come from the Android SDK Command-line Tools, which aren't installed.",
                exitStatus: .missingPrerequisite
            )
        }
        return profiles
    }

    func profile(id: String) async throws -> DeviceProfile {
        guard let profile = try await profiles().first(where: { $0.id == id }) else {
            throw CLIError(
                code: "profile_not_found",
                message: "No device profile with ID \(id).",
                hint: "Run `andyman devices` to see profile IDs.",
                exitStatus: .notFound
            )
        }
        return profile
    }

    func java() async -> JavaInstallation? {
        let locator = JavaLocator()
        return locator.resolve(
            settings: SharedPreferences().javaHomeOverride,
            environment: environment,
            installations: await locator.installations()
        ).selected
    }
}
