import Foundation
import Testing
@testable import AndroidKit

@Suite struct ShellEnvironmentTests {
    @Test func parsesBetweenMarkersIgnoringDotfileNoise() {
        let output = "Welcome banner\n\u{1B}[?1h" + ShellEnvironment.startMarker
            + "HOME=/Users/me\0ANDROID_HOME=/sdk\0MULTI=a=b\0" + ShellEnvironment.endMarker + "bye"
        let environment = ShellEnvironment.parse(Data(output.utf8))
        #expect(environment == ["HOME": "/Users/me", "ANDROID_HOME": "/sdk", "MULTI": "a=b"])
    }

    @Test func returnsNilWithoutMarkers() {
        #expect(ShellEnvironment.parse(Data("zsh: command not found".utf8)) == nil)
    }

    @Test func capturesFromRealShell() async throws {
        let environment = try #require(await ShellEnvironment.capture(shell: "/bin/sh"))
        #expect(environment["PATH"] != nil)
    }
}

@Suite struct PropertiesFileTests {
    @Test func parsesSourceProperties() {
        let properties = PropertiesFile.parse("""
        # comment
        Pkg.Desc=Android SDK Command-line Tools
        Pkg.Revision = 23.0
        Pkg.Path=cmdline-tools;23.0
        Escaped=C\\:\\\\Android
        """)
        #expect(properties["Pkg.Revision"] == "23.0")
        #expect(properties["Pkg.Path"] == "cmdline-tools;23.0")
        #expect(properties["Pkg.Desc"] == "Android SDK Command-line Tools")
        #expect(properties["Escaped"] == "C:\\Android")
    }
}

@Suite struct VersionComparatorTests {
    @Test func comparesNumerically() {
        #expect(VersionComparator.isLess("27.0.12077973", "27.1.12297006"))
        #expect(VersionComparator.isLess("android-9", "android-37.0"))
        #expect(!VersionComparator.isLess("30.0.1", "29.9.9"))
    }

    @Test func majorVersions() {
        #expect(VersionComparator.majorVersion("21.0.7") == 21)
        #expect(VersionComparator.majorVersion("1.8.0_292") == 8)
        #expect(VersionComparator.majorVersion("26") == 26)
        #expect(VersionComparator.majorVersion("") == nil)
    }
}

@Suite struct ShellExportsTests {
    let java = JavaInstallation(home: "/Library/Java/jdk-17/Contents/Home", version: "17.0.12", vendor: nil, name: nil, source: .javaHomeTool)

    @Test func zshUsesHomeRelativePathsAndJavaHome() {
        let lines = ShellExports.lines(sdkPath: "/Users/me/Library/Android/sdk", java: java, shell: .zsh, homeDirectory: "/Users/me", includeCommandLineTool: false)
        #expect(lines == [
            "export JAVA_HOME=$(/usr/libexec/java_home -v 17)",
            "export ANDROID_HOME=$HOME/Library/Android/sdk",
            "export PATH=\"$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin\"",
        ])
    }

    @Test func fishSyntaxAndQuotedPaths() {
        let manual = JavaInstallation(home: "/opt/my jdk", version: "21", vendor: nil, name: nil, source: .settings)
        let lines = ShellExports.lines(sdkPath: "/Volumes/Dev Disk/sdk", java: manual, shell: .fish, homeDirectory: "/Users/me", includeCommandLineTool: false)
        #expect(lines[0] == "set -gx JAVA_HOME \"/opt/my jdk\"")
        #expect(lines[1] == "set -gx ANDROID_HOME \"/Volumes/Dev Disk/sdk\"")
        #expect(lines[2].hasPrefix("fish_add_path --append"))
    }

    @Test func shellFromPath() {
        #expect(ShellExports.Shell(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellExports.Shell(shellPath: "/bin/bash") == .bash)
        #expect(ShellExports.Shell(shellPath: nil) == .zsh)
    }
}

@Suite struct LocationSourceTests {
    @Test func roundTripsThroughJSON() throws {
        let sources: [LocationSource] = [.flag, .settings, .environment("ANDROID_HOME"), .defaultLocation, .javaHomeTool, .knownLocation]
        let data = try JSONEncoder().encode(sources)
        #expect(String(decoding: data, as: UTF8.self) == #"["flag","settings","env:ANDROID_HOME","default","java_home","known_location"]"#)
        #expect(try JSONDecoder().decode([LocationSource].self, from: data) == sources)
    }
}
