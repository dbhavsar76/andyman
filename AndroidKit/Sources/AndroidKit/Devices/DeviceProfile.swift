import Foundation

/// A hardware profile to create AVDs from ("Pixel 9", "Medium Tablet", "Wear OS Small Round"…),
/// as defined in the SDK's device XML files.
public struct DeviceProfile: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var manufacturer: String?
    public var category: VirtualDevice.FormFactor
    /// Old profiles Android Studio lists under "Legacy".
    public var isLegacy: Bool
    /// Defined by the user (in `~/.android/devices.xml`) rather than shipped with the SDK.
    public var isUserDefined: Bool
    public var diagonalInches: Double?
    public var screenWidth: Int?
    public var screenHeight: Int?
    public var density: Int?
    public var ramMB: Int?
    /// Device frame name under `<sdk>/skins`.
    public var skin: String?
    /// System image tag the profile needs (`android-wear`, `android-tv`…), if any.
    public var tagID: String?
    /// Lowest API level the profile supports, from `<d:api-level>` like `35-`.
    public var minAPILevel: Double?
    public var playStore: Bool
    public var hasHinge: Bool

    /// `6.3″ · 1080 × 2424 · 420 dpi`
    public var summary: String {
        var parts: [String] = []
        if let diagonalInches { parts.append("\(Self.formatInches(diagonalInches))″") }
        if let screenWidth, let screenHeight { parts.append("\(screenWidth) × \(screenHeight)") }
        if let density { parts.append("\(density) dpi") }
        return parts.joined(separator: " · ")
    }

    /// `8.0` → `8`, `6.3` → `6.3` (also used for API levels like `36.1`).
    public static func formatInches(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Loads device profiles from the SDK and the user's own definitions.
public enum DeviceProfiles {
    /// Profiles shipped in the command-line tools (inside `sdklib.core.jar`) plus user-defined ones.
    /// Newest-looking first within each category is left to the UI; this returns file order.
    public static func load(sdkRoot: URL, cmdlineTools: URL?, environment: [String: String]) async -> [DeviceProfile] {
        var profiles: [DeviceProfile] = []
        if let jar = cmdlineTools.flatMap(sdklibJar) {
            for xml in await extractDeviceXML(from: jar) {
                profiles += DeviceProfileParser.parse(xml, userDefined: false)
            }
        }
        // User-defined profiles (Android Studio's "New Hardware Profile").
        let userFile = androidUserHome(environment: environment).appending(path: "devices.xml")
        if let data = try? Data(contentsOf: userFile) {
            profiles += DeviceProfileParser.parse(data, userDefined: true)
        }

        // Later definitions win (user overrides shipped ones with the same id).
        var seen = Set<String>()
        return Array(profiles.reversed().filter { seen.insert($0.id).inserted }.reversed())
    }

    static func sdklibJar(in cmdlineTools: URL) -> URL? {
        let jar = cmdlineTools.appending(path: "lib/sdklib/sdklib.core.jar")
        return FileManager.default.fileExists(atPath: jar.path) ? jar : nil
    }

    /// `ANDROID_USER_HOME`, legacy `ANDROID_EMULATOR_HOME`/`ANDROID_SDK_HOME`, or `~/.android`.
    public static func androidUserHome(environment: [String: String]) -> URL {
        if let path = environment["ANDROID_USER_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if let path = environment["ANDROID_EMULATOR_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if let path = environment["ANDROID_SDK_HOME"], !path.isEmpty { return URL(fileURLWithPath: path).appending(path: ".android") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android", directoryHint: .isDirectory)
    }

    /// Reads `com/android/sdklib/devices/*.xml` out of the jar with the system `unzip`.
    static func extractDeviceXML(from jar: URL, runner: ProcessRunner = ProcessRunner()) async -> [Data] {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard let listing = try? await runner.run(unzip, arguments: ["-Z1", jar.path], timeout: .seconds(10)), listing.succeeded else {
            return []
        }
        let entries = listing.stdoutString.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("com/android/sdklib/devices/") && $0.hasSuffix(".xml") }
        var documents: [Data] = []
        for entry in entries {
            if let result = try? await runner.run(unzip, arguments: ["-p", jar.path, entry], timeout: .seconds(10)), result.succeeded {
                documents.append(result.stdout)
            }
        }
        return documents
    }
}

/// SAX parser for the `d:devices` XML schema.
final class DeviceProfileParser: NSObject, XMLParserDelegate {
    private struct Draft {
        var deprecated = false
        var name: String?
        var id: String?
        var manufacturer: String?
        var diagonal: Double?
        var width: Int?
        var height: Int?
        var density: Int?
        var ramMB: Int?
        var skin: String?
        var tagID: String?
        var apiLevel: String?
        var playStore = false
        var hasHinge = false
    }

    private let userDefined: Bool
    private var profiles: [DeviceProfile] = []
    private var draft: Draft?
    private var path: [String] = []
    private var text = ""
    private var ramUnit = "MiB"

    private init(userDefined: Bool) {
        self.userDefined = userDefined
    }

    static func parse(_ data: Data, userDefined: Bool) -> [DeviceProfile] {
        let delegate = DeviceProfileParser(userDefined: userDefined)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.profiles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(elementName)
        text = ""
        switch elementName {
        case "device":
            draft = Draft(deprecated: attributes["deprecated"] == "true")
        case "ram":
            ramUnit = attributes["unit"] ?? "MiB"
        case "hinge":
            draft?.hasHinge = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft != nil else { return }

        // Only direct children of <device> for name/id/manufacturer (other elements reuse these names).
        let parent = path.dropLast().last
        switch elementName {
        case "name" where parent == "device": draft?.name = value
        case "id" where parent == "device": draft?.id = value
        case "manufacturer" where parent == "device": draft?.manufacturer = value
        case "playstore-enabled": draft?.playStore = value == "true"
        case "diagonal-length": draft?.diagonal = Double(value)
        case "x-dimension" where parent == "dimensions": draft?.width = Int(value)
        case "y-dimension" where parent == "dimensions": draft?.height = Int(value)
        case "pixel-density": draft?.density = Self.dpi(value)
        case "ram": draft?.ramMB = Self.megabytes(value, unit: ramUnit)
        case "skin": draft?.skin = value.isEmpty || value == "_no_skin" ? nil : value
        case "tag-id": draft?.tagID = value
        case "api-level": draft?.apiLevel = value
        case "device":
            if let profile = draft.flatMap(makeProfile) { profiles.append(profile) }
            draft = nil
        default:
            break
        }
    }

    private func makeProfile(_ draft: Draft) -> DeviceProfile? {
        guard let name = draft.name else { return nil }
        let id = draft.id ?? name
        var config: [String: String] = ["hw.device.name": id]
        if let width = draft.width { config["hw.lcd.width"] = String(width) }
        if let height = draft.height { config["hw.lcd.height"] = String(height) }
        if let density = draft.density { config["hw.lcd.density"] = String(density) }
        if draft.hasHinge { config["hw.sensor.hinge"] = "yes" }

        return DeviceProfile(
            id: id,
            name: name,
            manufacturer: draft.manufacturer,
            category: AVDCatalog.formFactor(config: config, tagIDs: draft.tagID.map { [$0] } ?? []),
            isLegacy: draft.deprecated,
            isUserDefined: userDefined,
            diagonalInches: draft.diagonal,
            screenWidth: draft.width,
            screenHeight: draft.height,
            density: draft.density,
            ramMB: draft.ramMB,
            skin: draft.skin,
            tagID: draft.tagID,
            minAPILevel: draft.apiLevel.flatMap(Self.minAPI),
            playStore: draft.playStore,
            hasHinge: draft.hasHinge
        )
    }

    /// `420dpi` → 420; density buckets map to their nominal dpi.
    static func dpi(_ value: String) -> Int? {
        let buckets = ["ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640]
        if let bucket = buckets[value] { return bucket }
        return Int(value.replacingOccurrences(of: "dpi", with: ""))
    }

    static func megabytes(_ value: String, unit: String) -> Int? {
        guard let number = Double(value) else { return nil }
        switch unit {
        case "GiB": return Int(number * 1024)
        case "KiB": return Int(number / 1024)
        case "B": return Int(number / 1_048_576)
        default: return Int(number)
        }
    }

    /// `35-` → 35, `29-33` → 29, `28` → 28.
    static func minAPI(_ value: String) -> Double? {
        let lower = value.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? value
        return Double(lower.trimmingCharacters(in: .whitespaces))
    }
}
