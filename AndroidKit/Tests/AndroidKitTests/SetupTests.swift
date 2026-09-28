import Foundation
import Testing
@testable import AndroidKit

@Suite struct ShellProfileEditorTests {
    func tempFile(_ contents: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: ".zshrc")
        if let contents { try contents.write(to: file, atomically: true, encoding: .utf8) }
        return file
    }

    @Test func appendsBlockAndBacksUp() throws {
        let file = try tempFile("export EDITOR=vim")
        let editor = ShellProfileEditor(file: file)
        let backup = try #require(try editor.apply(lines: ["export ANDROID_HOME=/sdk"]))
        #expect(try String(contentsOf: file, encoding: .utf8) == """
        export EDITOR=vim

        # >>> Andyman >>>
        export ANDROID_HOME=/sdk
        # <<< Andyman <<<

        """)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "export EDITOR=vim")
    }

    @Test func replacesExistingBlockOnly() throws {
        let file = try tempFile("a\n# >>> Andyman >>>\nexport ANDROID_HOME=/old\n# <<< Andyman <<<\nb\n")
        let editor = ShellProfileEditor(file: file)
        let change = editor.proposedChange(lines: ["export ANDROID_HOME=/new"])
        #expect(change.replacesExisting)
        try editor.apply(lines: ["export ANDROID_HOME=/new"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "a\n# >>> Andyman >>>\nexport ANDROID_HOME=/new\n# <<< Andyman <<<\nb\n")
        // Same lines again: nothing to do, no backup.
        #expect(!editor.proposedChange(lines: ["export ANDROID_HOME=/new"]).isNeeded)
        #expect(try editor.apply(lines: ["export ANDROID_HOME=/new"]) == nil)
    }

    @Test func createsMissingProfile() throws {
        let file = try tempFile(nil)
        #expect(try ShellProfileEditor(file: file).apply(lines: ["x"]) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# >>> Andyman >>>\nx\n# <<< Andyman <<<\n")
    }

    @Test func detectsConfiguredEnvironment() {
        let env = ["ANDROID_HOME": "/sdk", "PATH": "/usr/bin:/sdk/platform-tools"]
        #expect(ShellProfileEditor.isConfigured(environment: env, sdkPath: "/sdk"))
        #expect(!ShellProfileEditor.isConfigured(environment: ["ANDROID_HOME": "/sdk", "PATH": "/usr/bin"], sdkPath: "/sdk"))
        #expect(!ShellProfileEditor.isConfigured(environment: env, sdkPath: "/other"))
    }
}

@Suite struct JDKReleaseTests {
    @Test func parsesAdoptiumResponse() throws {
        let json = """
        [{"binary":{"package":{"checksum":"196d13","link":"https://github.com/adoptium/x/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.20.1_1.tar.gz","name":"OpenJDK17U.tar.gz","size":185851019},"image_type":"jdk"},"release_name":"jdk-17.0.20.1+1","vendor":"eclipse"}]
        """
        let release = try #require(JDKInstaller.parseRelease(Data(json.utf8), major: 17))
        #expect(release.version == "17.0.20.1")
        #expect(release.size == 185851019)
        #expect(release.sha256 == "196d13")
        #expect(JDKInstaller.parseRelease(Data("[]".utf8), major: 17) == nil)
    }

    @Test func verifiesChecksums() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "checksum-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Downloader.verify(file, .sha1("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")))
        #expect(try Downloader.verify(file, .sha256("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")))
        #expect(try !Downloader.verify(file, .sha1("0000")))
    }
}

@Suite struct SetupPlanTests {
    func catalogWithTools() -> RepositoryCatalog {
        var catalog = fixtureCatalog()
        var tools = catalog.latest("platforms;android-36")!
        tools.id = "cmdline-tools;latest"
        tools.displayName = "Android SDK Command-line Tools (latest)"
        tools.revision = PackageRevision("23.0")!
        tools.apiLevel = nil
        catalog.packages.append(tools)
        return catalog
    }

    @Test func presetsUseHostABI() {
        #expect(SetupPreset.reactNative().packages.contains("system-images;android-37.0;google_apis_playstore;\(SetupPreset.hostABI)"))
        #expect(SetupPreset.reactNative().packages.contains("ndk;27.1.12297006"))
        #expect(SetupPreset.named("tools")?.packages == ["platform-tools", "emulator"])
    }

    @Test func plansFromEmptySDK() async throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        let options = SetupOptions(sdkPath: sdk.root.path, jdkMajor: nil, packages: ["platforms;android-36"], createEmulator: false)
        let plan = try await EnvironmentSetup(environment: [:]).plan(options, catalog: catalogWithTools())
        #expect(plan.bootstrapTools)
        #expect(plan.steps.contains(.commandLineTools))
        #expect(plan.steps.contains(.packages))
        #expect(plan.steps.last == .verify)
        #expect(!plan.steps.contains(.emulator))
        #expect(plan.unacceptedLicenses.map(\.id) == ["android-sdk-license"])
        #expect(plan.downloadSize == 65878410 * 2) // tools (same fixture archive) + platform
    }

    @Test func refusesToRunWithUnacceptedLicenses() async throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        let options = SetupOptions(sdkPath: sdk.root.path, jdkMajor: nil, packages: [], createEmulator: false)
        let catalog = catalogWithTools()
        let setup = EnvironmentSetup(environment: [:])
        let plan = try await setup.plan(options, catalog: catalog)
        await #expect(throws: SetupError.licensesNotAccepted(["android-sdk-license"])) {
            try await setup.run(plan, options: options, catalog: catalog) { _ in }
        }
    }

    @Test func packageXMLRoundTrips() throws {
        var tools = fixtureCatalog().latest("platforms;android-36")!
        tools.id = "cmdline-tools;latest"
        tools.displayName = "Android SDK Command-line Tools (latest)"
        tools.revision = PackageRevision("23.0")!
        let xml = CommandLineToolsBootstrap.packageXML(for: tools)
        let parsed = try #require(LocalPackages.parsePackageXML(Data(xml.utf8), path: "/sdk/cmdline-tools/latest"))
        #expect(parsed.id == "cmdline-tools;latest")
        #expect(parsed.revision == PackageRevision("23.0"))
    }
}

/// Large real downloads (~155 MB tools, ~185 MB JDK). Run with AM_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AM_NETWORK_TESTS"] == "1"))
struct SetupNetworkTests {
    @Test(.timeLimit(.minutes(10)))
    func bootstrapsCommandLineToolsIntoEmptySDK() async throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        let catalog = try await RepositoryClient().catalog()
        let bootstrap = CommandLineToolsBootstrap(sdkRoot: sdk.root)
        #expect(bootstrap.isNeeded)
        try await bootstrap.install(from: catalog) { _, _ in }
        #expect(!bootstrap.isNeeded)
        #expect(LocalPackages.scan(sdkRoot: sdk.root).map(\.id) == ["cmdline-tools;latest"])

        // The bootstrapped Android CLI accepts our package.xml and can install the next package.
        try LicenseStore(sdkRoot: sdk.root).accept(try #require(catalog.licenses["android-sdk-license"]))
        let plan = try catalog.installPlan(for: ["platform-tools"], installed: LocalPackages.scan(sdkRoot: sdk.root))
        for try await _ in SDKInstaller(sdkRoot: sdk.root, java: nil, environment: [:]).install(plan) {}
        #expect(LocalPackages.scan(sdkRoot: sdk.root).map(\.id) == ["cmdline-tools;latest", "platform-tools"])
    }

    @Test(.timeLimit(.minutes(10)))
    func installsJDKIntoCustomFolder() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "jdks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = JDKInstaller(destination: destination)
        let release = try await installer.latestRelease(major: 17)
        let java = try await installer.install(release) { _, _ in }
        #expect(java.majorVersion == 17)
        #expect(java.home == destination.appending(path: "temurin-17.jdk/Contents/Home").path)
        let result = try await ProcessRunner().run(URL(fileURLWithPath: java.javaExecutable), arguments: ["-version"])
        #expect(result.succeeded)
        #expect(result.stderrString.contains("Temurin"))
    }
}
