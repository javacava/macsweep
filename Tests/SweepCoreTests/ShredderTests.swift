import Foundation
import Testing
@testable import SweepCore

@Suite struct ShredderTests {
    @Test func overwriteReplacesEveryByte() throws {
        let s = Sandbox()
        let original = Data(repeating: 0x41, count: 3_000_000)   // bigger than one 1 MB chunk
        let url = s.file("~/secret.txt", data: original)
        let shredder = Shredder(env: s.env, passes: 2)
        // Overwrite without truncating to look at what is on disk afterwards.
        try shredder.overwriteKeepingSize(url)
        let after = try Data(contentsOf: url)
        #expect(after.count == original.count)
        #expect(after != original)
        // Random data: the original byte should be rare, not the whole file.
        #expect(after.filter { $0 == 0x41 }.count < original.count / 100)
    }

    @Test func shredsFileAndLeavesNoTrace() {
        let s = Sandbox()
        s.file("~/Documents/passwords.txt", bytes: 5000)
        s.file("~/Documents/keep.txt", bytes: 10)
        let r = Shredder(env: s.env).shred([s.env.resolve("~/Documents/passwords.txt")])
        #expect(r.removed.count == 1)
        #expect(r.failed.isEmpty)
        #expect(r.freedBytes > 0)
        #expect(!s.exists("~/Documents/passwords.txt"))
        // Only the untouched file remains: no renamed leftover.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.env.resolve("~/Documents").path)) ?? []
        #expect(left == ["keep.txt"])
    }

    @Test func shredsFoldersRecursively() {
        let s = Sandbox()
        s.file("~/Private/a.txt", bytes: 100)
        s.file("~/Private/sub/b.bin", bytes: 2000)
        s.dir("~/Private/empty")
        var seen: [String] = []
        let r = Shredder(env: s.env).shred([s.env.resolve("~/Private")]) { seen.append($0.lastPathComponent) }
        #expect(r.removed.map(\.lastPathComponent) == ["Private"])
        #expect(!s.exists("~/Private"))
        #expect(Set(seen) == ["a.txt", "b.bin"])
    }

    @Test func symlinkIsRemovedButTargetSurvives() throws {
        let s = Sandbox()
        let target = s.file("~/Important/data.db", bytes: 4000)
        s.dir("~/Links")
        try FileManager.default.createSymbolicLink(at: s.env.resolve("~/Links/data"), withDestinationURL: target)
        let r = Shredder(env: s.env).shred([s.env.resolve("~/Links/data")])
        #expect(r.removed.count == 1)
        #expect(s.exists("~/Important/data.db"))
        #expect(try Data(contentsOf: target) == Data(repeating: 0x41, count: 4000))
    }

    @Test func hardLinkedFilesAreRefused() throws {
        let s = Sandbox()
        let a = s.file("~/x/a.txt", bytes: 100)
        try FileManager.default.linkItem(at: a, to: s.env.resolve("~/x/b.txt"))
        let r = Shredder(env: s.env).shred([a])
        #expect(r.removed.isEmpty)
        #expect(r.failed.first?.reason.contains("hard links") == true)
        #expect(try Data(contentsOf: s.env.resolve("~/x/b.txt")) == Data(repeating: 0x41, count: 100))
    }

    @Test func safetyGuardStillApplies() {
        let s = Sandbox()
        s.file("~/Documents/thesis.docx", bytes: 100)
        let r = Shredder(env: s.env).shred([s.env.resolve("~/Documents"), s.env.resolve("/System/x")])
        #expect(r.removed.isEmpty)
        #expect(r.failed.count == 2)
        #expect(s.exists("~/Documents/thesis.docx"))
    }

    @Test func emptyFileAndMissingFile() {
        let s = Sandbox()
        s.file("~/empty.txt", data: Data())
        let r = Shredder(env: s.env).shred([s.env.resolve("~/empty.txt"), s.env.resolve("~/nope.txt")])
        #expect(r.removed.map(\.lastPathComponent) == ["empty.txt"])
        #expect(r.failed.map { $0.url.lastPathComponent } == ["nope.txt"])
    }

    @Test func nestedTargetsShreddedOnce() {
        let s = Sandbox()
        s.file("~/P/a.txt", bytes: 100)
        let r = Shredder(env: s.env).shred([s.env.resolve("~/P/a.txt"), s.env.resolve("~/P")])
        #expect(r.removed.map(\.lastPathComponent) == ["P"])
        #expect(r.failed.isEmpty)
    }

    @Test func passesAreAtLeastOne() {
        #expect(Shredder(env: Sandbox().env, passes: 0).passes == 1)
        #expect(Shredder(env: Sandbox().env, passes: 7).passes == 7)
    }
}

extension Shredder {
    /// Test hook: overwrite, then restore the size so the result can be read back.
    func overwriteKeepingSize(_ url: URL) throws {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try overwrite(url, size: size, truncate: false)
    }
}
