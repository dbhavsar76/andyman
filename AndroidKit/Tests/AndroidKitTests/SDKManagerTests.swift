import Foundation
import Testing
@testable import AndroidKit

@Suite struct PackageRevisionTests {
    @Test func parsesAndCompares() throws {
        #expect(PackageRevision("37.0.1") == PackageRevision(major: 37, minor: 0, micro: 1))
        #expect(PackageRevision("23.0") == PackageRevision(major: 23))
        #expect(PackageRevision("36.0.0 rc3")?.preview == 3)
        #expect(PackageRevision("36.0.0-rc3")?.preview == 3)
        #expect(PackageRevision("nope") == nil)

        let rc = try #require(PackageRevision("36.0.0 rc3"))
        let final = try #require(PackageRevision("36.0.0"))
        #expect(rc < final)
        #expect(try #require(PackageRevision("27.0.12077973")) < #require(PackageRevision("27.1.12297006")))
        #expect(!(final < final))
    }
}

let repositoryFixture = """
<?xml version="1.0"?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:generic="http://schemas.android.com/repository/android/generic/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <license id="android-sdk-license" type="text">Terms and Conditions
Be nice.</license>
  <channel id="channel-0">stable</channel>
  <channel id="channel-2">dev</channel>
  <remotePackage path="emulator">
    <revision><major>36</major><minor>1</minor><micro>9</micro></revision>
    <display-name>Android Emulator</display-name>
    <uses-license ref="android-sdk-license"/>
    <channelRef ref="channel-0"/>
    <archives>
      <archive><complete><size>100</size><checksum type="sha1">aaa</checksum><url>emulator-darwin_x64.zip</url></complete><host-os>macosx</host-os><host-arch>x64</host-arch></archive>
      <archive><complete><size>200</size><checksum type="sha1">bbb</checksum><url>emulator-darwin_aarch64.zip</url></complete><host-os>macosx</host-os><host-arch>aarch64</host-arch></archive>
      <archive><complete><size>300</size><checksum type="sha1">ccc</checksum><url>emulator-linux.zip</url></complete><host-os>linux</host-os></archive>
    </archives>
  </remotePackage>
  <remotePackage path="emulator">
    <revision><major>37</major><minor>3</minor><micro>1</micro></revision>
    <display-name>Android Emulator</display-name>
    <uses-license ref="android-sdk-license"/>
    <channelRef ref="channel-2"/>
    <archives><archive><complete><size>400</size><checksum type="sha1">ddd</checksum><url>emulator-dev.zip</url></complete><host-os>macosx</host-os></archive></archives>
  </remotePackage>
  <remotePackage path="platforms;android-36">
    <type-details xsi:type="sdk:platformDetailsType"><api-level>36</api-level></type-details>
    <revision><major>2</major></revision>
    <display-name>Android SDK Platform 36</display-name>
    <uses-license ref="android-sdk-license"/>
    <channelRef ref="channel-0"/>
    <archives><archive><complete><size>65878410</size><checksum type="sha1">eee</checksum><url>platform-36_r02.zip</url></complete></archive></archives>
  </remotePackage>
  <remotePackage path="tools" obsolete="true">
    <revision><major>26</major><minor>1</minor><micro>1</micro></revision>
    <display-name>Android SDK Tools</display-name>
    <channelRef ref="channel-0"/>
    <archives><archive><complete><size>1</size><checksum type="sha1">fff</checksum><url>tools.zip</url></complete></archive></archives>
  </remotePackage>
  <remotePackage path="linux-only">
    <revision><major>1</major></revision>
    <display-name>Linux Only</display-name>
    <channelRef ref="channel-0"/>
    <archives><archive><complete><size>1</size><checksum type="sha1">ggg</checksum><url>l.zip</url></complete><host-os>linux</host-os></archive></archives>
  </remotePackage>
</sdk:sdk-repository>
"""

let systemImageFixture = """
<?xml version="1.0"?>
<sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <license id="android-sdk-arm-dbt-license" type="text">ARM license</license>
  <channel id="channel-0">stable</channel>
  <remotePackage path="system-images;android-36;google_apis_playstore;arm64-v8a">
    <type-details xsi:type="sys-img:sysImgDetailsType">
      <api-level>36</api-level>
      <tag><id>google_apis_playstore</id><display>Google Play</display></tag>
      <vendor><id>google</id><display>Google Inc.</display></vendor>
      <abi>arm64-v8a</abi>
    </type-details>
    <revision><major>7</major></revision>
    <display-name>Google Play ARM 64 v8a System Image</display-name>
    <uses-license ref="android-sdk-arm-dbt-license"/>
    <dependencies><dependency path="emulator"><min-revision><major>35</major><minor>4</minor><micro>9</micro></min-revision></dependency></dependencies>
    <channelRef ref="channel-0"/>
    <archives><archive><complete><size>1886527965</size><checksum type="sha1">5b91</checksum><url>arm64-v8a-36_r07.zip</url></complete></archive></archives>
  </remotePackage>
</sys-img:sdk-sys-img>
"""

func fixtureCatalog(host: HostPlatform = HostPlatform(os: "macosx", arch: "aarch64")) -> RepositoryCatalog {
    let base = URL(string: "https://dl.google.com/android/repository/")!
    let main = RepositoryParser.parse(Data(repositoryFixture.utf8), baseURL: base, host: host)
    let images = RepositoryParser.parse(Data(systemImageFixture.utf8), baseURL: base.appending(path: "sys-img/google_apis_playstore/"), host: host)
    let licenses = Dictionary((main.licenses + images.licenses).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return RepositoryCatalog(packages: main.packages + images.packages, licenses: licenses, fetchedAt: Date())
}

@Suite struct RepositoryParserTests {
    @Test func parsesPackagesChannelsAndArchives() throws {
        let catalog = fixtureCatalog()
        #expect(catalog.licenses.keys.sorted() == ["android-sdk-arm-dbt-license", "android-sdk-license"])
        #expect(catalog.licenses["android-sdk-license"]?.text == "Terms and Conditions\nBe nice.")

        let stable = try #require(catalog.latest("emulator"))
        #expect(stable.revision == PackageRevision(major: 36, minor: 1, micro: 9))
        #expect(stable.archive?.sha1 == "bbb") // the aarch64 archive
        #expect(stable.archive?.url.absoluteString == "https://dl.google.com/android/repository/emulator-darwin_aarch64.zip")
        #expect(catalog.latest("emulator", channel: .dev)?.revision.major == 37)

        let platform = try #require(catalog.latest("platforms;android-36"))
        #expect(platform.apiLevel == "36")
        #expect(platform.category == .platforms)
        #expect(platform.archive?.size == 65878410) // no host-os: available everywhere

        #expect(catalog.latest("linux-only") == nil)
        #expect(catalog.packages.first { $0.id == "tools" }?.obsolete == true)

        let image = try #require(catalog.latest("system-images;android-36;google_apis_playstore;arm64-v8a"))
        #expect(image.tagIDs == ["google_apis_playstore"]) // vendor id isn't a tag
        #expect(image.tagDisplay == "Google Play")
        #expect(image.abi == "arm64-v8a")
        #expect(image.dependencies == [.init(id: "emulator", minRevision: PackageRevision(major: 35, minor: 4, micro: 9))])
        #expect(image.archive?.url.absoluteString == "https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-36_r07.zip")
    }

    @Test func intelMacGetsX64Archive() {
        let catalog = fixtureCatalog(host: HostPlatform(os: "macosx", arch: "x64"))
        #expect(catalog.latest("emulator")?.archive?.sha1 == "aaa")
    }

    @Test func parsesSiteList() {
        let xml = "<site><url>sys-img/android/sys-img2-3.xml</url></site><site><url>\n addon2-3.xml \n</url></site>"
        let urls = SiteListParser.siteURLs(Data(xml.utf8), baseURL: URL(string: "https://dl.google.com/android/repository/")!)
        #expect(urls.map(\.absoluteString) == [
            "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml",
            "https://dl.google.com/android/repository/addon2-3.xml",
        ])
    }
}

@Suite struct LocalPackageTests {
    static let packageXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02">
      <license id="android-sdk-license" type="text">…</license>
      <localPackage path="system-images;android-36;google_apis;arm64-v8a" obsolete="false">
        <type-details/>
        <revision><major>7</major></revision>
        <display-name>Google APIs ARM 64 v8a System Image</display-name>
        <uses-license ref="android-sdk-license"/>
        <dependencies><dependency path="emulator"><min-revision><major>35</major><minor>1</minor></min-revision></dependency></dependencies>
      </localPackage>
    </ns2:repository>
    """

    @Test func parsesPackageXML() throws {
        let package = try #require(LocalPackages.parsePackageXML(Data(Self.packageXML.utf8), path: "/sdk/x"))
        #expect(package.id == "system-images;android-36;google_apis;arm64-v8a")
        #expect(package.revision == PackageRevision(major: 7)) // not the dependency's min-revision
        #expect(package.displayName == "Google APIs ARM 64 v8a System Image")
        #expect(!package.obsolete)
    }

    @Test func scansFakeSDK() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        func write(_ relative: String, id: String, major: Int, minor: Int = 0) throws {
            let directory = sdk.root.appending(path: relative)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try """
            <ns2:repository><localPackage path="\(id)" obsolete="false"><revision><major>\(major)</major><minor>\(minor)</minor></revision><display-name>\(id)</display-name></localPackage></ns2:repository>
            """.write(to: directory.appending(path: "package.xml"), atomically: true, encoding: .utf8)
        }
        try write("platform-tools", id: "platform-tools", major: 37)
        try write("ndk/27.1.12297006", id: "ndk;27.1.12297006", major: 27, minor: 1)
        try write("system-images/android-36/google_apis/arm64-v8a", id: "system-images;android-36;google_apis;arm64-v8a", major: 7)
        try sdk.package("platforms/android-9", revision: "1") // legacy: source.properties without Pkg.Path → ignored
        let legacy = sdk.root.appending(path: "extras/old")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "Pkg.Path=extras;old\nPkg.Revision=2.1\nPkg.Desc=Old Thing\n".write(to: legacy.appending(path: "source.properties"), atomically: true, encoding: .utf8)

        let packages = LocalPackages.scan(sdkRoot: sdk.root)
        #expect(packages.map(\.id) == ["extras;old", "ndk;27.1.12297006", "platform-tools", "system-images;android-36;google_apis;arm64-v8a"])
        #expect(packages.first { $0.id == "extras;old" }?.revision == PackageRevision(major: 2, minor: 1))
    }
}

@Suite struct InstallPlanTests {
    let catalog = fixtureCatalog()

    func local(_ id: String, _ revision: String) -> LocalPackage {
        LocalPackage(id: id, displayName: id, revision: PackageRevision(revision)!, path: "/sdk", obsolete: false)
    }

    @Test func pullsInMissingDependencyFirst() throws {
        let plan = try catalog.installPlan(for: ["system-images;android-36;google_apis_playstore;arm64-v8a"], installed: [])
        #expect(plan.packages.map(\.id) == ["emulator", "system-images;android-36;google_apis_playstore;arm64-v8a"])
        #expect(plan.licenses.map(\.id) == ["android-sdk-arm-dbt-license", "android-sdk-license"])
        #expect(plan.downloadSize == 200 + 1886527965)
    }

    @Test func skipsSatisfiedDependencyAndInstalledPackages() throws {
        let plan = try catalog.installPlan(
            for: ["system-images;android-36;google_apis_playstore;arm64-v8a", "platforms;android-36"],
            installed: [local("emulator", "35.5.0"), local("platforms;android-36", "2")]
        )
        #expect(plan.packages.map(\.id) == ["system-images;android-36;google_apis_playstore;arm64-v8a"])
    }

    @Test func updatesTooOldDependency() throws {
        let plan = try catalog.installPlan(for: ["system-images;android-36;google_apis_playstore;arm64-v8a"], installed: [local("emulator", "34.0.0")])
        #expect(plan.packages.first?.id == "emulator")
        #expect(plan.packages.first?.revision == PackageRevision("36.1.9"))
    }

    @Test func requestingInstalledOldPackageUpdatesIt() throws {
        let plan = try catalog.installPlan(for: ["emulator"], installed: [local("emulator", "35.0.0")])
        #expect(plan.packages.map(\.revision) == [PackageRevision("36.1.9")])
        #expect(try catalog.installPlan(for: ["emulator"], installed: [local("emulator", "36.1.9")]).isEmpty)
    }

    @Test func channelPicksNewerVersions() throws {
        let plan = try catalog.installPlan(for: ["emulator"], installed: [], channel: .dev)
        #expect(plan.packages.first?.revision.major == 37)
    }

    @Test func acceptsSlashIDsAndRejectsUnknown() throws {
        #expect(try catalog.installPlan(for: ["platforms/android-36"], installed: []).packages.map(\.id) == ["platforms;android-36"])
        #expect(throws: InstallPlanError.unknownPackage("nope")) { try catalog.installPlan(for: ["nope"], installed: []) }
        #expect(throws: InstallPlanError.unavailableHere("linux-only")) { try catalog.installPlan(for: ["linux-only"], installed: []) }
    }
}

@Suite struct SDKPackageListTests {
    @Test func mergesInstalledAndAvailable() {
        let catalog = fixtureCatalog()
        let installed = [
            LocalPackage(id: "emulator", displayName: "Android Emulator", revision: PackageRevision("35.0.0")!, path: "/sdk/emulator", obsolete: false),
            LocalPackage(id: "tools", displayName: "Old Tools", revision: PackageRevision("26.1.1")!, path: "/sdk/tools", obsolete: true),
            LocalPackage(id: "system-images;android-37.2-beta3;google_apis_ps16k;arm64-v8a", displayName: "Beta", revision: PackageRevision("3")!, path: "/x", obsolete: false),
        ]
        let list = SDKPackageList(catalog: catalog, installed: installed)
        #expect(list.updates.map(\.id) == ["emulator"])
        #expect(list.package("tools")?.isInstalled == true) // obsolete but installed: still listed
        #expect(list.package("platforms;android-36")?.isInstalled == false)
        #expect(list.package("system-images;android-37.2-beta3;google_apis_ps16k;arm64-v8a")?.available == nil)
        #expect(list.packages(in: .tools).map(\.id).sorted() == ["emulator", "tools"])

        let withoutTools = SDKPackageList(catalog: catalog, installed: [])
        #expect(withoutTools.package("tools") == nil) // obsolete and not installed: hidden
    }

    @Test func hidesReleaseCandidatesOnStable() {
        var catalog = fixtureCatalog()
        var rc = catalog.latest("platforms;android-36")!
        rc.id = "ndk;30.0.1"
        rc.revision = PackageRevision("30.0.1 rc2")!
        catalog.packages.append(rc)
        #expect(SDKPackageList(catalog: catalog, installed: []).package("ndk;30.0.1") == nil)
        #expect(SDKPackageList(catalog: catalog, installed: [], channel: .beta).package("ndk;30.0.1") != nil)
    }

    @Test func hidesCodenamedPreviewsAndSortsByAPILevel() {
        var catalog = fixtureCatalog()
        let base = catalog.latest("platforms;android-36")!
        func platform(_ id: String, api: String, codename: String? = nil) -> RemotePackage {
            var package = base
            package.id = id
            package.apiLevel = api
            package.codename = codename
            return package
        }
        catalog.packages += [
            platform("platforms;android-CANARY", api: "37.1", codename: "CANARY"),
            platform("platforms;android-37.2", api: "37.2"),
            platform("platforms;android-9", api: "9"),
        ]
        // Mixed with packages that have no API level (the emulator), which once broke the sort.
        let stable = SDKPackageList(catalog: catalog, installed: []).packages(in: .platforms).map(\.id)
        let fullOrder = SDKPackageList(catalog: catalog, installed: []).packages.map(\.id).filter { $0.hasPrefix("platforms") }
        #expect(fullOrder == ["platforms;android-37.2", "platforms;android-36", "platforms;android-9"])
        #expect(stable == ["platforms;android-37.2", "platforms;android-36", "platforms;android-9"])
        let beta = SDKPackageList(catalog: catalog, installed: [], channel: .beta).packages(in: .platforms).map(\.id)
        #expect(beta == ["platforms;android-37.2", "platforms;android-CANARY", "platforms;android-36", "platforms;android-9"])
    }
}

@Suite struct LicenseAndLockTests {
    @Test func acceptsLicensesOnce() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        let store = LicenseStore(sdkRoot: sdk.root)
        let license = SDKLicense(id: "android-sdk-license", text: "Terms")
        #expect(!store.isAccepted(license.id))
        try store.accept(license)
        try store.accept(license)
        #expect(store.isAccepted(license.id))
        let contents = try String(contentsOf: sdk.root.appending(path: "licenses/android-sdk-license"), encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 1)

        let plan = InstallPlan(packages: [], licenses: [license, SDKLicense(id: "other", text: "x")], downloadSize: 0)
        #expect(store.unaccepted(in: plan).map(\.id) == ["other"])
    }

    @Test func lockIsExclusive() throws {
        let sdk = try FakeSDK(); defer { sdk.remove() }
        let lock = try SDKLock.acquire(sdkRoot: sdk.root)
        #expect(throws: SDKInstallError.locked) { try SDKLock.acquire(sdkRoot: sdk.root) }
        lock.release()
        try SDKLock.acquire(sdkRoot: sdk.root).release()
    }

    @Test func mapsPackageIDsToFolders() {
        let root = URL(fileURLWithPath: "/sdk")
        #expect(SDKInstaller.directory(for: "ndk;27.1.12297006", in: root)?.path == "/sdk/ndk/27.1.12297006")
        #expect(SDKInstaller.versionString(PackageRevision("36.0.0 rc3")!) == "36.0.0-rc3")
    }
}

/// Real network + real Android CLI, installing into a throwaway SDK. Skipped when either is missing.
@Suite struct SDKInstallIntegrationTests {
    static let realSDK = URL(fileURLWithPath: SDKLocator.defaultPath)
    static var cliTools: URL? {
        let tools = realSDK.appending(path: "cmdline-tools/latest")
        return FileManager.default.isExecutableFile(atPath: tools.appending(path: "bin/android").path) ? tools : nil
    }

    @Test(.enabled(if: cliTools != nil), .timeLimit(.minutes(5)))
    func downloadsCatalogAndInstallsAPlatform() async throws {
        // The install needs command-line tools inside the target SDK; link the real ones in.
        let sdk = try FakeSDK(); defer { sdk.remove() }
        try FileManager.default.createDirectory(at: sdk.root.appending(path: "cmdline-tools"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sdk.root.appending(path: "cmdline-tools/latest"), withDestinationURL: try #require(Self.cliTools))

        let cache = FileManager.default.temporaryDirectory.appending(path: "repo-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let catalog = try await RepositoryClient(cacheDirectory: cache).catalog()
        #expect(catalog.packages.count > 500)
        #expect(catalog.latest("platform-tools") != nil)
        #expect(catalog.packages.contains { $0.category == .systemImages && $0.tagIDs.contains("google_apis_playstore") })
        #expect(RepositoryClient(cacheDirectory: cache).cachedCatalog() != nil)

        let plan = try catalog.installPlan(for: ["platforms;android-31"], installed: LocalPackages.scan(sdkRoot: sdk.root))
        #expect(plan.packages.map(\.id) == ["platforms;android-31"])

        var events: [InstallEvent] = []
        for try await event in SDKInstaller(sdkRoot: sdk.root, java: nil, environment: [:]).install(plan) {
            events.append(event)
        }
        #expect(events.first == .started("platforms;android-31"))
        #expect(events.last == .finished("platforms;android-31"))
        #expect(events.contains { if case .downloading = $0 { true } else { false } })
        let installed = LocalPackages.scan(sdkRoot: sdk.root)
        #expect(installed.contains { $0.id == "platforms;android-31" })

        try await SDKInstaller(sdkRoot: sdk.root, java: nil, environment: [:]).uninstall(["platforms;android-31"])
        #expect(!LocalPackages.scan(sdkRoot: sdk.root).contains { $0.id == "platforms;android-31" })
    }
}
