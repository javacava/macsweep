import Foundation
import AVFoundation
import CoreGraphics

/// Finds near-identical videos: re-exports, trimmed copies, several takes of an AI-generated clip.
/// Each video gets a fingerprint of its length and three frames (at a quarter, half and three quarters),
/// each frame hashed like a photo. Two videos are similar when their lengths are close and every frame matches.
public enum SimilarVideos {
    public struct Fingerprint: Equatable, Sendable {
        public let duration: Double
        public let frames: [UInt64]
        public init(duration: Double, frames: [UInt64]) { self.duration = duration; self.frames = frames }
    }

    static let positions: [Double] = [0.25, 0.5, 0.75]

    public static func fingerprint(_ url: URL) -> Fingerprint? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        // Exact frames: with a loose tolerance two copies cut at different keyframes give different pictures.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let duration = load({ try await asset.load(.duration) })?.seconds, duration.isFinite, duration > 0 else { return nil }
        var frames: [UInt64] = []
        for p in positions {
            let time = CMTime(seconds: duration * p, preferredTimescale: 600)
            guard let image = load({ try await generator.image(at: time).image }), let hash = SimilarImages.dHash(image) else { return nil }
            frames.append(hash)
        }
        return Fingerprint(duration: duration, frames: frames)
    }

    /// A frame from the middle of the video, for thumbnails.
    public static func poster(_ url: URL, maxSize: CGFloat = 300) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let seconds = load({ try await asset.load(.duration) })?.seconds ?? 0
        let time = CMTime(seconds: seconds.isFinite ? seconds / 2 : 0, preferredTimescale: 600)
        return load { try await generator.image(at: time).image }
    }

    /// Runs an async AVFoundation call from synchronous scanning code (always called off the main thread).
    static func load<T>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await work()
            done.signal()
        }
        // A broken file must not hang the scan.
        guard done.wait(timeout: .now() + 20) == .success else { return nil }
        return box.value
    }

    final class ResultBox<T>: @unchecked Sendable { var value: T? }

    /// Lengths within 2% (at least one second), and every frame within `threshold` bits.
    public static func similar(_ a: Fingerprint, _ b: Fingerprint, threshold: Int = 8) -> Bool {
        guard a.frames.count == b.frames.count, !a.frames.isEmpty else { return false }
        let slack = max(1, 0.02 * max(a.duration, b.duration))
        guard abs(a.duration - b.duration) <= slack else { return false }
        return zip(a.frames, b.frames).allSatisfy { SimilarImages.distance($0, $1) <= threshold }
    }

    /// Groups similar videos; each group is sorted biggest first.
    public static func groups(_ files: [FileEntry], threshold: Int = 8) -> [[FileEntry]] {
        let printed: [(FileEntry, Fingerprint)] = files.filter { $0.kind == .video }.compactMap { f in
            fingerprint(f.url).map { (f, $0) }
        }
        return cluster(printed, threshold: threshold)
    }

    static func cluster(_ printed: [(FileEntry, Fingerprint)], threshold: Int) -> [[FileEntry]] {
        var parent = Array(printed.indices)
        func find(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = find(parent[i]); return parent[i] }() }
        for i in printed.indices {
            for j in printed.indices where j > i && similar(printed[i].1, printed[j].1, threshold: threshold) {
                parent[find(j)] = find(i)
            }
        }
        return Dictionary(grouping: printed.indices) { find($0) }.values.filter { $0.count > 1 }
            .map { $0.map { printed[$0].0 }.sorted { $0.size > $1.size } }
            .sorted { $0.count > $1.count }
    }
}
