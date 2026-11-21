import Foundation
import ImageIO
import CoreGraphics

/// Finds visually similar photos with a difference hash (dHash): the image is shrunk to 9×8 grey pixels and
/// each bit says whether a pixel is brighter than its right neighbour. Close hashes mean similar pictures.
public enum SimilarImages {
    public static func dHash(_ url: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 256,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return dHash(image)
    }

    public static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Groups images whose hashes differ by at most `threshold` bits (of 64).
    public static func groups(_ files: [FileEntry], threshold: Int = 6) -> [[FileEntry]] {
        let hashed: [(FileEntry, UInt64)] = files.filter { $0.kind == .image }.compactMap { f in
            dHash(f.url).map { (f, $0) }
        }
        return cluster(hashed, threshold: threshold)
    }

    static func cluster(_ hashed: [(FileEntry, UInt64)], threshold: Int) -> [[FileEntry]] {
        var parent = Array(hashed.indices)
        func find(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = find(parent[i]); return parent[i] }() }
        for i in hashed.indices {
            for j in hashed.indices where j > i && distance(hashed[i].1, hashed[j].1) <= threshold {
                parent[find(j)] = find(i)
            }
        }
        let grouped = Dictionary(grouping: hashed.indices) { find($0) }
        return grouped.values.filter { $0.count > 1 }
            .map { $0.map { hashed[$0].0 }.sorted { $0.size > $1.size } }
            .sorted { $0.count > $1.count }
    }
}
