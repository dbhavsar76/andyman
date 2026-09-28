import Foundation

/// Reads the handful of values we need from Gradle build files without running Gradle.
///
/// This is pattern matching, not a Groovy/Kotlin parser: it understands the ways React Native
/// and Expo templates write these values (`ext { … }`, `ext.x = …`, `extra["x"] = …`,
/// `val x by extra(…)`, and literals in `android { … }`), which covers real projects well.
enum GradleScript {
    /// The Android build values a project can declare.
    enum Key: String, CaseIterable, Sendable {
        case compileSdk, targetSdk, minSdk, buildTools, ndk, cmake, kotlin

        /// Names used for the root project's extra properties.
        var extNames: [String] {
            switch self {
            case .compileSdk: ["compileSdkVersion", "compileSdk"]
            case .targetSdk: ["targetSdkVersion", "targetSdk"]
            case .minSdk: ["minSdkVersion", "minSdk"]
            case .buildTools: ["buildToolsVersion"]
            case .ndk: ["ndkVersion"]
            case .cmake: ["cmakeVersion"]
            case .kotlin: ["kotlinVersion"]
            }
        }

        /// Property names in the `android { }` block of a module's build file.
        var dslNames: [String] {
            switch self {
            case .compileSdk: ["compileSdk", "compileSdkVersion"]
            case .targetSdk: ["targetSdk", "targetSdkVersion"]
            case .minSdk: ["minSdk", "minSdkVersion"]
            case .buildTools: ["buildToolsVersion"]
            case .ndk: ["ndkVersion"]
            case .cmake, .kotlin: []
            }
        }

        /// Keys in React Native's `gradle/libs.versions.toml`.
        var catalogName: String? {
            switch self {
            case .compileSdk: "compileSdk"
            case .targetSdk: "targetSdk"
            case .minSdk: "minSdk"
            case .buildTools: "buildTools"
            case .ndk: "ndkVersion"
            case .kotlin: "kotlin"
            case .cmake: nil
            }
        }

        /// Expo's `gradle.properties` overrides (see expo-autolinking's settings plugin).
        var expoPropertyName: String? {
            switch self {
            case .compileSdk: "android.compileSdkVersion"
            case .targetSdk: "android.targetSdkVersion"
            case .minSdk: "android.minSdkVersion"
            case .buildTools: "android.buildToolsVersion"
            case .kotlin: "android.kotlinVersion"
            case .ndk, .cmake: nil
            }
        }
    }

    /// Drops `//` and `/* */` comments, keeping `//` inside URLs (`https://…`).
    static func strippingComments(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)(^|[\s;{}])//.*$"#, with: "$1", options: .regularExpression)
        return result
    }

    private static let value = #"["']?([0-9A-Za-z][\w.\-]*)["']?"#

    /// Values assigned to the root project's extra properties.
    static func extValues(_ script: String) -> [Key: String] {
        let text = strippingComments(script)
        var values: [Key: String] = [:]
        for key in Key.allCases {
            for name in key.extNames {
                let patterns = [
                    // ext.ndkVersion = "…" or `ndkVersion = "…"` inside ext { }
                    #"(?m)(?:^|[\s{;])(?:ext\.)?\#(name)\s*=\s*\#(value)"#,
                    // extra["ndkVersion"] = "…" / extra.set("ndkVersion", "…") / set('ndkVersion', …)
                    #"extra\[\s*["']\#(name)["']\s*\]\s*=\s*\#(value)"#,
                    #"(?:extra\.)?set\(\s*["']\#(name)["']\s*,\s*\#(value)\s*\)"#,
                    // val ndkVersion by extra("…")
                    #"val\s+\#(name)\s+by\s+extra\(\s*\#(value)\s*\)"#,
                ]
                if let match = patterns.lazy.compactMap({ firstCapture($0, in: text) }).first,
                   isLiteral(match) {
                    values[key] = match
                    break
                }
            }
        }
        return values
    }

    /// Literal values set in a module's `android { }` block (references like
    /// `rootProject.ext.compileSdkVersion` are skipped: those come from the root project).
    static func moduleValues(_ script: String) -> [Key: String] {
        let text = strippingComments(script)
        var values: [Key: String] = [:]
        for key in Key.allCases {
            for name in key.dslNames {
                // compileSdk 35 / compileSdk = 35 / ndkVersion "27.1…" / ndkVersion = "…"
                let pattern = #"(?m)(?:^|[\s{;])\#(name)\s*(?:=\s*|\s)\s*(["']?)([0-9][\w.\-]*)\1(?=\s|$|;|\))"#
                if let match = captures(pattern, in: text)?.last {
                    values[key] = match
                    break
                }
            }
        }
        // externalNativeBuild { cmake { version "3.22.1" } }
        if let version = firstCapture(#"cmake\s*\{[^}]*?\bversion\s*(?:=\s*|\s)\s*["']([0-9][\d.]*)["']"#, in: text) {
            values[.cmake] = version
        }
        return values
    }

    /// Versions from a TOML version catalog's `[versions]` table.
    static func catalogVersions(_ toml: String) -> [String: String] {
        var versions: [String: String] = [:]
        var inVersions = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inVersions = line == "[versions]"
                continue
            }
            guard inVersions, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !name.isEmpty, !value.isEmpty { versions[name] = value }
        }
        return versions
    }

    /// The Android Gradle Plugin version a project applies: from the `plugins { }` block in
    /// settings.gradle (`id "com.android.application" version "8.7.0"`), or a buildscript
    /// `classpath "com.android.tools.build:gradle:8.1.0"`.
    static func androidGradlePluginVersion(settings: String, rootBuild: String) -> String? {
        let pluginPattern = #"id\s*\(?\s*["']com\.android\.(?:application|library)["']\s*\)?\s*version\s*["']([0-9][\w.\-]*)["']"#
        let classpathPattern = #"com\.android\.tools\.build:gradle:([0-9][\w.\-]*)"#
        return firstCapture(pluginPattern, in: strippingComments(settings))
            ?? firstCapture(pluginPattern, in: strippingComments(rootBuild))
            ?? firstCapture(classpathPattern, in: strippingComments(rootBuild))
    }

    /// The Gradle version from a wrapper's `distributionUrl` (`…/gradle-9.3.1-bin.zip`).
    static func wrapperVersion(distributionURL: String) -> String? {
        firstCapture(#"gradle-([0-9][\w.\-]*?)-(?:bin|all)\.zip"#, in: distributionURL)
    }

    private static func isLiteral(_ value: String) -> Bool {
        value.first?.isNumber ?? false
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.last
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
