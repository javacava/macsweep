import Foundation
import Testing
@testable import SweepCore

@Suite struct AppInfoTests {
    @Test func readsInfoPlist() {
        let s = Sandbox()
        let url = s.app("/Applications/Foo.app", id: "com.acme.foo", name: "Foo", version: "2.1", build: "210",
                        feed: "https://acme.com/appcast.xml", appStore: true)
        let app = AppInfo(bundle: url)!
        #expect(app.bundleID == "com.acme.foo")
        #expect(app.name == "Foo")
        #expect(app.version == "2.1")
        #expect(app.build == "210")
        #expect(app.feedURL?.absoluteString == "https://acme.com/appcast.xml")
        #expect(app.isAppStore)
        #expect(!app.isApple)
    }

    @Test func bundleWithoutPlistIsSkipped() {
        let s = Sandbox()
        s.dir("/Applications/Broken.app/Contents")
        #expect(AppInfo(bundle: s.env.resolve("/Applications/Broken.app")) == nil)
    }

    @Test func scannerFindsAppsInSubfoldersAndHome() {
        let s = Sandbox()
        s.app("/Applications/Zed.app", id: "dev.zed", name: "Zed")
        s.app("/Applications/Utilities/Tool.app", id: "com.x.tool", name: "Tool")
        s.app("~/Applications/Mine.app", id: "com.me.mine", name: "Mine")
        s.file("/Applications/readme.txt")
        let names = AppScanner.installedApps(env: s.env).map(\.name)
        #expect(names == ["Mine", "Tool", "Zed"])
    }
}

@Suite struct LeftoverMatchingTests {
    @Test(arguments: [
        "com.acme.foo", "com.acme.foo.plist", "com.acme.foo.savedState", "com.acme.foo.helper",
        "ABCDE12345.com.acme.foo", "group.com.acme.foo", "Foo", "foo.log",
    ])
    func matches(_ name: String) {
        #expect(LeftoverFinder.matches(name: name, bundleID: "com.acme.foo", appName: "Foo"))
    }

    @Test(arguments: ["com.acme.foobar", "com.acme.fo", "FooBar", "com.other.app", "acme"])
    func doesNotMatch(_ name: String) {
        #expect(!LeftoverFinder.matches(name: name, bundleID: "com.acme.foo", appName: "Foo"))
    }

    @Test func shortAppNamesDoNotMatchByName() {
        #expect(!LeftoverFinder.matches(name: "Go", bundleID: "com.x.go", appName: "Go"))
    }

    @Test func nameMatchIgnoresSpacesAndCase() {
        #expect(LeftoverFinder.matches(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", appName: "visual-studio code"))
    }

    @Test func bundleIDHeuristics() {
        #expect(LeftoverFinder.looksLikeBundleID("com.acme.foo"))
        #expect(!LeftoverFinder.looksLikeBundleID("com.acme"))
        #expect(!LeftoverFinder.looksLikeBundleID("Some Folder"))
        #expect(!LeftoverFinder.looksLikeBundleID("foo.bar.baz"))
        #expect(LeftoverFinder.isSystemID("com.apple.finder"))
    }
}

@Suite struct LeftoverFinderTests {
    func makeFoo(_ s: Sandbox) -> AppInfo {
        AppInfo(bundle: s.app("/Applications/Foo.app", id: "com.acme.foo", name: "Foo"))!
    }

    @Test func findsLeftoversAcrossLibraryFolders() {
        let s = Sandbox()
        let app = makeFoo(s)
        s.file("~/Library/Application Support/Foo/data.db", bytes: 3000)
        s.file("~/Library/Caches/com.acme.foo/c", bytes: 3000)
        s.file("~/Library/Preferences/com.acme.foo.plist", bytes: 300)
        s.file("~/Library/Saved Application State/com.acme.foo.savedState/x", bytes: 300)
        s.file("~/Library/Group Containers/TEAM123.com.acme.foo/g", bytes: 300)
        s.file("/Library/LaunchDaemons/com.acme.foo.helper.plist", bytes: 300)
        s.file("~/Library/Application Support/Other/x", bytes: 300)
        let found = LeftoverFinder(env: s.env).leftovers(for: app)
        #expect(found.count == 6)
        #expect(!found.contains { $0.url.lastPathComponent == "Other" })
        #expect(found.allSatisfy { !$0.location.isEmpty })
    }

    @Test func findsSandboxContainerByMetadata() {
        let s = Sandbox()
        let app = makeFoo(s)
        s.plist("~/Library/Containers/7F3A-UUID/.com.apple.containermanagerd.metadata.plist",
                ["MCMMetadataIdentifier": "com.acme.foo"])
        s.file("~/Library/Containers/7F3A-UUID/Data/file", bytes: 3000)
        let found = LeftoverFinder(env: s.env).leftovers(for: app)
        #expect(found.map { $0.url.lastPathComponent } == ["7F3A-UUID"])
    }

    @Test func appleAppsHaveNoLeftovers() {
        let s = Sandbox()
        let app = AppInfo(url: s.env.resolve("/Applications/Notes.app"), name: "Notes", bundleID: "com.apple.Notes", version: "1")
        s.file("~/Library/Preferences/com.apple.Notes.plist")
        #expect(LeftoverFinder(env: s.env).leftovers(for: app).isEmpty)
    }

    @Test func uninstallPlanTargetsAppAndSelectedLeftovers() {
        let s = Sandbox()
        let app = makeFoo(s)
        s.file("~/Library/Caches/com.acme.foo/c", bytes: 3000)
        s.file("~/Library/Preferences/com.acme.foo.plist", bytes: 300)
        let plan = Uninstaller.plan(for: app, env: s.env)
        #expect(plan.appSize > 0)
        #expect(plan.total > plan.appSize)
        let prefs = plan.leftovers.first { $0.url.pathExtension == "plist" }!
        let targets = plan.targets(includingApp: true, selectedLeftovers: [prefs.id])
        #expect(targets.map(\.url) == [app.url, prefs.url])
        #expect(plan.targets(includingApp: false, selectedLeftovers: []).isEmpty)

        let r = Cleaner(env: s.env, remover: RecordingRemover()).remove(targets)
        #expect(r.removed.count == 2)
        #expect(!s.exists("/Applications/Foo.app"))
        #expect(s.exists("~/Library/Caches/com.acme.foo/c"), "unselected leftover kept")
    }

    @Test func orphansAreItemsOfUninstalledApps() {
        let s = Sandbox()
        let installed = [makeFoo(s)]
        s.file("~/Library/Preferences/com.acme.foo.plist")           // installed app
        s.file("~/Library/Preferences/com.gone.app.plist", bytes: 500)  // orphan
        s.file("~/Library/Preferences/com.apple.dock.plist")           // system
        s.file("~/Library/Application Support/Some Folder/x")          // not reverse-DNS
        s.plist("~/Library/Containers/UUID-1/.com.apple.containermanagerd.metadata.plist",
                ["MCMMetadataIdentifier": "com.removed.thing"])
        let orphans = LeftoverFinder(env: s.env).orphans(installed: installed)
        #expect(Set(orphans.map { $0.url.lastPathComponent }) == ["com.gone.app.plist", "UUID-1"])
    }
}

@Suite struct VersionCompareTests {
    @Test(arguments: [
        ("1.10", "1.9"), ("2.0", "1.99.9"), ("1.2.1", "1.2"), ("1.2", "1.2b3"), ("v3.0", "2.9"), ("1.0rc2", "1.0rc1"),
        ("10", "9"),
    ])
    func newer(_ pair: (String, String)) {
        #expect(VersionCompare.isNewer(pair.0, than: pair.1))
        #expect(!VersionCompare.isNewer(pair.1, than: pair.0))
    }

    @Test func equalVersions() {
        #expect(VersionCompare.compare("2.0", "2") == .orderedSame)
        #expect(VersionCompare.compare("1.0.0", "1") == .orderedSame)
        #expect(!VersionCompare.isNewer("1.0", than: "1.0"))
    }
}

@Suite struct AppcastTests {
    let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version 2.3</title>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://acme.com/Foo-2.3.zip" sparkle:version="230" sparkle:shortVersionString="2.3" length="1"/>
        </item>
        <item>
          <title>Version 3.0</title>
          <sparkle:version>300</sparkle:version>
          <sparkle:shortVersionString>3.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://acme.com/Foo-3.0.zip" length="1"/>
        </item>
        <item>
          <title>Version 2.2</title>
          <enclosure url="https://acme.com/Foo-2.2.zip" sparkle:version="220" sparkle:shortVersionString="2.2"/>
        </item>
      </channel>
    </rss>
    """.data(using: .utf8)!

    @Test func parsesAttributesAndElements() {
        let items = AppcastParser.parse(feed)
        #expect(items.count == 3)
        #expect(items[0].shortVersion == "2.3")
        #expect(items[0].build == "230")
        #expect(items[0].downloadURL?.absoluteString == "https://acme.com/Foo-2.3.zip")
        #expect(items[1].shortVersion == "3.0")
        #expect(items[1].minimumSystemVersion == "99.0")
    }

    @Test func latestRespectsSystemVersion() {
        let items = AppcastParser.parse(feed)
        #expect(AppcastParser.latest(items, systemVersion: "14.5")?.shortVersion == "2.3")
        #expect(AppcastParser.latest(items, systemVersion: nil)?.shortVersion == "3.0")
    }

    @Test func evaluateFindsUpdate() {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Foo.app"), name: "Foo", bundleID: "com.acme.foo",
                          version: "2.2", build: "220")
        let update = UpdateChecker.evaluate(app, feedData: feed, systemVersion: "14.0")
        #expect(update?.latest.shortVersion == "2.3")
    }

    @Test func evaluateCurrentAppHasNoUpdate() {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Foo.app"), name: "Foo", bundleID: "com.acme.foo",
                          version: "2.3", build: "230")
        #expect(UpdateChecker.evaluate(app, feedData: feed, systemVersion: "14.0") == nil)
        #expect(UpdateChecker.evaluate(app, feedData: Data("garbage".utf8)) == nil)
    }

    @Test func noFeedMeansNoNetworkCall() async {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Foo.app"), name: "Foo", bundleID: "com.acme.foo", version: "1")
        #expect(await UpdateChecker.check(app) == nil)
        let http = AppInfo(url: app.url, name: "Foo", bundleID: "x.y.z", version: "1", feedURL: URL(string: "http://insecure.example/a.xml"))
        #expect(await UpdateChecker.check(http) == nil, "plain http feeds are ignored")
    }
}
