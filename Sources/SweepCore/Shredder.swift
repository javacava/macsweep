import Foundation

/// Secure delete: overwrites file contents with random bytes, renames the file to a random name,
/// truncates it and unlinks it. Folders are shredded file by file.
///
/// On SSDs with APFS (copy-on-write, wear levelling) an overwrite may land on new blocks, so old data
/// can survive physically. FileVault encryption is what really protects deleted data there.
public struct Shredder: Sendable {
    public let safety: SafetyGuard
    /// How many times each file is overwritten (1 is enough for modern drives; 3/7 for the cautious).
    public var passes: Int

    public init(env: SweepEnvironment, passes: Int = 1) {
        self.safety = SafetyGuard(env: env)
        self.passes = max(1, passes)
    }

    public enum ShredError: LocalizedError {
        case hardLinked, notRegular, openFailed(Int32), writeFailed(Int32), otherVolume, unreadableFolder

        public var errorDescription: String? {
            switch self {
            case .hardLinked: "The file has other hard links"
            case .notRegular: "Not a regular file"
            case .otherVolume: "Another disk is mounted inside: its contents are left alone"
            case .unreadableFolder: "Could not read the folder"
            case .openFailed(let e): "Could not open: \(String(cString: strerror(e)))"
            case .writeFailed(let e): "Could not overwrite: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Shreds every target that passes the safety guard. `progress` gets each file as it goes.
    public func shred(_ targets: [URL], progress: ((URL) -> Void)? = nil) -> CleanReport {
        var report = CleanReport()
        let sorted = targets.sorted { $0.path.count < $1.path.count }
        var taken: [URL] = []
        for url in sorted {
            if taken.contains(where: { url.isInside($0) }) { continue }
            if case .denied(let why) = safety.check(url) {
                report.failed.append((url, why))
                continue
            }
            taken.append(url)
            let size = FileSize.of(url)
            do {
                var root = stat()
                guard lstat(url.path, &root) == 0 else { throw ShredError.openFailed(errno) }
                try shredItem(url, device: root.st_dev, progress: progress)
                report.removed.append(url)
                report.freedBytes += size
            } catch {
                report.failed.append((url, error.localizedDescription))
            }
        }
        return report
    }

    /// `device` is the volume the dropped item lives on: anything mounted inside it (a disk image,
    /// a network share) is on another device and is refused instead of being wiped along.
    func shredItem(_ url: URL, device: dev_t, progress: ((URL) -> Void)?) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw ShredError.openFailed(errno) }
        guard st.st_dev == device else { throw ShredError.otherVolume }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            // Remove the link only; its target is not ours to shred.
            try FileManager.default.removeItem(at: url)
        case S_IFDIR:
            // If the folder cannot be listed, stop: removing it now would delete files without overwriting them.
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { throw ShredError.unreadableFolder }
            for child in children { try shredItem(child, device: device, progress: progress) }
            try FileManager.default.removeItem(at: url)
        case S_IFREG:
            progress?(url)
            if st.st_nlink > 1 { throw ShredError.hardLinked }
            try overwrite(url, size: Int64(st.st_size))
            try FileManager.default.removeItem(at: scramble(url))
        default:
            throw ShredError.notRegular
        }
    }

    /// Overwrites the whole file `passes` times with random data and flushes it to disk.
    func overwrite(_ url: URL, size: Int64, truncate: Bool = true) throws {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ShredError.openFailed(errno) }
        defer { close(fd) }
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        for _ in 0..<passes {
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw ShredError.writeFailed(errno) }
            var left = size
            while left > 0 {
                let n = Int(min(Int64(chunk), left))
                arc4random_buf(&buffer, n)
                let written = buffer.withUnsafeBytes { write(fd, $0.baseAddress, n) }
                guard written == n else { throw ShredError.writeFailed(errno) }
                left -= Int64(n)
            }
            // F_FULLFSYNC asks the drive itself to flush its cache, not just the OS.
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        }
        if truncate { ftruncate(fd, 0) }
    }

    /// Renames the file to a random name so the original name does not linger in the directory.
    func scramble(_ url: URL) throws -> URL {
        let random = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        try FileManager.default.moveItem(at: url, to: random)
        return random
    }
}
