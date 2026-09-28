import Foundation
import Testing
@testable import AndroidKit

@Suite struct GradleScriptTests {
    @Test func readsGroovyExtBlock() {
        let script = """
        buildscript {
            ext {
                buildToolsVersion = "35.0.0"
                minSdkVersion = 24
                compileSdkVersion = 35 // keep in sync
                targetSdkVersion = 34
                ndkVersion = "26.1.10909125"
                kotlinVersion = "1.9.24"
            }
            repositories { maven { url "https://maven.example.com/repo" } }
        }
        """
        let values = GradleScript.extValues(script)
        #expect(values[.buildTools] == "35.0.0")
        #expect(values[.minSdk] == "24")
        #expect(values[.compileSdk] == "35")
        #expect(values[.targetSdk] == "34")
        #expect(values[.ndk] == "26.1.10909125")
        #expect(values[.kotlin] == "1.9.24")
    }

    @Test func readsKotlinScriptAndDotSyntax() {
        #expect(GradleScript.extValues(#"extra["ndkVersion"] = "27.1.12297006""#)[.ndk] == "27.1.12297006")
        #expect(GradleScript.extValues(#"val compileSdkVersion by extra(36)"#)[.compileSdk] == "36")
        #expect(GradleScript.extValues("ext.minSdkVersion = 23")[.minSdk] == "23")
        #expect(GradleScript.extValues(#"extra.set("buildToolsVersion", "36.0.0")"#)[.buildTools] == "36.0.0")
    }

    @Test func ignoresCommentedAndReferencedValues() {
        let script = """
        // ndkVersion = "25.0.0"
        /* compileSdkVersion = 33 */
        compileSdkVersion = rootProject.ext.foo
        """
        let values = GradleScript.extValues(script)
        #expect(values[.ndk] == nil)
        #expect(values[.compileSdk] == nil)
    }

    @Test func readsModuleLiteralsButNotReferences() {
        let app = """
        android {
            ndkVersion rootProject.ext.ndkVersion
            buildToolsVersion "34.0.0"
            compileSdk 34
            defaultConfig {
                minSdkVersion rootProject.ext.minSdkVersion
                targetSdk = 34
            }
            externalNativeBuild {
                cmake {
                    path "src/main/jni/CMakeLists.txt"
                    version "3.22.1"
                }
            }
        }
        """
        let values = GradleScript.moduleValues(app)
        #expect(values[.ndk] == nil)
        #expect(values[.minSdk] == nil)
        #expect(values[.buildTools] == "34.0.0")
        #expect(values[.compileSdk] == "34")
        #expect(values[.targetSdk] == "34")
        #expect(values[.cmake] == "3.22.1")
    }

    @Test func readsVersionCatalogAndWrapper() {
        let toml = """
        [versions]
        # Android versions
        minSdk = "24"
        compileSdk = "36" # comment
        ndkVersion = "27.1.12297006"
        [libraries]
        minSdk = "not a version"
        """
        let versions = GradleScript.catalogVersions(toml)
        #expect(versions == ["minSdk": "24", "compileSdk": "36", "ndkVersion": "27.1.12297006"])
        #expect(GradleScript.wrapperVersion(distributionURL: #"https\://services.gradle.org/distributions/gradle-9.3.1-bin.zip"#) == "9.3.1")
        #expect(GradleScript.wrapperVersion(distributionURL: "https://x/gradle-8.14-all.zip") == "8.14")
    }
}

@Suite struct GradleCompatibilityTests {
    @Test func verdicts() {
        #expect(GradleCompatibility.verdict(java: 17, gradle: "8.14.3") == .supported)
        #expect(GradleCompatibility.verdict(java: 24, gradle: "8.14.3") == .supported)
        #expect(GradleCompatibility.verdict(java: 25, gradle: "8.14.3") == .tooNew(maximum: 24))
        #expect(GradleCompatibility.verdict(java: 21, gradle: "8.3") == .tooNew(maximum: 20))
        #expect(GradleCompatibility.verdict(java: 11, gradle: "8.14") == .tooOld(minimum: 17))
        #expect(GradleCompatibility.verdict(java: 25, gradle: "9.3.1") == .supported)
        #expect(GradleCompatibility.verdict(java: 26, gradle: "9.3.1") == .unknown(newestKnown: 25))
        #expect(GradleCompatibility.verdict(java: 21, gradle: nil) == .supported)
    }
}

/// A React Native project on disk, laid out like the template.
struct FakeProject {
    let root: URL
    var android: URL { root.appending(path: "android") }

    init(rootBuild: String = "", appBuild: String = "", properties: String = "", catalog: String? = nil, localSDK: String? = nil, gradle: String = "8.14.3") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FakeRN-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        func write(_ text: String, _ path: String) throws {
            let url = root.appending(path: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(#"{"name": "FakeApp", "dependencies": {"react-native": "0.85.3", "expo": "~55.0.0"}}"#, "package.json")
        try write(rootBuild, "android/build.gradle")
        try write(appBuild, "android/app/build.gradle")
        try write(properties, "android/gradle.properties")
        try write("distributionUrl=https\\://services.gradle.org/distributions/gradle-\(gradle)-bin.zip\n", "android/gradle/wrapper/gradle-wrapper.properties")
        if let catalog {
            try write(#"{"name": "react-native", "version": "0.85.3"}"#, "node_modules/react-native/package.json")
            try write(catalog, "node_modules/react-native/gradle/libs.versions.toml")
        }
        if let localSDK { try write("sdk.dir=\(localSDK)\n", "android/local.properties") }
    }
}

@Suite struct AndroidProjectTests {
    let emptyGradleHome = FileManager.default.temporaryDirectory.appending(path: "gradle-home-\(UUID().uuidString)")
    let catalog = """
    [versions]
    minSdk = "24"
    targetSdk = "36"
    compileSdk = "36"
    buildTools = "36.0.0"
    ndkVersion = "27.1.12297006"
    agp = "8.12.0"
    """

    @Test func resolvesWithPrecedence() throws {
        let fake = try FakeProject(
            rootBuild: "ext { ndkVersion = \"26.1.10909125\" }",
            appBuild: "android { compileSdk 35 }",
            properties: "android.buildToolsVersion=35.0.1\nnewArchEnabled=true\nreactNativeArchitectures=arm64-v8a, x86_64\n",
            catalog: catalog
        )
        let project = try AndroidProject.load(fake.root.path, gradleUserHome: emptyGradleHome)
        #expect(project.name == "FakeApp")
        #expect(project.reactNativeVersion == "0.85.3")
        #expect(project.isExpo)
        #expect(project.gradleVersion == "8.14.3")
        #expect(project.androidGradlePluginVersion == "8.12.0")
        #expect(project.compileSdk == .init(value: "35", source: .appBuildFile))
        #expect(project.ndk == .init(value: "26.1.10909125", source: .rootBuildFile))
        #expect(project.buildTools == .init(value: "35.0.1", source: .gradleProperties))
        #expect(project.minSdk == .init(value: "24", source: .reactNativeCatalog))
        #expect(project.newArchitecture == true)
        #expect(project.architectures == ["arm64-v8a", "x86_64"])
    }

    @Test func acceptsTheAndroidFolderItself() throws {
        let fake = try FakeProject(catalog: catalog)
        let project = try AndroidProject.load(fake.android.path, gradleUserHome: emptyGradleHome)
        #expect(project.root == fake.root.standardizedFileURL.path)
        #expect(project.compileSdk?.value == "36")
    }

    @Test func rejectsFoldersWithoutAndroid() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NotAProject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: ProjectError.noAndroidFolder(folder.standardizedFileURL.path)) {
            try AndroidProject.load(folder.path)
        }
    }

    @Test func writesLocalPropertiesKeepingOtherLines() throws {
        let fake = try FakeProject(catalog: catalog)
        let file = fake.android.appending(path: "local.properties")
        try "# generated\nsdk.dir=/old\nfoo=bar\n".write(to: file, atomically: true, encoding: .utf8)
        let project = try AndroidProject.load(fake.root.path, gradleUserHome: emptyGradleHome)
        try project.writeLocalSDKDir("/new/sdk")
        #expect(try String(contentsOf: file, encoding: .utf8) == "# generated\nsdk.dir=/new/sdk\nfoo=bar\n")

        try FileManager.default.removeItem(at: file)
        try project.writeLocalSDKDir("/new/sdk")
        #expect(try String(contentsOf: file, encoding: .utf8) == "sdk.dir=/new/sdk\n")
    }
}

@Suite struct ProjectDoctorTests {
    let emptyGradleHome = FileManager.default.temporaryDirectory.appending(path: "gradle-home-\(UUID().uuidString)")

    func package(_ id: String) -> LocalPackage {
        LocalPackage(id: id, displayName: id, revision: PackageRevision(major: 1, minor: 0, micro: 0), path: "/sdk/\(id)", obsolete: false)
    }

    func project(localSDK: String? = nil, gradle: String = "8.14.3") throws -> AndroidProject {
        let fake = try FakeProject(
            catalog: "[versions]\nminSdk = \"24\"\ncompileSdk = \"36\"\nbuildTools = \"36.0.0\"\nndkVersion = \"27.1.12297006\"\nagp = \"8.12.0\"\n",
            localSDK: localSDK,
            gradle: gradle
        )
        return try AndroidProject.load(fake.root.path, gradleUserHome: emptyGradleHome)
    }

    func report(_ project: AndroidProject, installed: [String], javaHome: String?, sdk: String = NSTemporaryDirectory()) -> ProjectReport {
        var environment = ["ANDROID_HOME": sdk]
        if let javaHome { environment["JAVA_HOME"] = javaHome }
        return ProjectDoctor().check(.init(
            project: project,
            sdk: SDKLocation(path: sdk, source: .environment("ANDROID_HOME")),
            installed: installed.map(package),
            catalog: nil,
            javaInstallations: [],
            environment: environment,
            devices: [],
            gradleUserHome: emptyGradleHome
        ))
    }

    @Test func findsMissingPackages() throws {
        let jdk = try makeFakeJDK(version: "17.0.12")
        let report = report(try project(), installed: ["platforms;android-36", "cmake;3.22.1"], javaHome: jdk.path)
        #expect(report.missingPackages == ["build-tools;36.0.0", "ndk;27.1.12297006"])
        #expect(report.checks.first { $0.id == "platform" }?.status == .ok)
        #expect(report.checks.first { $0.id == "java" }?.status == .ok)
        #expect(report.status == .error)
    }

    @Test func allGoodWhenEverythingIsInstalled() throws {
        let jdk = try makeFakeJDK(version: "17.0.12")
        let installed = ["platforms;android-36.0", "build-tools;36.0.0", "ndk;27.1.12297006", "cmake;3.22.1"]
        let report = report(try project(), installed: installed, javaHome: jdk.path)
        #expect(report.missingPackages.isEmpty)
        // The only warning is having no emulator for minSdk 24.
        #expect(report.checks.filter { $0.status != .ok }.map(\.id) == ["emulator"])
    }

    @Test func flagsJavaTooNewForGradle() throws {
        let jdk = try makeFakeJDK(version: "25.0.1")
        let report = report(try project(gradle: "8.14.3"), installed: [], javaHome: jdk.path)
        let java = try #require(report.checks.first { $0.id == "java" })
        #expect(java.status == .error)
        #expect(java.fix == .installJDK(17))

        // With JDK 17 installed, the fix is to use it rather than install it again.
        let seventeen = try makeFakeJDK(version: "17.0.12")
        var input = ProjectDoctor.Input(
            project: try project(gradle: "8.14.3"), sdk: SDKLocation(path: NSTemporaryDirectory(), source: .defaultLocation),
            installed: [], catalog: nil,
            javaInstallations: [JavaLocator.installation(at: seventeen.path, source: .javaHomeTool)!],
            environment: ["JAVA_HOME": jdk.path], devices: [], gradleUserHome: emptyGradleHome
        )
        #expect(ProjectDoctor().check(input).checks.first { $0.id == "java" }?.fix == .useJDK(17))
        // Without JAVA_HOME, Gradle gets the macOS default JDK.
        input.environment = [:]
        input.defaultJava = JavaLocator.installation(at: jdk.path, source: .javaHomeTool)
        let fallback = try #require(ProjectDoctor().check(input).checks.first { $0.id == "java" })
        #expect(fallback.message.contains("macOS default"))
    }

    @Test func flagsBrokenLocalProperties() throws {
        let report = report(try project(localSDK: "/nope/sdk"), installed: [], javaHome: nil)
        let sdk = try #require(report.checks.first { $0.id == "sdk" })
        #expect(sdk.status == .error)
        #expect(sdk.fix == .writeLocalProperties(sdkPath: NSTemporaryDirectory()))
    }

    @Test func platformIDVariants() {
        #expect(ProjectDoctor.platformIDs(for: "37") == ["platforms;android-37", "platforms;android-37.0"])
        #expect(ProjectDoctor.platformIDs(for: "36.1") == ["platforms;android-36.1"])
    }
}

@Suite struct CleanupTests {
    @Test func findsTargetsAndCleansThem() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "CleanupHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        let temp = home.appending(path: "tmp", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        func write(_ path: String, bytes: Int = 10_000) throws {
            let url = home.appending(path: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try write(".gradle/caches/modules-2/lib.jar")
        try write(".gradle/wrapper/dists/gradle-8.14.3-bin/abc/gradle-8.14.3/bin/gradle")
        try write(".gradle/wrapper/dists/gradle-9.3.1-bin/def/gradle-9.3.1/bin/gradle")
        try write(".gradle/daemon/8.14.3/daemon-123.out.log")
        try write(".gradle/daemon/8.14.3/registry.bin")
        try write("tmp/metro-cache/x")
        try write("tmp/unrelated/y")

        let cleanup = Cleanup(sdkRoot: nil, environment: [:], home: home, temporaryDirectory: temp)
        let targets = cleanup.targets()
        #expect(targets.map(\.id) == [
            "gradle-caches",
            "gradle-distribution:gradle-9.3.1-bin",
            "gradle-distribution:gradle-8.14.3-bin",
            "gradle-daemon-logs",
            "metro-cache",
        ])
        let logs = try #require(targets.first { $0.kind == .gradleDaemonLogs })
        #expect(logs.paths == [home.appending(path: ".gradle/daemon/8.14.3/daemon-123.out.log").path])
        #expect(Cleanup.size(of: logs) > 0)

        let metro = try #require(targets.first { $0.kind == .metroCache })
        #expect(try Cleanup.clean(metro) > 0)
        #expect(!fileManager.fileExists(atPath: temp.appending(path: "metro-cache").path))
        #expect(fileManager.fileExists(atPath: temp.appending(path: "unrelated/y").path))
        try Cleanup.clean(logs)
        #expect(fileManager.fileExists(atPath: home.appending(path: ".gradle/daemon/8.14.3/registry.bin").path))
    }

    @Test func projectBuildFolders() throws {
        let fake = try FakeProject(catalog: "[versions]\n")
        let fileManager = FileManager.default
        for path in ["android/app/build/outputs/a.apk", "android/app/.cxx/x", "android/.gradle/y", "node_modules/react-native-foo/android/build/z", "node_modules/@scope/lib/android/.cxx/w"] {
            let url = fake.root.appending(path: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 100).write(to: url)
        }
        let project = try AndroidProject.load(fake.root.path)
        let targets = Cleanup.projectTargets(project)
        #expect(targets.map(\.kind) == [.projectBuild, .projectLibraries])
        #expect(Set(targets[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent }) == [".gradle", "build", ".cxx"])
        #expect(targets[1].paths.count == 2)
    }
}

@Suite struct GradleDaemonTests {
    @Test func parsesProcessList() {
        let output = """
          501 812344 /Library/Java/JavaVirtualMachines/jdk-17/Contents/Home/bin/java -Xmx2048m -cp /Users/me/.gradle/wrapper/dists/gradle-8.14.3-bin/x/gradle-8.14.3/lib/gradle-daemon-main-8.14.3.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14.3
          777 402000 /jdk/bin/java -cp /Users/me/.gradle/caches/modules-2/kotlin-compiler-embeddable-2.1.20.jar org.jetbrains.kotlin.daemon.KotlinCompileDaemon --daemon-runFilesPath x
          900 1000 /usr/bin/vim notes.txt
        """
        let daemons = GradleDaemons.parse(output)
        #expect(daemons == [
            GradleDaemon(pid: 501, kind: .gradle, version: "8.14.3", memory: 812344 * 1024),
            GradleDaemon(pid: 777, kind: .kotlin, version: "2.1.20", memory: 402000 * 1024),
        ])
    }
}
