import Foundation
import Testing
@testable import AndroidKit

/// A throwaway `~/.android/avd` with helpers to add AVDs in various states.
struct FakeAVDHome {
    let root: URL
    var directory: URL { root.appending(path: "avd", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FakeAVD-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "avd"), withIntermediateDirectories: true)
    }

    /// Writes `<name>.ini` pointing at `<folder>.avd` and, unless `withFolder` is false, the folder's config.ini.
    @discardableResult
    func addAVD(
        name: String,
        folder: String? = nil,
        withFolder: Bool = true,
        absolutePath: String? = nil,
        config: [String: String] = [:]
    ) throws -> URL {
        let folderName = "\(folder ?? name).avd"
        let folderURL = directory.appending(path: folderName, directoryHint: .isDirectory)
        let ini = [
            "avd.ini.encoding=UTF-8",
            "path=\(absolutePath ?? folderURL.path)",
            "path.rel=avd/\(folderName)",
            "target=\(config["target"] ?? "android-36")",
        ]
        try ini.joined(separator: "\n").write(to: directory.appending(path: "\(name).ini"), atomically: true, encoding: .utf8)
        if withFolder { try writeConfig(folder: folderURL, config: config) }
        return folderURL
    }

    func addUnregisteredFolder(_ folder: String, avdID: String) throws {
        try writeConfig(folder: directory.appending(path: "\(folder).avd", directoryHint: .isDirectory), config: ["AvdId": avdID])
    }

    func writeConfig(folder: URL, config: [String: String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = [
            "abi.type": "arm64-v8a",
            "image.sysdir.1": "system-images/android-36/google_apis_playstore/arm64-v8a/",
            "hw.lcd.width": "1080", "hw.lcd.height": "2400", "hw.lcd.density": "420",
            "target": "android-36",
        ]
        let merged = defaults.merging(config) { _, new in new }
        let text = merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        try text.write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct AVDCatalogTests {
    @Test func readsDevicesIncludingRenamedOnes() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addAVD(name: "Pixel_9", config: [
            "avd.ini.displayname": "Pixel 9", "PlayStore.enabled": "true", "hw.ramSize": "2048",
            "hw.device.name": "pixel_9", "hw.device.manufacturer": "Google", "tag.display": "Google Play",
        ])
        // Renamed in Android Studio: the .ini name changed, the folder kept its old name.
        try home.addAVD(name: "Android_6_No_Google", folder: "New_Device", config: [
            "target": "android-23", "tag.display": "Default Android System Image", "tag.id": "default",
        ])

        let scan = AVDCatalog(directory: home.directory, sdkRoot: nil).scan()
        #expect(scan.issues.isEmpty)
        #expect(scan.devices.map(\.name) == ["Android_6_No_Google", "Pixel_9"])

        let pixel = try #require(scan.devices.last)
        #expect(pixel.displayName == "Pixel 9")
        #expect(pixel.summary == "Android 16 · API 36 · Google Play")
        #expect(pixel.ramMB == 2048)
        #expect(pixel.formFactor == .phone)
        #expect(pixel.systemImagePackage == "system-images;android-36;google_apis_playstore;arm64-v8a")

        let renamed = try #require(scan.devices.first)
        #expect(renamed.displayName == "Android 6 No Google")
        #expect(renamed.path.hasSuffix("New_Device.avd"))
        #expect(renamed.summary == "Android 6.0 · API 23 · Default Android System Image")
    }

    @Test func detectsMissingFoldersAndUnregisteredFolders() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addAVD(name: "Ghost", withFolder: false)
        try home.addUnregisteredFolder("Orphan", avdID: "Orphan_Device")

        let scan = AVDCatalog(directory: home.directory, sdkRoot: nil).scan()
        #expect(scan.devices.isEmpty)
        #expect(scan.issues.map(\.kind) == [.missingFolder, .unregisteredFolder])
        #expect(scan.issues.map(\.name) == ["Ghost", "Orphan_Device"])
    }

    @Test func fallsBackToRelativePathWhenAbsoluteIsStale() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addAVD(name: "Moved", absolutePath: "/Users/someone-else/.android/avd/Moved.avd")
        let scan = AVDCatalog(directory: home.directory, sdkRoot: nil).scan()
        #expect(scan.devices.map(\.name) == ["Moved"])
        #expect(scan.issues.isEmpty)
    }

    @Test func flagsMissingSystemImage() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try home.addAVD(name: "Installed")
        try home.addAVD(name: "Missing", config: ["image.sysdir.1": "system-images/android-99/default/arm64-v8a/"])
        try sdk.package("system-images/android-36/google_apis_playstore/arm64-v8a", revision: "1")

        let devices = AVDCatalog(directory: home.directory, sdkRoot: sdk.root).scan().devices
        #expect(devices.first { $0.name == "Installed" }?.problems == [])
        #expect(devices.first { $0.name == "Missing" }?.problems == [.systemImageMissing(package: "system-images;android-99;default;arm64-v8a")])
        #expect(devices.first { $0.name == "Missing" }?.canLaunch == false)
    }

    @Test(arguments: [
        // System image tags.
        ([:], ["google-tv"], .tv),
        ([:], ["android-tv"], .tv),
        ([:], ["android-wear"], .wear),
        ([:], ["android-automotive-playstore"], .automotive),
        ([:], ["android-desktop"], .desktop),
        ([:], ["android-xr"], .xr),
        ([:], ["google_apis_playstore_tablet"], .tablet),
        // Device profile names from `avdmanager list device`, when the tag says nothing.
        (["hw.device.name": "tv_4k"], ["default"], .tv),
        (["hw.device.name": "wearos_small_round"], ["default"], .wear),
        (["hw.device.name": "automotive_1024p_landscape"], ["default"], .automotive),
        (["hw.device.name": "desktop_medium"], ["default"], .desktop),
        (["hw.device.name": "13.5in Freeform"], ["default"], .desktop),
        (["hw.device.name": "xr_headset_device"], ["android-xr"], .xr),
        (["hw.device.name": "xr_glasses_device"], ["android-xr"], .glasses),
        (["hw.device.name": "ai_glasses_displayless"], ["default"], .glasses),
        (["hw.device.name": "medium_tablet"], ["google_apis"], .tablet),
        // A foldable's configured screen is its large unfolded size; it must not read as a tablet.
        (["hw.device.name": "pixel_9_pro_fold", "hw.lcd.width": "2076", "hw.lcd.height": "2152", "hw.lcd.density": "390"], ["google_apis"], .foldable),
        (["hw.device.name": "7.6in Foldable"], ["default"], .foldable),
        (["hw.sensor.hinge": "yes", "hw.lcd.width": "1840", "hw.lcd.height": "2208", "hw.lcd.density": "420"], ["default"], .foldable),
        (["hw.device.name": "resizable", "hw.sensor.hinge": "yes"], ["google_apis"], .phone),
        // Screen size decides between phone and tablet (smallest width ≥ 600 dp is a tablet).
        (["hw.device.name": "Nexus 10", "hw.lcd.width": "2560", "hw.lcd.height": "1600", "hw.lcd.density": "320"], ["default"], .tablet),
        (["hw.device.name": "pixel_10a", "hw.lcd.width": "1080", "hw.lcd.height": "2424", "hw.lcd.density": "420"], ["google_apis"], .phone),
        (["hw.device.name": "Nexus One"], ["default"], .phone),
    ] as [([String: String], [String], VirtualDevice.FormFactor)])
    func formFactors(config: [String: String], tags: [String], expected: VirtualDevice.FormFactor) {
        #expect(AVDCatalog.formFactor(config: config, tagIDs: tags) == expected)
    }

    @Test func parsesTargetsAndSizes() {
        #expect(AVDCatalog.apiLevel(fromTarget: "android-37.1") == "37.1")
        #expect(AVDCatalog.apiLevel(fromTarget: "Google Inc.:Google APIs:23") == "23")
        #expect(AVDCatalog.apiLevel(fromTarget: "android-Baklava") == nil)
        #expect(AVDCatalog.megabytes("2G") == 2048)
        #expect(AVDCatalog.megabytes("1536M") == 1536)
        #expect(AVDCatalog.megabytes("4096") == 4096)
    }

    @Test func wipeRemovesUserDataButKeepsConfig() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        let folder = try home.addAVD(name: "Pixel")
        for name in ["userdata-qemu.img", "cache.img.qcow2", "sdcard.img"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "snapshots/default_boot"), withIntermediateDirectories: true)

        let catalog = AVDCatalog(directory: home.directory, sdkRoot: nil)
        try catalog.wipeData(try catalog.device(named: "Pixel"), running: [])
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(remaining == ["config.ini", "sdcard.img"])
    }

    @Test func refusesToWipeOrDeleteRunningDevice() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addAVD(name: "Pixel")
        let catalog = AVDCatalog(directory: home.directory, sdkRoot: nil)
        let device = try catalog.device(named: "Pixel")
        let running = [RunningEmulator(pid: 1, avdName: "Pixel", avdPath: nil, consolePort: 5554, emulatorVersion: nil, headless: false)]
        #expect(throws: AVDError.running("Pixel")) { try catalog.wipeData(device, running: running) }
        #expect(throws: AVDError.running("Pixel")) { try catalog.delete(device, running: running) }
    }

    @Test func restoresUnregisteredFolder() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addUnregisteredFolder("Orphan", avdID: "Orphan_Device")
        let catalog = AVDCatalog(directory: home.directory, sdkRoot: nil)
        try catalog.fix(try #require(catalog.scan().issues.first))

        let scan = catalog.scan()
        #expect(scan.issues.isEmpty)
        #expect(scan.devices.map(\.name) == ["Orphan_Device"])
    }

    @Test func restoreAvoidsNameClash() throws {
        let home = try FakeAVDHome(); defer { home.remove() }
        try home.addAVD(name: "Pixel")
        try home.addUnregisteredFolder("Pixel_copy", avdID: "Pixel")
        let catalog = AVDCatalog(directory: home.directory, sdkRoot: nil)
        try catalog.fix(try #require(catalog.scan().issues.first))
        #expect(catalog.scan().devices.map(\.name).sorted() == ["Pixel", "Pixel_2"])
    }

    @Test func avdDirectoryFromEnvironment() {
        #expect(AVDCatalog.defaultDirectory(environment: ["ANDROID_AVD_HOME": "/custom/avd"]).path == "/custom/avd")
        #expect(AVDCatalog.defaultDirectory(environment: ["ANDROID_USER_HOME": "/u"]).path == "/u/avd")
        #expect(AVDCatalog.defaultDirectory(environment: [:]).path.hasSuffix("/.android/avd"))
    }

    @Test func problemEncodesWithCode() throws {
        let data = try JSONEncoder().encode(VirtualDevice.Problem.systemImageMissing(package: "p"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json == ["code": "system_image_missing", "package": "p"])
        #expect(try JSONDecoder().decode(VirtualDevice.Problem.self, from: data) == .systemImageMissing(package: "p"))
    }
}

@Suite struct EmulatorTests {
    @Test func launchOptionsMapToFlags() {
        #expect(EmulatorLaunchOptions().arguments == [])
        let options = EmulatorLaunchOptions(coldBoot: true, wipeData: true, saveSnapshot: false, headless: true, gpu: .swiftshader)
        #expect(options.arguments == ["-no-snapshot-load", "-wipe-data", "-no-snapshot-save", "-no-window", "-gpu", "swiftshader_indirect"])
    }

    @Test func parsesDiscoveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "running-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let me = ProcessInfo.processInfo.processIdentifier
        try """
        avd.id=Pixel_10a
        port.serial=5556
        avd.name=Pixel 10a
        emulator.version=37.1.11.0
        avd.dir=/Users/me/.android/avd/Pixel_10a.avd
        cmdline="/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless" "-avd" "Pixel_10a" "-no-window"
        """.write(to: directory.appending(path: "pid_\(me).ini"), atomically: true, encoding: .utf8)
        // A stale file from a process that no longer exists is ignored.
        try "avd.id=Old\nport.serial=5554\n".write(to: directory.appending(path: "pid_999999.ini"), atomically: true, encoding: .utf8)

        let running = RunningEmulators.scan(directory: directory)
        #expect(running.count == 1)
        let emulator = try #require(running.first)
        #expect(emulator.avdName == "Pixel_10a")
        #expect(emulator.serial == "emulator-5556")
        #expect(emulator.headless)
    }

    @Test func detachedProcessOutlivesAndLogs() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "detached-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try DetachedProcess.spawn(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo \"hello $GREETING\"; echo oops >&2"],
            environment: ["GREETING": "world"],
            logFile: log
        )
        #expect(pid > 0)
        for _ in 0..<50 where DetachedProcess.isRunning(pid) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!DetachedProcess.isRunning(pid))
        #expect(try String(contentsOf: log, encoding: .utf8) == "hello world\noops\n")
    }
}
