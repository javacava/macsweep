import Foundation
import AVFoundation
import CoreGraphics
import Testing
@testable import SweepCore

/// Similar videos and the swap figure on the Mac Health page.

@Suite struct SimilarVideoTests {
    /// Writes a short H.264 movie whose frames are drawn by `draw` (frame index, context, size).
    static func makeVideo(_ url: URL, seconds: Int, fps: Int32 = 10, size: Int = 64,
                          draw: @escaping (Int, CGContext, Int) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                draw(i, ctx, size)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    /// Eight bands of brightness ramps; each band runs left or right, and the pattern changes every 1.5 s,
    /// so frames at different times differ while every hash bit stays clear-cut after compression.
    static func sweep(_ i: Int, _ ctx: CGContext, _ size: Int) {
        let segment = i / 15
        let band = size / 8
        for b in 0..<8 {
            let rightward = (b * 7 + segment * 3) % 5 < 2
            for x in 0..<size {
                let t = CGFloat(x) / CGFloat(size - 1)
                ctx.setFillColor(CGColor(gray: rightward ? t : 1 - t, alpha: 1))
                ctx.fill(CGRect(x: x, y: b * band, width: 1, height: band))
            }
        }
    }

    /// Checkerboard-ish stripes: looks nothing like the gradient.
    static func stripes(_ i: Int, _ ctx: CGContext, _ size: Int) {
        for x in stride(from: 0, to: size, by: 8) {
            ctx.setFillColor(CGColor(gray: (x / 8 + i / 20) % 2 == 0 ? 0.1 : 0.9, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: size))
        }
    }

    @Test func copiesOfAVideoAreGroupedAndADifferentOneIsNot() throws {
        let s = Sandbox()
        let dir = s.dir("~/Movies")
        try Self.makeVideo(dir.appendingPathComponent("take.mp4"), seconds: 6, draw: Self.sweep)
        try Self.makeVideo(dir.appendingPathComponent("take-export.mp4"), seconds: 6, size: 96, draw: Self.sweep)
        try Self.makeVideo(dir.appendingPathComponent("other.mp4"), seconds: 6, draw: Self.stripes)
        let files = FileWalker().files(under: dir, minSize: 0)
        #expect(files.count == 3)
        let groups = SimilarVideos.groups(files)
        #expect(groups.count == 1)
        #expect(Set(groups.first?.map(\.url.lastPathComponent) ?? []) == ["take.mp4", "take-export.mp4"])
        #expect(SimilarVideos.poster(dir.appendingPathComponent("take.mp4")) != nil)
    }

    @Test func lengthsMustBeClose() {
        let frames: [UInt64] = [1, 2, 3]
        #expect(SimilarVideos.similar(.init(duration: 60, frames: frames), .init(duration: 60.9, frames: frames)))
        #expect(!SimilarVideos.similar(.init(duration: 60, frames: frames), .init(duration: 70, frames: frames)))
        #expect(!SimilarVideos.similar(.init(duration: 10, frames: [0]), .init(duration: 10, frames: [UInt64.max])))
        #expect(!SimilarVideos.similar(.init(duration: 10, frames: []), .init(duration: 10, frames: [])))
    }

    @Test func aBrokenFileHasNoFingerprint() {
        let s = Sandbox()
        let bad = s.file("~/Movies/broken.mp4", data: Data("not a movie".utf8))
        #expect(SimilarVideos.fingerprint(bad) == nil)
    }
}

@Suite struct SwapTests {
    @Test func adviceDependsOnHowMuchIsSwapped() {
        let gb: UInt64 = 1 << 30
        #expect(SwapStats(total: 0, used: 0).advice(physicalMemory: 16 * gb).contains("No swap"))
        #expect(SwapStats(total: 2 * gb, used: gb / 2).advice(physicalMemory: 16 * gb).contains("normal"))
        #expect(SwapStats(total: 8 * gb, used: 6 * gb).advice(physicalMemory: 16 * gb).contains("Heavy"))
        #expect(SwapStats(total: 2 * gb, used: gb).usedFraction == 0.5)
        #expect(SwapStats(total: 0, used: gb).usedFraction == 0)
    }

    @Test func thisMacReportsSwap() throws {
        let swap = try #require(SystemMonitor.swap())
        #expect(swap.used <= swap.total || swap.total == 0)
    }

    @Test func appMemoryLeavesOutFileCache() {
        let m = MemoryStats(total: 100, free: 10, active: 40, inactive: 20, wired: 10, compressed: 5, purgeable: 5, external: 10)
        #expect(m.appMemory == 45)
    }
}
