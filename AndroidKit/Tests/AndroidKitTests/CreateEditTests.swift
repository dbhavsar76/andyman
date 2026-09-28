import Foundation
import Testing
@testable import AndroidKit

@Suite struct DeviceProfileParserTests {
    let xml = """
    <?xml version="1.0"?>
    <d:devices xmlns:d="http://schemas.android.com/sdk/devices/9">
      <d:device>
        <d:name>Pixel 9 Pro Fold</d:name>
        <d:id>pixel_9_pro_fold</d:id>
        <d:manufacturer>Google</d:manufacturer>
        <d:playstore-enabled>true</d:playstore-enabled>
        <d:hardware>
          <d:screen>
            <d:diagonal-length>8</d:diagonal-length>
            <d:pixel-density>390dpi</d:pixel-density>
            <d:dimensions><d:x-dimension>2076</d:x-dimension><d:y-dimension>2152</d:y-dimension></d:dimensions>
            <d:foldable-region><d:x-folded-dimension>1080</d:x-folded-dimension></d:foldable-region>
          </d:screen>
          <d:hinge><d:count>1</d:count></d:hinge>
          <d:camera><d:location>back</d:location></d:camera>
          <d:ram unit="MiB">11444</d:ram>
          <d:skin>pixel_9_pro_fold</d:skin>
        </d:hardware>
        <d:software><d:api-level>35-</d:api-level></d:software>
      </d:device>
      <d:device deprecated="true">
        <d:name>Nexus One</d:name>
        <d:manufacturer>Google</d:manufacturer>
        <d:hardware>
          <d:screen>
            <d:diagonal-length>3.7</d:diagonal-length>
            <d:pixel-density>hdpi</d:pixel-density>
            <d:dimensions><d:x-dimension>480</d:x-dimension><d:y-dimension>800</d:y-dimension></d:dimensions>
          </d:screen>
          <d:ram unit="GiB">0.5</d:ram>
          <d:skin>_no_skin</d:skin>
        </d:hardware>
      </d:device>
      <d:device>
        <d:name>Wear OS Small Round</d:name>
        <d:id>wearos_small_round</d:id>
        <d:hardware><d:screen><d:pixel-density>hdpi</d:pixel-density></d:screen></d:hardware>
        <d:software><d:api-level>30-</d:api-level></d:software>
        <d:tag-id>android-wear</d:tag-id>
      </d:device>
    </d:devices>
    """

    @Test func parsesProfiles() throws {
        let profiles = DeviceProfileParser.parse(Data(xml.utf8), userDefined: false)
        #expect(profiles.map(\.id) == ["pixel_9_pro_fold", "Nexus One", "wearos_small_round"])

        let fold = profiles[0]
        #expect(fold.name == "Pixel 9 Pro Fold")
        #expect(fold.category == .foldable)
        #expect(fold.screenWidth == 2076 && fold.screenHeight == 2152 && fold.density == 390)
        #expect(fold.ramMB == 11444)
        #expect(fold.skin == "pixel_9_pro_fold")
        #expect(fold.minAPILevel == 35)
        #expect(fold.playStore && fold.hasHinge && !fold.isLegacy)
        #expect(fold.summary == "8″ · 2076 × 2152 · 390 dpi")

        let nexus = profiles[1]
        #expect(nexus.isLegacy)
        #expect(nexus.id == "Nexus One") // no <d:id>: the name is the id
        #expect(nexus.density == 240)
        #expect(nexus.ramMB == 512)
        #expect(nexus.skin == nil)
        #expect(nexus.category == .phone)

        #expect(profiles[2].category == .wear)
        #expect(profiles[2].tagID == "android-wear")
    }

    @Test func parsesAPIRanges() {
        #expect(DeviceProfileParser.minAPI("35-") == 35)
        #expect(DeviceProfileParser.minAPI("29-33") == 29)
        #expect(DeviceProfileParser.minAPI("28") == 28)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: SDKLocator.defaultPath + "/cmdline-tools/latest/lib/sdklib/sdklib.core.jar")))
    func loadsRealSDKProfiles() async {
        let sdk = URL(fileURLWithPath: SDKLocator.defaultPath)
        let profiles = await DeviceProfiles.load(sdkRoot: sdk, cmdlineTools: sdk.appending(path: "cmdline-tools/latest"), environment: [:])
        let categories = Set(profiles.map(\.category))
        #expect(profiles.count > 50)
        #expect(categories.isSuperset(of: [.phone, .foldable, .tablet, .wear, .desktop, .tv, .automotive, .xr, .glasses]))
        #expect(profiles.contains { $0.isLegacy })
        #expect(profiles.first { $0.id == "pixel_tablet" }?.category == .tablet)
    }
}

@Suite struct ConfigFileTests {
    @Test func editsInPlace() {
        var config = ConfigFile(contents: "# comment\nhw.ramSize=2G\nhw.keyboard=no\nunknown.key=kept\n")
        config["hw.ramSize"] = "4096M"
        config["hw.keyboard"] = nil
        config["AvdId"] = "Pixel"
        #expect(config["unknown.key"] == "kept")
        #expect(config.contents == "# comment\nhw.ramSize=4096M\nunknown.key=kept\nAvdId=Pixel\n")
    }
}

@Suite struct NamingTests {
    @Test func sanitizesNames() {
        #expect(AVDCatalog.sanitizedName("Pixel 9 Pro API 36") == "Pixel_9_Pro_API_36")
        #expect(AVDCatalog.sanitizedName("Wear OS (Round) — test") == "Wear_OS_Round_test")
        #expect(AVDCatalog.isValidName("Pixel_9.a-b"))
        #expect(!AVDCatalog.isValidName("Pixel 9"))
        #expect(!AVDCatalog.isValidName(""))
    }
}

@Suite struct SystemImageTests {
    func image(_ tags: [String], api: String = "36", abi: String = "arm64-v8a") -> SystemImage {
        SystemImage(id: "x", apiLevel: api, tagIDs: tags, tagDisplay: "", abi: abi, revision: nil, path: "")
    }

    func profile(_ category: VirtualDevice.FormFactor, minAPI: Double? = nil) -> DeviceProfile {
        DeviceProfile(
            id: "p", name: "P", manufacturer: nil, category: category, isLegacy: false, isUserDefined: false,
            diagonalInches: nil, screenWidth: nil, screenHeight: nil, density: nil, ramMB: nil, skin: nil,
            tagID: nil, minAPILevel: minAPI, playStore: false, hasHinge: false
        )
    }

    @Test func matchesImagesToProfiles() {
        let arm = ["arm64-v8a"]
        #expect(image(["google_apis_playstore"]).isCompatible(with: profile(.phone), hostABIs: arm))
        #expect(image(["google_apis", "page_size_16kb"]).isCompatible(with: profile(.foldable), hostABIs: arm))
        #expect(!image(["google_apis_playstore_tablet"]).isCompatible(with: profile(.phone), hostABIs: arm))
        #expect(image(["google_apis_playstore_tablet"]).isCompatible(with: profile(.tablet), hostABIs: arm))
        #expect(image(["google_apis"]).isCompatible(with: profile(.tablet), hostABIs: arm))
        #expect(image(["android-tv"]).isCompatible(with: profile(.tv), hostABIs: arm))
        #expect(!image(["android-tv"]).isCompatible(with: profile(.phone), hostABIs: arm))
        #expect(!image(["google_apis"]).isCompatible(with: profile(.wear), hostABIs: arm))
        #expect(!image(["google_apis"], abi: "x86_64").isCompatible(with: profile(.phone), hostABIs: arm))
        #expect(!image(["google_apis"], api: "33").isCompatible(with: profile(.phone, minAPI: 35), hostABIs: arm))
    }

    @Test func readsInstalledImages() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("system-images/android-36/google_apis/arm64-v8a", revision: "7")
        try sdk.package("system-images/android-36/google_apis_playstore/arm64-v8a", revision: "7")
        try sdk.package("system-images/android-37.1/google_apis_ps16k/arm64-v8a", revision: "9")
        let url = sdk.root.appending(path: "system-images/android-37.1/google_apis_ps16k/arm64-v8a/source.properties")
        try """
        Pkg.Revision=9
        AndroidVersion.ApiLevel=37.1
        SystemImage.Abi=arm64-v8a
        SystemImage.TagId=google_apis,page_size_16kb
        SystemImage.TagDisplay=Google APIs,16 KB Page Size
        """.write(to: url, atomically: true, encoding: .utf8)

        let images = SystemImages.installed(in: sdk.root)
        #expect(images.map(\.id) == [
            "system-images;android-37.1;google_apis_ps16k;arm64-v8a",
            "system-images;android-36;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis;arm64-v8a",
        ])
        #expect(images[0].summary == "Android 17 · API 37.1 · Google APIs, 16 KB Page Size")
        #expect(images[0].tagIDs == ["google_apis", "page_size_16kb"])
    }
}

@Suite struct AVDEditTests {
    func makeCatalog() throws -> (FakeAVDHome, AVDCatalog) {
        let home = try FakeAVDHome()
        try home.addAVD(name: "Pixel", config: [
            "AvdId": "Pixel", "avd.ini.displayname": "Pixel", "hw.ramSize": "2048", "hw.keyboard": "yes",
            "disk.dataPartition.size": "6G", "skin.path": "/sdk/skins/pixel", "showDeviceFrame": "yes",
        ])
        return (home, AVDCatalog(directory: home.directory, sdkRoot: nil))
    }

    @Test func updatesSettings() throws {
        let (home, catalog) = try makeCatalog(); defer { home.remove() }
        let device = try catalog.device(named: "Pixel")
        #expect(catalog.settings(of: device).ramMB == 2048)
        #expect(catalog.settings(of: device).storageMB == 6144)

        let updated = try catalog.update(device, settings: AVDSettings(
            displayName: "My Pixel", ramMB: 4096, storageMB: 8192, sdCardMB: 0, cpuCores: 6,
            hardwareKeyboard: false, showFrame: false, orientation: .landscape
        ), running: [])

        #expect(updated.displayName == "My Pixel")
        let settings = catalog.settings(of: updated)
        #expect(settings.ramMB == 4096)
        #expect(settings.storageMB == 8192)
        #expect(settings.sdCardMB == 0)
        #expect(settings.cpuCores == 6)
        #expect(settings.hardwareKeyboard == false)
        #expect(settings.showFrame == false)
        #expect(settings.orientation == .landscape)

        let config = try String(contentsOf: URL(fileURLWithPath: updated.path).appending(path: "config.ini"), encoding: .utf8)
        #expect(config.contains("disk.dataPartition.size=8G"))
        #expect(config.contains("abi.type=arm64-v8a")) // untouched keys survive
    }

    @Test func renamesINIButKeepsFolder() throws {
        let (home, catalog) = try makeCatalog(); defer { home.remove() }
        let renamed = try catalog.rename(try catalog.device(named: "Pixel"), to: "Pixel_Work", running: [])
        #expect(renamed.name == "Pixel_Work")
        #expect(renamed.path.hasSuffix("Pixel.avd"))
        #expect(catalog.scan().devices.map(\.name) == ["Pixel_Work"])
        #expect(throws: AVDEditError.invalidName("Bad Name")) { try catalog.rename(renamed, to: "Bad Name", running: []) }
    }

    @Test func duplicatesWithoutSnapshotsOrLocks() throws {
        let (home, catalog) = try makeCatalog(); defer { home.remove() }
        let original = try catalog.device(named: "Pixel")
        let folder = URL(fileURLWithPath: original.path)
        try Data("data".utf8).write(to: folder.appending(path: "userdata-qemu.img"))
        try Data().write(to: folder.appending(path: "multiinstance.lock"))
        try FileManager.default.createDirectory(at: folder.appending(path: "snapshots/default_boot"), withIntermediateDirectories: true)

        let copy = try catalog.duplicate(original, as: "Pixel_Copy", running: [])
        #expect(copy.displayName == "Pixel Copy")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: copy.path))
        #expect(files.contains("userdata-qemu.img"))
        #expect(!files.contains("multiinstance.lock"))
        #expect(!files.contains("snapshots"))
        #expect(catalog.scan().devices.map(\.name).sorted() == ["Pixel", "Pixel_Copy"])
        #expect(throws: AVDEditError.nameTaken("Pixel")) { try catalog.duplicate(original, as: "Pixel", running: []) }
    }

    @Test func listsSnapshots() throws {
        let (home, catalog) = try makeCatalog(); defer { home.remove() }
        let device = try catalog.device(named: "Pixel")
        let snapshotFolder = URL(fileURLWithPath: device.path).appending(path: "snapshots/default_boot")
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: snapshotFolder.appending(path: "ram.bin"))

        let snapshots = catalog.snapshots(of: device)
        #expect(snapshots.map(\.name) == ["default_boot"])
        #expect(snapshots.first?.isQuickBoot == true)
        #expect((snapshots.first?.sizeBytes ?? 0) >= 4096)
    }

    @Test func suggestsFreeNames() throws {
        let (home, catalog) = try makeCatalog(); defer { home.remove() }
        try home.addAVD(name: "Pixel_9_API_36")
        let profile = DeviceProfile(
            id: "pixel_9", name: "Pixel 9", manufacturer: nil, category: .phone, isLegacy: false, isUserDefined: false,
            diagonalInches: nil, screenWidth: nil, screenHeight: nil, density: nil, ramMB: nil, skin: nil,
            tagID: nil, minAPILevel: nil, playStore: false, hasHinge: false
        )
        let image = SystemImage(id: "x", apiLevel: "36", tagIDs: [], tagDisplay: "", abi: "arm64-v8a", revision: nil, path: "")
        #expect(catalog.suggestedName(profile: profile, image: image) == "Pixel_9_API_36_2")
    }
}

/// Runs the real `avdmanager` against a throwaway AVD folder, when an SDK and JDK are installed.
@Suite struct AVDCreateIntegrationTests {
    static let sdk = URL(fileURLWithPath: SDKLocator.defaultPath)
    static var image: SystemImage? {
        SystemImages.installed(in: sdk).first { $0.formFactor == .phone && !$0.isTabletOnly && SystemImage.hostABIs.contains($0.abi) }
    }

    @Test(.enabled(if: SDKInspector.inventory(at: sdk).avdmanagerPath != nil && image != nil))
    func createsAVDWithStudioDefaults() async throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        let locator = JavaLocator()
        let java = locator.resolve(environment: [:], installations: await locator.installations()).selected
        try #require(java != nil)

        let catalog = AVDCatalog(directory: home.directory, sdkRoot: Self.sdk)
        let spec = AVDSpec(
            name: "Test_Pixel", profileID: "pixel_9", systemImage: try #require(Self.image).id,
            settings: AVDSettings(displayName: "Test Pixel", ramMB: 3072, storageMB: 4096)
        )
        let device = try await catalog.create(spec, java: java, environment: ProcessInfo.processInfo.environment)

        #expect(device.name == "Test_Pixel")
        #expect(device.displayName == "Test Pixel")
        #expect(device.problems.isEmpty)
        let config = PropertiesFile.load(URL(fileURLWithPath: device.path).appending(path: "config.ini")) ?? [:]
        #expect(config["AvdId"] == "Test_Pixel")
        #expect(config["hw.gpu.enabled"] == "yes")
        #expect(config["hw.ramSize"] == "3072M")
        #expect(config["disk.dataPartition.size"] == "4G")
        #expect(config["avd.id"] == nil)
        #expect(config["skin.name"] == "pixel_9" || !FileManager.default.fileExists(atPath: Self.sdk.appending(path: "skins/pixel_9").path))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: device.path).appending(path: "sdcard.img").path))
        let ini = PropertiesFile.load(URL(fileURLWithPath: device.iniPath)) ?? [:]
        #expect(ini["path.rel"] == "avd/Test_Pixel.avd")

        await #expect(throws: AVDEditError.nameTaken("Test_Pixel")) {
            try await catalog.create(spec, java: java, environment: [:])
        }
    }
}
