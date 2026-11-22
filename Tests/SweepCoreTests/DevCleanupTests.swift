import Foundation
import Testing
@testable import SweepCore

@Suite struct DevFolderTests {
    @Test func findsFirmwareXcodeAndPackageCaches() {
        let s = Sandbox()
        s.file("~/Library/iTunes/iPhone Software Updates/iPhone17,1_18.5_Restore.ipsw", bytes: 9000)
        s.file("~/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5 (21F90)/Symbols/x", bytes: 9000)
        s.file("~/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 9000)
        s.file("~/Library/Developer/Xcode/Archives/2025-01-01/App.xcarchive/x", bytes: 9000)
        s.file("~/.npm/_cacache/content-v2/sha512/ab", bytes: 9000)
        s.file("~/Library/pnpm/store/v3/files/00/x", bytes: 9000)
        let items = DevFolderScanner(env: s.env).scan()
        func item(_ title: String) -> DevItem? { items.first { $0.title == title } }

        #expect(item("iPhone17,1_18.5_Restore.ipsw")?.group == .firmware)
        #expect(item("iPhone15,2 17.5 (21F90)")?.group == .firmware)
        #expect(item("App-abc")?.group == .xcode)
        #expect(item("App-abc")?.selectedByDefault == true)
        #expect(item("2025-01-01")?.selectedByDefault == false, "archives hold shipped builds")
        #expect(item("npm")?.group == .packageCaches)
        #expect(item("npm")?.removal.names == ["_cacache"])
        #expect(item("pnpm (store)")?.selectedByDefault == false)
        #expect(items.allSatisfy { $0.size > 0 })
    }

    @Test func emptyOrMissingFoldersGiveNothing() {
        let s = Sandbox()
        s.dir("~/.npm/_cacache")
        #expect(DevFolderScanner(env: s.env).scan().isEmpty)
    }

    @Test func androidEmulatorTakesItsIniAlong() {
        let s = Sandbox()
        s.file("~/.android/avd/Pixel_8.avd/userdata.img", bytes: 9000)
        s.file("~/.android/avd/Pixel_8.ini", bytes: 50)
        s.file("~/Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img", bytes: 9000)
        let items = DevFolderScanner(env: s.env).scan()
        let avd = items.first { $0.title == "Pixel_8" }!
        #expect(avd.removal.names == ["Pixel_8.avd", "Pixel_8.ini"])
        #expect(!avd.selectedByDefault)
        #expect(items.contains { $0.title == "android-34 · google_apis · arm64-v8a" })
    }

    @Test func everyGroupHasTexts() {
        for g in DevItem.Group.allCases {
            #expect(!g.title.isEmpty && !g.symbol.isEmpty && !g.hint.isEmpty)
        }
        #expect(Set(DevFolderScanner.rules.map(\.path)).count == DevFolderScanner.rules.count, "no folder listed twice")
    }

    @Test func everyRuleTargetPassesTheSafetyGuardOnlyWhenInside() {
        // Whole-folder rules remove the folder itself, so none of them may point at a protected folder.
        let s = Sandbox()
        let g = SafetyGuard(env: s.env)
        for rule in DevFolderScanner.rules where rule.mode == .whole {
            #expect(g.check(s.env.resolve(rule.path)) == .allowed, "\(rule.path)")
        }
    }
}

@Suite struct SimulatorTests {
    let devices = Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {"udid": "11111111-2222-4333-8444-555555555555", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true,
         "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/11111111-2222-4333-8444-555555555555/data",
         "dataPathSize": 5000000, "lastUsedAt": "2026-11-01T10:00:00Z"},
        {"udid": "22222222-3333-4444-8555-666666666666", "name": "iPhone 15 Pro", "state": "Booted", "isAvailable": true,
         "dataPathSize": 9000000}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
        {"udid": "33333333-4444-4555-8666-777777777777", "name": "iPhone 14", "state": "Shutdown", "isAvailable": false,
         "dataPathSize": 7000000, "availabilityError": "runtime profile not found"},
        {"udid": "not-a-uuid; rm -rf /", "name": "Evil", "state": "Shutdown", "isAvailable": true, "dataPathSize": 1}
      ]
    }}
    """.utf8)

    let runtimes = Data("""
    {"44444444-5555-4666-8777-888888888888": {"identifier": "44444444-5555-4666-8777-888888888888", "version": "17.5",
       "build": "21F79", "sizeBytes": 7336630623, "deletable": true, "lastUsedAt": "2026-11-01T20:26:57Z",
       "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5"},
     "55555555-6666-4777-8888-999999999999": {"identifier": "55555555-6666-4777-8888-999999999999", "version": "16.0",
       "build": "20A360", "sizeBytes": 6000000000, "deletable": true,
       "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-0"},
     "66666666-7777-4888-8999-AAAAAAAAAAAA": {"identifier": "66666666-7777-4888-8999-AAAAAAAAAAAA", "version": "27.0",
       "build": "24A1", "sizeBytes": 8000000000, "deletable": false,
       "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}}
    """.utf8)

    @Test func parsesDevicesKeepingBootedAndDroppingBadIDs() {
        let all = SimulatorScanner.parseDevices(devices)
        #expect(all.map(\.title) == ["iPhone 15 Pro", "iPhone 14", "iPhone 15"], "sorted by size; non-UUID entries dropped")
        let booted = all[0]
        #expect(booted.safety == .kept && !booted.isRemovable && !booted.selectedByDefault, "a running simulator is shown, never removed")
        #expect(booted.detail.contains("running now"))
        let items = all.filter(\.isRemovable)
        let unavailable = items[0], normal = items[1]
        #expect(unavailable.safety == .safe, "it cannot start, so nothing in it can be used")
        #expect(normal.safety == .review, "a simulator holds the apps and data installed in it")
        #expect(unavailable.selectedByDefault, "a simulator without its runtime cannot start")
        #expect(unavailable.detail.contains("iOS 16.0") && unavailable.detail.contains("unavailable"))
        #expect(!normal.selectedByDefault)
        #expect(normal.size == 5_000_000)
        #expect(normal.lastUsed != nil)
        #expect(normal.removal == .command(["/usr/bin/xcrun", "simctl", "delete", "11111111-2222-4333-8444-555555555555"]))
        #expect(normal.location?.lastPathComponent == "11111111-2222-4333-8444-555555555555")
    }

    @Test func parsesRuntimesOnlyDeletableNeverPreselected() {
        let usage = SimulatorScanner.devicesPerRuntime(devices)
        let items = SimulatorScanner.parseRuntimes(runtimes, devicesPerRuntime: usage)
        #expect(items.map(\.title) == ["iOS 17.5", "iOS 16.0"])
        #expect(items.allSatisfy { !$0.selectedByDefault })
        #expect(items[0].detail.contains("simulators on it: 2"))
        #expect(items[1].detail.contains("never used"))
        #expect(items[0].size == 7_336_630_623)
        #expect(items[0].removal == .command(["/usr/bin/xcrun", "simctl", "runtime", "delete", "44444444-5555-4666-8777-888888888888"]))
    }

    @Test func runtimeNames() {
        #expect(SimulatorScanner.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-17-5") == "iOS 17.5")
        #expect(SimulatorScanner.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-10-0") == "watchOS 10.0")
        #expect(SimulatorScanner.runtimeName("weird") == "weird")
    }

    @Test func garbageAndFailuresGiveNothing() {
        #expect(SimulatorScanner.parseDevices(Data("nope".utf8)).isEmpty)
        #expect(SimulatorScanner.parseRuntimes(Data("[]".utf8)).isEmpty)
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 1, error: "xcrun: error: unable to find utility simctl")
        #expect(SimulatorScanner(env: Sandbox().env, runner: runner).scan().isEmpty)
    }

    @Test func scanAsksSimctl() {
        let runner = FakeRunner()
        runner.responses["/usr/bin/xcrun simctl list devices -j"] = CommandResult(status: 0, output: String(decoding: devices, as: UTF8.self))
        runner.responses["/usr/bin/xcrun simctl runtime list -j"] = CommandResult(status: 0, output: String(decoding: runtimes, as: UTF8.self))
        let items = SimulatorScanner(env: Sandbox().env, runner: runner).scan()
        #expect(items.filter { $0.group == .simulators && $0.isRemovable }.count == 2)
        #expect(items.filter { $0.group == .simulators && !$0.isRemovable }.count == 1, "the running one is kept")
        #expect(items.filter { $0.group == .runtimes }.count == 2)
    }
}

@Suite struct BuildArtifactTests {
    @Test func findsArtifactsOnlyNextToTheirProjectFile() {
        let s = Sandbox()
        s.file("~/code/web/package.json")
        s.file("~/code/web/node_modules/react/index.js", bytes: 9000)
        s.file("~/code/web/node_modules/react/node_modules/x/i.js", bytes: 9000)   // nested: not listed twice
        s.file("~/code/web/.next/cache/x", bytes: 9000)
        s.file("~/code/swift/Package.swift")
        s.file("~/code/swift/.build/debug/x.o", bytes: 9000)
        s.file("~/code/rust/Cargo.toml")
        s.file("~/code/rust/target/debug/app", bytes: 9000)
        s.file("~/code/android/app/build.gradle")
        s.file("~/code/android/app/build/outputs/app.apk", bytes: 9000)
        s.file("~/code/ios/Podfile")
        s.file("~/code/ios/Pods/AFNetworking/a.m", bytes: 9000)
        // Look-alikes that are NOT build output:
        s.file("~/Documents/build/thesis-final.docx", bytes: 9000)        // a folder that just happens to be called build
        s.file("~/Documents/target/plan.txt", bytes: 9000)
        s.file("~/stray/node_modules/pkg/i.js", bytes: 9000)              // no package.json next to it
        let found = Set(BuildArtifactFinder(env: s.env).find().map(\.title))
        #expect(found == ["web/node_modules", "web/.next", "swift/.build", "rust/target", "app/build", "ios/Pods"])
    }

    @Test func nothingPreselectedAndRemovalIsTheFolder() {
        let s = Sandbox()
        s.file("~/code/web/package.json")
        s.file("~/code/web/node_modules/a/i.js", bytes: 9000)
        let item = BuildArtifactFinder(env: s.env).find()[0]
        #expect(!item.selectedByDefault)
        #expect(item.group == .builds)
        #expect(item.removal.names == ["node_modules"])
        #expect(item.detail.contains("~/code/web"))
    }

    @Test func reportsProjectInactivity() {
        let now = Date()
        let s = Sandbox(now: now)
        let old = now.addingTimeInterval(-90 * day)
        s.file("~/code/old/package.json", modified: old)
        s.file("~/code/old/node_modules/a/i.js", bytes: 9000)
        s.file("~/code/fresh/package.json", modified: now)
        s.file("~/code/fresh/node_modules/a/i.js", bytes: 9000)
        let items = BuildArtifactFinder(env: s.env).find()
        let oldItem = items.first { $0.title == "old/node_modules" }!
        let fresh = items.first { $0.title == "fresh/node_modules" }!
        #expect(now.timeIntervalSince(oldItem.lastUsed!) > 80 * day)
        #expect(now.timeIntervalSince(fresh.lastUsed!) < day)
        #expect(oldItem.detail.contains("unchanged for"))
    }

    @Test func skipsLibraryHiddenFoldersPackagesAndSymlinks() throws {
        let s = Sandbox()
        s.file("~/Library/stuff/package.json"); s.file("~/Library/stuff/node_modules/a/i.js", bytes: 9000)
        s.file("~/.hidden/proj/package.json"); s.file("~/.hidden/proj/node_modules/a/i.js", bytes: 9000)
        s.file("~/Apps/Tool.app/Contents/package.json"); s.file("~/Apps/Tool.app/Contents/node_modules/a/i.js", bytes: 9000)
        s.file("~/real/package.json"); s.file("~/real/node_modules/a/i.js", bytes: 9000)
        s.dir("~/links")
        try FileManager.default.createSymbolicLink(at: s.env.resolve("~/links/real"), withDestinationURL: s.env.resolve("~/real"))
        #expect(BuildArtifactFinder(env: s.env).find().map(\.title) == ["real/node_modules"])
    }

    @Test func respectsDepthLimitChosenRootsAndCancel() {
        let s = Sandbox()
        s.file("~/a/b/c/d/package.json"); s.file("~/a/b/c/d/node_modules/x/i.js", bytes: 9000)
        s.file("~/other/package.json"); s.file("~/other/node_modules/x/i.js", bytes: 9000)
        var finder = BuildArtifactFinder(env: s.env)
        #expect(finder.find().count == 2)
        #expect(finder.find(roots: [s.env.resolve("~/other")]).map(\.title) == ["other/node_modules"])
        #expect(finder.find(cancelled: { true }).isEmpty)
        finder.maxDepth = 2
        #expect(finder.find().map(\.title) == ["other/node_modules"])
    }

    @Test func markerMatching() {
        let build = BuildArtifactFinder.kinds.first { $0.folder == "build" }!
        #expect(BuildArtifactFinder.matches(build, siblings: ["App.xcodeproj", "build"]))
        #expect(BuildArtifactFinder.matches(build, siblings: ["build.gradle.kts"]))
        #expect(!BuildArtifactFinder.matches(build, siblings: ["package.json", "README.md"]), "a JS `build` may be the shipped site")
        #expect(Set(BuildArtifactFinder.kinds.map(\.folder)).count == BuildArtifactFinder.kinds.count)
    }
}

@Suite struct DevCleanerTests {
    @Test func removesFilesThroughTheGuardAndRunsSimctl() {
        let s = Sandbox()
        s.file("~/code/web/package.json")
        s.file("~/code/web/node_modules/a/i.js", bytes: 9000)
        s.file("~/.android/avd/P.avd/x.img", bytes: 9000)
        s.file("~/.android/avd/P.ini", bytes: 50)
        let builds = BuildArtifactFinder(env: s.env).find()
        let avd = DevFolderScanner(env: s.env).scan()
        let sim = DevItem(id: "sim", group: .simulators, title: "iPhone 15", detail: "", size: 5000,
                          removal: .command(["/usr/bin/xcrun", "simctl", "delete", "11111111-2222-4333-8444-555555555555"]))
        let runner = FakeRunner()
        let remover = RecordingRemover()
        let cleaner = DevCleaner(env: s.env, runner: runner, cleaner: Cleaner(env: s.env, remover: remover))
        let r = cleaner.remove(builds + avd + [sim])
        #expect(r.failed.isEmpty)
        #expect(r.removed.count == 4, "node_modules, avd folder, avd ini, simulator")
        #expect(!s.exists("~/code/web/node_modules"))
        #expect(s.exists("~/code/web/package.json"))
        #expect(!s.exists("~/.android/avd/P.ini"))
        #expect(runner.calls == [["/usr/bin/xcrun", "simctl", "delete", "11111111-2222-4333-8444-555555555555"]])
        #expect(r.freedBytes == builds[0].size + avd[0].size + 5000)
    }

    @Test(arguments: [
        ["/bin/rm", "-rf", "/"],
        ["/usr/bin/xcrun", "simctl", "delete", "all"],
        ["/usr/bin/xcrun", "simctl", "erase", "11111111-2222-4333-8444-555555555555"],
        ["/usr/bin/xcrun", "rm", "delete", "11111111-2222-4333-8444-555555555555"],
        ["/usr/bin/xcrun", "simctl", "delete"],
        [],
    ])
    func refusesAnyOtherCommand(_ argv: [String]) {
        #expect(!DevCleaner.isAllowed(argv))
        let s = Sandbox()
        let runner = FakeRunner()
        let item = DevItem(id: "x", group: .simulators, title: "X", detail: "", size: 1, removal: .command(argv))
        let r = DevCleaner(env: s.env, runner: runner).remove([item])
        #expect(r.removed.isEmpty && r.failed.count == 1)
        #expect(runner.calls.isEmpty)
    }

    @Test func allowsBothSimctlDeletes() {
        let id = "11111111-2222-4333-8444-555555555555"
        #expect(DevCleaner.isAllowed(["/usr/bin/xcrun", "simctl", "delete", id]))
        #expect(DevCleaner.isAllowed(["/usr/bin/xcrun", "simctl", "runtime", "delete", id]))
    }

    @Test func failedCommandIsReportedNotCounted() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 1, error: "Unable to delete: device is booted\n")
        let item = DevItem(id: "x", group: .simulators, title: "iPhone", detail: "", size: 500,
                           removal: .command(["/usr/bin/xcrun", "simctl", "delete", "11111111-2222-4333-8444-555555555555"]))
        let r = DevCleaner(env: Sandbox().env, runner: runner).remove([item])
        #expect(r.freedBytes == 0)
        #expect(r.failed.first?.reason == "Unable to delete: device is booted")
    }

    @Test func buildFolderOutsideHomeIsRefused() {
        let s = Sandbox()
        let item = DevItem(id: "x", group: .builds, title: "x/node_modules", detail: "", size: 1,
                           removal: .files([URL(fileURLWithPath: "/Volumes/Ext/proj/node_modules")]))
        let r = DevCleaner(env: s.env, runner: FakeRunner(), cleaner: Cleaner(env: s.env, remover: RecordingRemover())).remove([item])
        #expect(r.removed.isEmpty && r.failed.count == 1)
    }
}

@Suite struct DockerTests {
    let df = """
    {"Active":"2","Reclaimable":"1.5GB (46%)","Size":"3.2GB","TotalCount":"5","Type":"Images"}
    {"Active":"1","Reclaimable":"12.3kB (10%)","Size":"120kB","TotalCount":"3","Type":"Containers"}
    {"Active":"1","Reclaimable":"0B (0%)","Size":"250MB","TotalCount":"2","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"4.25GB","Size":"4.25GB","TotalCount":"80","Type":"Build Cache"}
    """

    @Test(arguments: [("0B", Int64(0)), ("12.3kB", 12_300), ("250MB", 250_000_000), ("1.5GB (46%)", 1_500_000_000),
                      ("2TB", 2_000_000_000_000), ("", 0), ("garbage", 0)])
    func parsesSizes(_ c: (String, Int64)) {
        #expect(DockerCleaner.parseSize(c.0) == c.1)
    }

    @Test func parsesUsage() {
        let u = DockerCleaner.parseUsage(df)
        #expect(u.map(\.type) == ["Images", "Containers", "Local Volumes", "Build Cache"])
        #expect(u[0] == DockerUsage(type: "Images", total: 5, active: 2, size: 3_200_000_000, reclaimable: 1_500_000_000))
        #expect(u[3].reclaimable == 4_250_000_000)
        #expect(DockerCleaner.parseUsage("not json\n").isEmpty)
    }

    @Test func statesInstalledRunningOrNot() {
        let runner = FakeRunner()
        #expect(DockerCleaner(runner: runner, binary: nil).state() == .notInstalled)
        runner.defaultResult = CommandResult(status: 1, error: "failed to connect to the docker API")
        #expect(DockerCleaner(runner: runner, binary: "/usr/local/bin/docker").state() == .notRunning)
        runner.defaultResult = CommandResult(status: 0, output: df)
        guard case .ready(let u) = DockerCleaner(runner: runner, binary: "/usr/local/bin/docker").state() else {
            Issue.record("expected ready"); return
        }
        #expect(u.count == 4)
        #expect(runner.calls.last == ["/usr/local/bin/docker", "system", "df", "--format", "{{json .}}"])
    }

    @Test func pruneRunsOnlyTheChosenCommands() {
        let runner = FakeRunner()
        runner.responses["/usr/local/bin/docker builder prune"] = CommandResult(status: 0, output: "ID\tRECLAIMABLE\nTotal:\t4.25GB\n")
        runner.responses["/usr/local/bin/docker image prune"] = CommandResult(status: 0, output: "Deleted Images:\nTotal reclaimed space: 1.5GB\n")
        let d = DockerCleaner(runner: runner, binary: "/usr/local/bin/docker")
        let (results, reclaimed) = d.prune([.buildCache, .danglingImages])
        #expect(runner.calls == [["/usr/local/bin/docker", "builder", "prune", "-f"],
                                 ["/usr/local/bin/docker", "image", "prune", "-f"]])
        #expect(results.count == 2)
        #expect(reclaimed == 5_750_000_000)
        #expect(!runner.calls.contains { $0.contains("volume") })
    }

    @Test func dataLosingPrunesAreNeverPreselected() {
        #expect(DockerPrune.allCases.filter(\.selectedByDefault) == [.buildCache, .danglingImages])
        #expect(DockerPrune.volumes.dangerous && DockerPrune.containers.dangerous)
        #expect(!DockerPrune.volumes.selectedByDefault && !DockerPrune.unusedImages.selectedByDefault)
        // `volume prune` without -a only touches anonymous volumes; never widen it silently.
        #expect(DockerPrune.volumes.arguments == ["volume", "prune", "-f"])
        for p in DockerPrune.allCases { #expect(!p.title.isEmpty && !p.details.isEmpty) }
    }

    @Test func parsesReclaimed() {
        #expect(DockerCleaner.parseReclaimed("Total reclaimed space: 0B") == 0)
        #expect(DockerCleaner.parseReclaimed("a\nTotal reclaimed space: 120MB\n") == 120_000_000)
        #expect(DockerCleaner.parseReclaimed("nothing here") == 0)
    }
}

extension DevItem.Removal {
    /// File names of a `.files` removal.
    var names: [String] {
        if case .files(let urls) = self { return urls.map(\.lastPathComponent) }
        return []
    }
}
