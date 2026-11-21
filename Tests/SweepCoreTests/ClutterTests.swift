import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SweepCore

@Suite struct FileKindTests {
    @Test(arguments: [("a.MOV", FileKind.video), ("b.mp3", .audio), ("c.HEIC", .image), ("d.zip", .archive),
                      ("e.dmg", .diskImage), ("f.pdf", .document), ("g.swift", .code), ("h.xyz", .other)])
    func classifies(_ c: (String, FileKind)) {
        #expect(FileKind.of(URL(fileURLWithPath: "/x/" + c.0)) == c.1)
        #expect(!c.1.title.isEmpty)
    }
}

@Suite struct LargeOldTests {
    @Test func findsLargeFilesSkippingLibraryAndHidden() {
        let s = Sandbox()
        s.file("~/Movies/big.mov", bytes: 300_000)
        s.file("~/Documents/small.txt", bytes: 100)
        s.file("~/Library/Caches/huge.bin", bytes: 400_000)
        s.file("~/.hidden/huge.bin", bytes: 400_000)
        let found = LargeOldFinder(env: s.env).find(minSize: 200_000)
        #expect(found.map { $0.url.lastPathComponent } == ["big.mov"])
        #expect(found[0].kind == .video)
    }

    @Test func oldFilterUsesLastUseDate() {
        let now = Date()
        let s = Sandbox(now: now)
        let old = s.file("~/Documents/old.pdf", bytes: 1000)
        s.file("~/Documents/fresh.pdf", bytes: 1000)
        let past = now.addingTimeInterval(-400 * day)
        try! FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        // Access time can't be set via FileManager; use utimes.
        var times = [timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0)]
        utimes(old.path, &times)
        let found = LargeOldFinder(env: s.env).find(minSize: 0, olderThanDays: 365)
        #expect(found.map { $0.url.lastPathComponent } == ["old.pdf"])
    }

    @Test func appBundlesCountAsOneItem() {
        let s = Sandbox()
        s.app("~/Apps/Big.app", id: "com.x.big", name: "Big")
        s.file("~/Apps/Big.app/Contents/Resources/blob", bytes: 300_000)
        let found = LargeOldFinder(env: s.env).find(minSize: 200_000)
        #expect(found.map { $0.url.lastPathComponent } == ["Big.app"])
    }

    @Test func cancellationStopsEarly() {
        let s = Sandbox()
        for i in 0..<20 { s.file("~/Docs/f\(i)", bytes: 10) }
        let found = FileWalker().files(under: s.home, cancelled: { true })
        #expect(found.isEmpty)
    }
}

@Suite struct DuplicateTests {
    func entries(_ s: Sandbox) -> [FileEntry] { FileWalker().files(under: s.home) }

    @Test func groupsIdenticalFiles() {
        let s = Sandbox()
        let content = Data((0..<100_000).map { UInt8($0 % 251) })
        s.file("~/a/photo.jpg", data: content)
        s.file("~/b/photo copy.jpg", data: content)
        s.file("~/c/photo (1).jpg", data: content)
        var other = content; other[99_999] = 7    // same size, differs at the end
        s.file("~/d/other.jpg", data: other)
        s.file("~/e/unique.txt", bytes: 50)
        let groups = DuplicateFinder.find(in: entries(s))
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 3)
        #expect(groups[0].wasted == groups[0].fileSize * 2)
        #expect(groups[0].hash.count == 64)
    }

    @Test func suggestsKeepingOldestCopy() {
        let now = Date()
        let s = Sandbox(now: now)
        let content = Data(repeating: 9, count: 5000)
        s.file("~/new/x.bin", data: content, modified: now)
        s.file("~/orig/x.bin", data: content, modified: now.addingTimeInterval(-100 * day))
        let g = DuplicateFinder.find(in: entries(s))[0]
        #expect(g.suggestedRemovals.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["new"])
    }

    @Test func respectsMinSizeAndEmptyInput() {
        let s = Sandbox()
        s.file("~/a/x", bytes: 10)
        s.file("~/b/x", bytes: 10)
        #expect(DuplicateFinder.find(in: entries(s), minSize: 1000).isEmpty)
        #expect(DuplicateFinder.find(in: []).isEmpty)
    }

    @Test func largeFilesHashedBeyondFirstChunk() {
        let s = Sandbox()
        let a = Data(repeating: 1, count: 3_000_000)
        var b = a; b[2_999_999] = 2
        s.file("~/a/big", data: a)
        s.file("~/b/big", data: b)
        s.file("~/c/big", data: a)
        let groups = DuplicateFinder.find(in: entries(s))
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
    }
}

@Suite struct SimilarImageTests {
    /// Writes a PNG with a horizontal gradient (optionally reversed) at the given size.
    func png(_ s: Sandbox, _ path: String, width: Int, height: Int, reversed: Bool = false, noise: Int = 0) -> URL {
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let v = reversed ? 255 - x * 255 / width : x * 255 / width
            px[y * width + x] = UInt8(clamping: v + ((x * 7 + y * 13) % (noise + 1)))
        } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let image = ctx.makeImage()!
        let url = s.env.resolve(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test func resizedCopiesAreSimilarDifferentImagesAreNot() {
        let s = Sandbox()
        let a = png(s, "~/p/a.png", width: 400, height: 300)
        let b = png(s, "~/p/b.png", width: 200, height: 150, noise: 3)
        let c = png(s, "~/p/c.png", width: 400, height: 300, reversed: true)
        let ha = SimilarImages.dHash(a)!, hb = SimilarImages.dHash(b)!, hc = SimilarImages.dHash(c)!
        #expect(SimilarImages.distance(ha, hb) <= 6)
        #expect(SimilarImages.distance(ha, hc) > 20)

        let groups = SimilarImages.groups(FileWalker().files(under: s.env.resolve("~/p")))
        #expect(groups.count == 1)
        #expect(Set(groups[0].map { $0.url.lastPathComponent }) == ["a.png", "b.png"])
    }

    @Test func nonImagesAreIgnored() {
        let s = Sandbox()
        s.file("~/p/x.jpg", bytes: 100)  // not a real JPEG
        #expect(SimilarImages.dHash(s.env.resolve("~/p/x.jpg")) == nil)
        #expect(SimilarImages.groups(FileWalker().files(under: s.home)).isEmpty)
    }

    @Test func distanceCountsBits() {
        #expect(SimilarImages.distance(0, 0) == 0)
        #expect(SimilarImages.distance(0b1011, 0) == 3)
        #expect(SimilarImages.distance(.max, 0) == 64)
    }
}

@Suite struct SpaceMapTests {
    @Test func buildsSortedTreeWithSums() {
        let s = Sandbox()
        s.file("~/big/a", bytes: 200_000)
        s.file("~/big/deep/b", bytes: 100_000)
        s.file("~/small/c", bytes: 5_000)
        let root = SpaceMap.build(s.home, depth: 2)
        #expect(root.children.map(\.name) == ["big", "small"])
        #expect(root.size == root.children.reduce(0) { $0 + $1.size })
        let big = root.children[0]
        #expect(big.children.count == 2, "depth 2 expands one more level")
        #expect(big.children.first { $0.name == "deep" }!.children.isEmpty, "depth limit reached")
        #expect(big.fraction(of: root) > 0.9)
    }

    @Test func topGroupsTheRest() {
        let s = Sandbox()
        for i in 1...5 { s.file("~/d\(i)/f", bytes: i * 10_000) }
        let root = SpaceMap.build(s.home, depth: 1)
        let (shown, other) = SpaceMap.top(root, limit: 2)
        #expect(shown.map(\.name) == ["d5", "d4"])
        #expect(other == root.size - shown.reduce(0) { $0 + $1.size })
    }

    @Test func fileNodeIsLeaf() {
        let s = Sandbox()
        let f = s.file("~/x.bin", bytes: 5000)
        let n = SpaceMap.build(f)
        #expect(!n.isDirectory)
        #expect(n.size > 0)
        #expect(n.children.isEmpty)
    }
}

@Suite struct CloudTests {
    @Test func listsLocalCopiesInSyncFolders() {
        let s = Sandbox()
        s.file("~/Library/Mobile Documents/com~apple~CloudDocs/Video/trip.mov", bytes: 300_000)
        s.file("~/Library/Mobile Documents/com~apple~CloudDocs/evicted.mov", bytes: 300_000)
        s.file("~/Library/CloudStorage/GoogleDrive-me/big.zip", bytes: 300_000)
        s.file("~/Library/CloudStorage/OneDrive-Personal/small.txt", bytes: 10)
        let scanner = CloudScanner(env: s.env, isLocal: { !$0.lastPathComponent.hasPrefix("evicted") })
        let found = scanner.scan(minSize: 100_000)
        #expect(Set(found.map { $0.entry.url.lastPathComponent }) == ["trip.mov", "big.zip"])
        #expect(found.first { $0.entry.url.lastPathComponent == "big.zip" }?.provider == .googleDrive)
    }

    @Test func providersWithoutFoldersYieldNothing() {
        let s = Sandbox()
        #expect(CloudProvider.dropbox.roots(env: s.env).isEmpty)
        #expect(CloudScanner(env: s.env).scan().isEmpty)
    }
}
