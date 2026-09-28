import Foundation
import Testing
@testable import AndroidKit

/// A throwaway JDK home with `bin/java` and a `release` file.
func makeFakeJDK(version: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "FakeJDK-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    let java = home.appending(path: "bin/java")
    try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
    try "IMPLEMENTOR=\"Test\"\nJAVA_VERSION=\"\(version)\"\n".write(to: home.appending(path: "release"), atomically: true, encoding: .utf8)
    return home
}

@Suite struct JavaLocatorTests {
    let locator = JavaLocator()

    func java(_ version: String) -> JavaInstallation {
        JavaInstallation(home: "/jdk/\(version)", version: version, vendor: nil, name: nil, source: .javaHomeTool)
    }

    @Test func parsesJavaHomePlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array>
          <dict>
            <key>JVMEnabled</key><true/>
            <key>JVMHomePath</key><string>/jdk/21/Contents/Home</string>
            <key>JVMName</key><string>Amazon Corretto 21</string>
            <key>JVMVendor</key><string>Amazon.com Inc.</string>
            <key>JVMVersion</key><string>21.0.7</string>
          </dict>
          <dict>
            <key>JVMEnabled</key><false/>
            <key>JVMHomePath</key><string>/jdk/disabled</string>
          </dict>
        </array></plist>
        """
        let installations = JavaLocator.parseJavaHomeList(Data(plist.utf8))
        #expect(installations == [JavaInstallation(
            home: "/jdk/21/Contents/Home", version: "21.0.7", vendor: "Amazon.com Inc.",
            name: "Amazon Corretto 21", source: .javaHomeTool
        )])
        #expect(installations.first?.displayName == "JDK 21 · Amazon Corretto 21")
    }

    @Test func picksNewestLTSAtLeast17() {
        let installed = [java("26.0.2"), java("25.0.0"), java("21.0.7"), java("11.0.2")]
        #expect(JavaLocator.best(of: installed)?.version == "25.0.0")
        #expect(JavaLocator.best(of: [java("11.0.2"), java("18.0.1")])?.version == "18.0.1")
        #expect(JavaLocator.best(of: [java("11.0.2")]) == nil)
    }

    @Test func javaHomeWinsWhenValid() throws {
        let home = try makeFakeJDK(version: "17.0.12")
        defer { try? FileManager.default.removeItem(at: home) }
        let resolution = locator.resolve(environment: ["JAVA_HOME": home.path], installations: [java("21.0.7")])
        #expect(resolution.selected?.home == home.standardizedFileURL.path)
        #expect(resolution.selected?.source == .environment("JAVA_HOME"))
    }

    @Test func tooOldJavaHomeIsRejected() throws {
        let home = try makeFakeJDK(version: "1.8.0_292")
        defer { try? FileManager.default.removeItem(at: home) }
        let resolution = locator.resolve(environment: ["JAVA_HOME": home.path], installations: [java("21.0.7")])
        #expect(resolution.selected?.version == "21.0.7")
        #expect(resolution.rejected.map(\.reason) == [.tooOld])
    }
}

@Suite struct DoctorTests {
    func java(_ version: String?) -> JavaLocator.Resolution {
        let installation = version.map { JavaInstallation(home: "/jdk", version: $0, vendor: nil, name: nil, source: .javaHomeTool) }
        return .init(selected: installation, rejected: [], installations: installation.map { [$0] } ?? [])
    }

    @Test func missingSDKIsAnError() {
        let sdk = SDKLocator.Resolution(location: nil, candidates: [])
        let report = Doctor.report(sdk: sdk, java: java("21.0.7"), environment: [:])
        #expect(report.status == .error)
        #expect(report.checks.first { $0.id == "sdk.location" }?.status == .error)
        #expect(report.sdk.inventory == nil)
    }

    @Test func healthySetup() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("cmdline-tools/latest", revision: "23.0")
        try sdk.executable("cmdline-tools/latest/bin/sdkmanager")
        try sdk.package("platform-tools", revision: "37.0.1")
        try sdk.executable("platform-tools/adb")
        try sdk.package("emulator", revision: "36.1")

        let environment = ["ANDROID_HOME": sdk.root.path, "PATH": "/usr/bin:\(sdk.root.path)/platform-tools"]
        let resolution = SDKLocator().resolve(environment: environment)
        let report = Doctor.report(sdk: resolution, java: java("21.0.7"), environment: environment)

        #expect(report.checks.map(\.id) == [
            "sdk.location", "sdk.cmdline-tools", "sdk.platform-tools", "sdk.emulator", "java", "env.android-home", "env.path",
        ])
        #expect(report.status == .ok, "\(report.checks.filter { $0.status != .ok })")
        #expect(report.environment.adbOnPath)
    }

    @Test func missingCmdlineToolsAndEnvironment() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try sdk.package("platform-tools", revision: "37.0.1")

        let resolution = SDKLocator().resolve(environment: [:], defaultPath: sdk.root.path)
        let report = Doctor.report(sdk: resolution, java: java(nil), environment: [:])
        let statuses = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0.status) })

        #expect(statuses["sdk.cmdline-tools"] == .error)
        #expect(statuses["sdk.emulator"] == .warning)
        #expect(statuses["java"] == .error)
        #expect(statuses["env.android-home"] == .warning)
        #expect(statuses["env.path"] == .warning)
        #expect(report.status == .error)
    }

    @Test func reportEncodesWithSchemaVersion() throws {
        let report = Doctor.report(sdk: .init(location: nil, candidates: []), java: java(nil), environment: [:])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
        #expect(json?["status"] as? String == "error")
    }
}
