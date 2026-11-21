import Foundation
import Testing
@testable import SweepCore

@Suite struct EnvironmentTests {
    @Test func resolvesHomeAndRootPaths() {
        let s = Sandbox()
        #expect(s.env.resolve("~/Library/Caches").path == s.home.path + "/Library/Caches")
        #expect(s.env.resolve("/Library/Caches").path == s.root.path + "/Library/Caches")
        #expect(s.env.resolve("~") == s.home)
        #expect(s.env.resolve("/") == s.root)
    }

    @Test func displayPathShortensHome() {
        let s = Sandbox()
        #expect(s.env.displayPath(s.env.resolve("~/Downloads/a.dmg")) == "~/Downloads/a.dmg")
        #expect(s.env.displayPath(s.home) == "~")
        #expect(s.env.displayPath(s.env.resolve("/Library/Logs")) == "/Library/Logs")
    }
}

@Suite struct FileSizeTests {
    @Test func sumsFolderRecursively() {
        let s = Sandbox()
        s.file("~/a/one", bytes: 5000)
        s.file("~/a/b/two", bytes: 7000)
        let size = FileSize.of(s.env.resolve("~/a"))
        #expect(size >= 12_000)
        #expect(size < 12_000 + 4 * 16_384)
    }

    @Test func doesNotFollowSymlinks() throws {
        let s = Sandbox()
        s.file("~/big/blob", bytes: 500_000)
        s.dir("~/links")
        try FileManager.default.createSymbolicLink(at: s.env.resolve("~/links/l"), withDestinationURL: s.env.resolve("~/big"))
        #expect(FileSize.of(s.env.resolve("~/links")) == 0)
    }

    @Test func missingPathIsZero() {
        #expect(FileSize.of(URL(fileURLWithPath: "/nonexistent-\(UUID())")) == 0)
    }

    @Test func formatsBytes() {
        #expect(FileSize.format(5_000_000).contains("MB"))
        #expect(FileSize.format(2_000_000_000).contains("GB"))
    }

    @Test func isInsideRespectsPathBoundaries() {
        let a = URL(fileURLWithPath: "/Users/x/Library")
        #expect(URL(fileURLWithPath: "/Users/x/Library/Caches").isInside(a))
        #expect(a.isInside(a))
        #expect(!URL(fileURLWithPath: "/Users/x/LibraryOld").isInside(a))
    }
}

@Suite struct JunkScannerTests {
    @Test func findsCachesLogsAndTrash() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo.app/cache.db", bytes: 4000)
        s.file("~/Library/Logs/foo.log", bytes: 3000)
        s.file("~/.Trash/old.zip", bytes: 2000)
        s.file("/Library/Caches/com.bar/x", bytes: 1000)
        let r = JunkScanner(env: s.env).scan()
        #expect(Set(r.categories) == [.userCache, .userLogs, .trash, .systemCache])
        #expect(r.items.count == 4)
        #expect(r.totalSize == r.items.map(\.size).reduce(0, +))
        #expect(r.items.first!.size >= r.items.last!.size, "sorted by size")
    }

    @Test func excludedCachesAreLeftAlone() {
        let s = Sandbox()
        s.file("~/Library/Caches/CloudKit/db", bytes: 4000)
        s.file("~/Library/Caches/com.apple.bird/db", bytes: 4000)
        let r = JunkScanner(env: s.env).scan()
        #expect(r.items.isEmpty)
    }

    @Test func browserCacheIsOwnedByBrowserCategoryNotUserCache() {
        let s = Sandbox()
        s.file("~/Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 9000)
        s.file("~/Library/Caches/com.apple.Safari/WebKitCache", bytes: 9000)
        let r = JunkScanner(env: s.env).scan()
        #expect(r.items.allSatisfy { $0.category == .browserCache })
        #expect(r.items.count == 2)
    }

    @Test func devToolCachesGoToDevCategory() {
        let s = Sandbox()
        s.file("~/Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 9000)
        s.file("~/.npm/_cacache/content-v2/sha512/ab", bytes: 9000)
        s.file("~/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 9000)
        let r = JunkScanner(env: s.env).scan()
        #expect(r.items(in: .devTools).count == 2)
        #expect(r.items(in: .xcode).count == 1)
        #expect(r.items(in: .userCache).isEmpty)
    }

    @Test func minAgeFiltersFreshFiles() {
        let now = Date()
        let s = Sandbox(now: now)
        s.file("~/Downloads/old.dmg", bytes: 5000, modified: now.addingTimeInterval(-30 * day))
        s.file("~/Downloads/new.dmg", bytes: 5000, modified: now.addingTimeInterval(-1 * day))
        s.file("~/Downloads/photo.jpg", bytes: 5000, modified: now.addingTimeInterval(-30 * day))
        let r = JunkScanner(env: s.env).scan(categories: [.installers])
        #expect(r.items.map { $0.url.lastPathComponent } == ["old.dmg"])
        #expect(r.items.first?.selectedByDefault == false, "installers need an explicit choice")
        #expect(r.defaultSelection.isEmpty)
    }

    @Test func brokenDownloadsMatchedByExtension() {
        let now = Date()
        let s = Sandbox(now: now)
        s.file("~/Downloads/movie.mkv.crdownload", bytes: 5000, modified: now.addingTimeInterval(-2 * day))
        s.file("~/Downloads/report.pdf", bytes: 5000, modified: now.addingTimeInterval(-2 * day))
        let r = JunkScanner(env: s.env).scan(categories: [.brokenDownloads])
        #expect(r.items.map { $0.url.lastPathComponent } == ["movie.mkv.crdownload"])
    }

    @Test func compressedSystemLogsOnly() {
        let s = Sandbox()
        s.file("/private/var/log/system.log.0.gz", bytes: 3000)
        s.file("/private/var/log/system.log", bytes: 3000)
        let r = JunkScanner(env: s.env).scan(categories: [.systemLogs])
        #expect(r.items.map { $0.url.lastPathComponent } == ["system.log.0.gz"])
    }

    @Test func categoryFilterAndEmptyItemsSkipped() {
        let s = Sandbox()
        s.file("~/Library/Logs/a.log", bytes: 3000)
        s.dir("~/Library/Caches/empty-folder")
        s.file("~/Library/Caches/x/y", bytes: 3000)
        let r = JunkScanner(env: s.env).scan(categories: [.userCache])
        #expect(r.items.count == 1)
        #expect(r.items[0].category == .userCache)
    }

    @Test func reportsProgressPerRule() {
        let s = Sandbox()
        var seen: [String] = []
        _ = JunkScanner(env: s.env).scan(categories: [.trash]) { seen.append($0.id) }
        #expect(seen == ["trash"])
    }

    @Test func everyCategoryHasTitleSymbolAndRule() {
        for c in JunkCategory.allCases {
            #expect(!c.title.isEmpty)
            #expect(!c.symbol.isEmpty)
            #expect(JunkRules.all.contains { $0.category == c }, "\(c) has no rule")
        }
        #expect(Set(JunkRules.all.map(\.id)).count == JunkRules.all.count, "rule ids unique")
    }
}

@Suite struct SafetyGuardTests {
    let s = Sandbox()
    var g: SafetyGuard { SafetyGuard(env: s.env) }

    @Test func allowsJunkInsideHome() {
        #expect(g.check(s.env.resolve("~/Library/Caches/com.foo")) == .allowed)
        #expect(g.check(s.env.resolve("~/Downloads/a.dmg")) == .allowed)
        #expect(g.check(s.env.resolve("/Library/Caches/com.foo")) == .allowed)
    }

    @Test func deniesProtectedFoldersThemselves() {
        for p in ["~", "~/Library", "~/Library/Caches", "~/Documents", "~/Desktop", "~/.Trash",
                  "/", "/Library", "/Applications", "/System", "/Users"] {
            #expect(g.check(s.env.resolve(p)) != .allowed, "\(p) must be protected")
        }
    }

    @Test func deniesSystemTreesAndKeychains() {
        #expect(g.check(s.env.resolve("/System/Library/foo")) != .allowed)
        #expect(g.check(s.env.resolve("/usr/lib/libz.dylib")) != .allowed)
        #expect(g.check(s.env.resolve("~/Library/Keychains/login.keychain-db")) != .allowed)
        #expect(g.check(s.env.resolve("/private/var/db/receipts/x.bom")) != .allowed)
    }

    @Test func deniesOutsideAllowedTreesAndTraversal() {
        #expect(g.check(URL(fileURLWithPath: "/etc/hosts")) != .allowed)
        #expect(g.check(URL(fileURLWithPath: s.home.path + "/../../etc")) != .allowed)
        #expect(g.check(URL(string: "relative/path")!) != .allowed)
    }

    @Test func deniesCoreAppleApps() {
        #expect(g.check(s.env.resolve("/Applications/Safari.app")) != .allowed)
        #expect(g.check(s.env.resolve("/Applications/Foo.app")) == .allowed)
    }

    @Test func symlinkedParentCannotEscape() throws {
        s.dir("~/Downloads")
        try FileManager.default.createSymbolicLink(at: s.env.resolve("~/Downloads/sys"),
                                                   withDestinationURL: s.env.resolve("/System"))
        s.dir("/System/Library")
        #expect(g.check(s.env.resolve("~/Downloads/sys/Library")) != .allowed)
        // The link itself may go: removing it does not touch the target.
        #expect(g.check(s.env.resolve("~/Downloads/sys")) == .allowed)
    }
}

@Suite struct CleanerTests {
    @Test func trashesByDefaultAndCountsFreedBytes() {
        let s = Sandbox()
        let a = s.file("~/Library/Caches/a/x", bytes: 100).deletingLastPathComponent()
        let remover = RecordingRemover()
        let r = Cleaner(env: s.env, remover: remover).remove([(a, 4096)])
        #expect(r.removed == [a])
        #expect(r.freedBytes == 4096)
        #expect(remover.trashed == [a])
        #expect(!s.exists("~/Library/Caches/a"))
    }

    @Test func permanentModeDeletes() {
        let s = Sandbox()
        let a = s.file("~/Library/Logs/x.log")
        let remover = RecordingRemover()
        _ = Cleaner(env: s.env, remover: remover, mode: .permanent).remove([(a, 1)])
        #expect(remover.deleted == [a])
        #expect(remover.trashed.isEmpty)
    }

    @Test func itemsAlreadyInTrashAreDeletedForGood() {
        let s = Sandbox()
        let a = s.file("~/.Trash/old.zip")
        let remover = RecordingRemover()
        _ = Cleaner(env: s.env, remover: remover).remove([(a, 1)])
        #expect(remover.deleted == [a])
    }

    @Test func refusesProtectedPathsAndKeepsThem() {
        let s = Sandbox()
        s.file("~/Documents/thesis.docx")
        let remover = RecordingRemover()
        let r = Cleaner(env: s.env, remover: remover).remove([(s.env.resolve("~/Documents"), 1)])
        #expect(r.removed.isEmpty)
        #expect(r.failed.count == 1)
        #expect(s.exists("~/Documents/thesis.docx"))
    }

    @Test func nestedTargetsRemovedOnce() {
        let s = Sandbox()
        s.file("~/Library/Caches/app/sub/f", bytes: 10)
        let remover = RecordingRemover()
        let r = Cleaner(env: s.env, remover: remover).remove([
            (s.env.resolve("~/Library/Caches/app/sub/f"), 10),
            (s.env.resolve("~/Library/Caches/app"), 100),
        ])
        #expect(r.removed.count == 1)
        #expect(r.freedBytes == 100)
        #expect(r.failed.isEmpty)
    }

    @Test func failuresAreReportedNotThrown() {
        let s = Sandbox()
        let a = s.file("~/Library/Caches/locked")
        let b = s.file("~/Library/Caches/fine")
        let remover = RecordingRemover()
        remover.failOn = ["locked"]
        let r = Cleaner(env: s.env, remover: remover).remove([(a, 1), (b, 2)])
        #expect(r.removed == [b])
        #expect(r.failed.map(\.url) == [a])
        #expect(r.freedBytes == 2)
    }

    @Test func scanThenCleanEndToEnd() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo/x", bytes: 9000)
        s.file("~/Library/Logs/y.log", bytes: 9000)
        let scan = JunkScanner(env: s.env).scan()
        let r = Cleaner(env: s.env, remover: RecordingRemover()).remove(scan.items)
        #expect(r.removed.count == 2)
        #expect(JunkScanner(env: s.env).scan().items.isEmpty)
        #expect(s.exists("~/Library/Caches"), "the cache folder itself stays")
    }
}
