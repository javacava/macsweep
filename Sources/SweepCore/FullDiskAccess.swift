import Foundation

/// Whether this app has Full Disk Access, found out by actually trying to read places macOS only
/// opens with it. There is no public API that answers the question directly.
public enum FullDiskAccess: Equatable, Sendable {
    case granted, denied, unknown

    /// Protected places, tried in order. The first one that exists decides.
    static let probes = [
        "~/Library/Application Support/com.apple.TCC/TCC.db",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/CloudTabs.db",
        "~/Library/Mail",
    ]

    public static func check(env: SweepEnvironment) -> FullDiskAccess {
        for p in probes {
            let url = env.resolve(p)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    return .granted
                } catch {
                    return .denied
                }
            }
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == EPERM || errno == EACCES { return .denied }
        }
        return .unknown
    }
}
