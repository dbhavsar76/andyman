import Foundation
import Testing
@testable import AndroidKit

@Suite struct FrameworkRequirementsTests {
    @Test func parsesReactNativeCatalog() throws {
        let toml = """
        [versions]
        minSdk = "24"
        targetSdk = "36"
        compileSdk = "37"
        buildTools = "37.0.0"
        ndkVersion = "27.1.12297006"
        agp = "9.2.1"
        """
        let requirements = try #require(FrameworkRequirementsClient.reactNative(version: "0.87.1", toml: toml))
        #expect(requirements.compileSdk == "37")
        #expect(requirements.buildTools == "37.0.0")
        #expect(requirements.ndk == "27.1.12297006")
        #expect(requirements.cmake == "3.22.1")
        #expect(requirements.androidGradlePlugin == "9.2.1")
        #expect(!requirements.isFallback)
    }

    @Test func parsesFlutterSources() throws {
        let kotlin = """
        open class FlutterExtension {
            /** Sets the compileSdkVersion used by default in Flutter app projects. */
            val compileSdkVersion: Int = 36
            val minSdkVersion: Int = 24
            // val ndkVersion: String = "1.0.0"
            val targetSdkVersion: Int = 36
            val ndkVersion: String = "28.2.13676358"
        }
        """
        let gradleUtils = "const templateAndroidGradlePluginVersion = '9.1.0';"
        let requirements = try #require(FrameworkRequirementsClient.flutter(version: "3.47.5", extensionSource: kotlin, gradleUtils: gradleUtils))
        #expect(requirements.compileSdk == "36")
        #expect(requirements.ndk == "28.2.13676358")
        #expect(requirements.minSdk == "24")
        #expect(requirements.androidGradlePlugin == "9.1.0")
        #expect(requirements.buildTools == "36.0.0")
        #expect(requirements.cmake == nil)

        // Older SDKs keep the defaults in flutter.groovy.
        let groovy = """
        class FlutterExtension {
            static int compileSdkVersion = 34
            static int minSdkVersion = 21
            static int targetSdkVersion = 34
            public final String ndkVersion = "23.1.7779620"
        }
        """
        #expect(FlutterDefaults.parse(groovy) == FlutterDefaults(compileSdk: "34", targetSdk: "34", minSdk: "21", ndk: "23.1.7779620"))
    }

    @Test func findsStableFlutterRelease() {
        let releases: [String: Any] = [
            "current_release": ["stable": "abc", "beta": "def"],
            "releases": [
                ["hash": "def", "channel": "beta", "version": "3.48.0-1.0.pre"],
                ["hash": "abc", "channel": "stable", "version": "3.47.5"],
            ],
        ]
        #expect(FrameworkRequirementsClient.stableFlutterVersion(releases) == "3.47.5")
    }

    @Test func androidGradlePluginDefaults() {
        #expect(AndroidGradlePlugin.defaultBuildTools(for: "9.1.0") == "36.0.0")
        #expect(AndroidGradlePlugin.defaultBuildTools(for: "8.12.0") == "35.0.0")
        #expect(AndroidGradlePlugin.defaultBuildTools(for: "8.1.0") == nil)
        #expect(AndroidGradlePlugin.usesDefaultCMake("9.2.1"))
        #expect(!AndroidGradlePlugin.usesDefaultCMake("7.4.2"))
    }

    @Test func presetsFollowRequirements() {
        var flutter = FrameworkRequirements.fallback(.flutter)
        flutter.version = "3.50.0"
        flutter.compileSdk = "38"
        flutter.ndk = "29.0.1"
        let preset = SetupPreset.flutter(flutter)
        #expect(preset.packages == [
            "platform-tools", "emulator", "platforms;android-38.0", "build-tools;36.0.0", "ndk;29.0.1",
            "system-images;android-38.0;google_apis_playstore;\(SetupPreset.hostABI)",
        ])
        #expect(preset.detail.contains("Flutter 3.50.0"))
        #expect(SetupPreset.reactNative().packages.contains("cmake;3.22.1"))
        #expect(SetupPreset.named("flutter")?.id == "flutter")
    }

    @Test func picksPackageIDsTheCatalogHas() throws {
        let catalog = try fixtureCatalog()
        // The fixture has platforms;android-36, not android-36.0.
        #expect(SetupPreset.platformID("36", catalog: catalog) == "platforms;android-36")
        #expect(SetupPreset.platformID("99", catalog: catalog) == "platforms;android-99.0")
    }

    @Test func cachedFallsBackToBuiltIn() {
        let client = FrameworkRequirementsClient(cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "reqs-\(UUID().uuidString)"))
        let values = client.cached()
        #expect(values[.reactNative]?.isFallback == true)
        #expect(values[.flutter]?.version == FrameworkRequirements.fallback(.flutter).version)
    }
}

@Suite struct FlutterProjectTests {
    /// A Flutter SDK with just what the project doctor reads.
    func makeFlutterSDK() throws -> URL {
        let sdk = FileManager.default.temporaryDirectory.appending(path: "flutter-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sdk.appending(path: "bin/cache"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: sdk.appending(path: "bin/flutter"), atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdk.appending(path: "bin/flutter").path)
        try #"{"frameworkVersion": "3.47.5", "channel": "stable"}"#.write(to: sdk.appending(path: "bin/cache/flutter.version.json"), atomically: true, encoding: .utf8)
        let kotlin = sdk.appending(path: "packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt")
        try fileManager.createDirectory(at: kotlin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "val compileSdkVersion: Int = 36\nval minSdkVersion: Int = 24\nval targetSdkVersion: Int = 36\nval ndkVersion: String = \"28.2.13676358\"\n"
            .write(to: kotlin, atomically: true, encoding: .utf8)
        return sdk
    }

    func makeProject(flutterSDK: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "FlutterApp-\(UUID().uuidString)", directoryHint: .isDirectory)
        func write(_ text: String, _ path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("name: my_app\ndependencies:\n  flutter:\n    sdk: flutter\n", "pubspec.yaml")
        try write("""
        plugins {
            id("dev.flutter.flutter-plugin-loader") version "1.0.0"
            id("com.android.application") version "9.1.0" apply false
        }
        """, "android/settings.gradle.kts")
        try write("allprojects { repositories { google() } }\n", "android/build.gradle.kts")
        try write("""
        android {
            namespace = "com.example.my_app"
            compileSdk = flutter.compileSdkVersion
            ndkVersion = flutter.ndkVersion
            defaultConfig { minSdk = flutter.minSdkVersion }
        }
        """, "android/app/build.gradle.kts")
        try write("distributionUrl=https\\://services.gradle.org/distributions/gradle-9.3.1-all.zip\n", "android/gradle/wrapper/gradle-wrapper.properties")
        try write("sdk.dir=/sdk\nflutter.sdk=\(flutterSDK)\n", "android/local.properties")
        try FileManager.default.createDirectory(at: root.appending(path: "build/app/outputs"), withIntermediateDirectories: true)
        return root
    }

    @Test func readsFlutterDefaultsFromTheSDK() throws {
        let sdk = try makeFlutterSDK()
        let root = try makeProject(flutterSDK: sdk.path)
        let project = try AndroidProject.load(root.path, environment: [:])
        #expect(project.framework == .flutter)
        #expect(project.name == "my_app")
        #expect(project.flutterVersion == "3.47.5")
        #expect(project.flutterSDK == sdk.path)
        #expect(project.androidGradlePluginVersion == "9.1.0")
        #expect(project.compileSdk == .init(value: "36", source: .flutterDefault))
        #expect(project.ndk == .init(value: "28.2.13676358", source: .flutterDefault))
        #expect(project.minSdk?.value == "24")
        #expect(project.buildTools == nil)

        let report = ProjectDoctor().check(.init(
            project: project,
            sdk: SDKLocation(path: "/sdk", source: .environment("ANDROID_HOME")),
            installed: [],
            catalog: nil,
            javaInstallations: [],
            environment: [:],
            devices: []
        ))
        #expect(report.checks.first?.id == "flutter")
        #expect(report.checks.first?.status == .ok)
        #expect(!report.checks.contains { $0.id == "cmake" })
        let buildTools = try #require(report.checks.first { $0.id == "build-tools" })
        #expect(buildTools.title == "Build Tools 36.0.0")
        #expect(buildTools.message.contains("Android Gradle Plugin default"))
        #expect(report.missingPackages == ["platforms;android-36", "build-tools;36.0.0", "ndk;28.2.13676358"])

        #expect(Cleanup.projectTargets(project).first?.paths.contains(root.appending(path: "build").path) == true)
    }

    @Test func reportsMissingFlutterSDK() throws {
        let root = try makeProject(flutterSDK: "/nowhere/flutter")
        let project = try AndroidProject.load(root.path, environment: [:])
        #expect(project.missingFlutterSDK == "/nowhere/flutter")
        #expect(project.compileSdk == nil)
        let report = ProjectDoctor().check(.init(project: project, sdk: nil, installed: [], catalog: nil, javaInstallations: [], environment: [:], devices: []))
        #expect(report.checks.first { $0.id == "flutter" }?.status == .error)
    }

    @Test func readsPluginVersionFromSettings() {
        #expect(GradleScript.androidGradlePluginVersion(settings: #"id "com.android.application" version "8.7.0" apply false"#, rootBuild: "") == "8.7.0")
        #expect(GradleScript.androidGradlePluginVersion(settings: "", rootBuild: "classpath 'com.android.tools.build:gradle:8.1.0'") == "8.1.0")
    }
}
