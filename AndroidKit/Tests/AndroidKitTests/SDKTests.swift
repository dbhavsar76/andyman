import Foundation
import Testing
@testable import AndroidKit

/// Builds a throwaway SDK folder layout for tests.
struct FakeSDK {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FakeSDK-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func package(_ relativePath: String, revision: String) throws {
        let directory = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Pkg.Revision=\(revision)\n".write(to: directory.appending(path: "source.properties"), atomically: true, encoding: .utf8)
    }

    func executable(_ relativePath: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct SDKLocatorTests {
    let locator = SDKLocator()

    @Test func prefersAndroidHomeOverDefault() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("platform-tools", revision: "37.0.1")
        let other = try FakeSDK(); defer { other.remove() }
        try other.package("emulator", revision: "36.1")

        let resolution = locator.resolve(environment: ["ANDROID_HOME": sdk.root.path], defaultPath: other.root.path)
        #expect(resolution.location == SDKLocation(path: sdk.root.path, source: .environment("ANDROID_HOME")))
        #expect(resolution.isValid)
    }

    @Test func skipsBrokenEnvironmentVariables() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("platform-tools", revision: "37.0.1")

        let resolution = locator.resolve(environment: ["ANDROID_HOME": "/does/not/exist"], defaultPath: sdk.root.path)
        #expect(resolution.location?.source == .defaultLocation)
        #expect(resolution.candidates.first?.problem == .missing)
    }

    @Test func explicitSettingWinsEvenWhenBroken() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("platform-tools", revision: "37.0.1")

        let resolution = locator.resolve(settings: "/does/not/exist", environment: [:], defaultPath: sdk.root.path)
        #expect(resolution.location?.source == .settings)
        #expect(!resolution.isValid)
    }

    @Test func folderWithoutSDKMarkersIsNotAnSDK() throws {
        let empty = try FakeSDK(); defer { empty.remove() }
        let resolution = locator.resolve(environment: [:], defaultPath: empty.root.path)
        #expect(resolution.location == nil)
        #expect(resolution.candidates == [.init(path: empty.root.path, source: .defaultLocation, problem: .notAnSDK)])
    }
}

@Suite struct SDKInspectorTests {
    @Test func readsInstalledPackages() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("cmdline-tools/latest", revision: "23.0")
        try sdk.executable("cmdline-tools/latest/bin/sdkmanager")
        try sdk.package("cmdline-tools/19.0", revision: "19.0")
        try sdk.executable("cmdline-tools/19.0/bin/sdkmanager")
        try sdk.package("cmdline-tools/broken", revision: "1.0") // no bin/sdkmanager
        try sdk.package("platform-tools", revision: "37.0.1")
        try sdk.package("ndk/27.0.12077973", revision: "27.0.12077973")
        try sdk.package("ndk/27.1.12297006", revision: "27.1.12297006")
        try sdk.package("platforms/android-9", revision: "1")
        try sdk.package("platforms/android-36", revision: "2")
        try sdk.package("system-images/android-36/google_apis_playstore/arm64-v8a", revision: "7")

        let inventory = SDKInspector.inventory(at: sdk.root)
        #expect(inventory.cmdlineTools.map(\.id) == ["cmdline-tools;latest", "cmdline-tools;19.0"])
        #expect(inventory.sdkmanagerPath == sdk.root.appending(path: "cmdline-tools/latest").path + "/bin/sdkmanager")
        #expect(inventory.platformTools?.version == "37.0.1")
        #expect(inventory.emulator == nil)
        #expect(inventory.ndks.map(\.id) == ["ndk;27.1.12297006", "ndk;27.0.12077973"])
        #expect(inventory.platforms.map(\.id) == ["platforms;android-36", "platforms;android-9"])
        #expect(inventory.systemImages.map(\.id) == ["system-images;android-36;google_apis_playstore;arm64-v8a"])
    }

    @Test func fallsBackToNewestCmdlineToolsWithoutLatest() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        for version in ["9.0", "19.0"] {
            try sdk.package("cmdline-tools/\(version)", revision: version)
            try sdk.executable("cmdline-tools/\(version)/bin/sdkmanager")
        }
        #expect(SDKInspector.inventory(at: sdk.root).sdkmanagerPath?.contains("cmdline-tools/19.0/") == true)
    }
}
