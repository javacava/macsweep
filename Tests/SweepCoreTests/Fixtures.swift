import Foundation
@testable import SweepCore

/// A throwaway fake Mac: `home` and `root` folders inside a temp dir.
final class Sandbox {
    let base: URL
    let env: SweepEnvironment
    var home: URL { env.home }
    var root: URL { env.root }

    init(now: Date = Date()) {
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: b.appendingPathComponent("home"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: b.appendingPathComponent("root"), withIntermediateDirectories: true)
        base = b.resolvingSymlinksInPath()
        env = SweepEnvironment(home: base.appendingPathComponent("home"), root: base.appendingPathComponent("root"), now: { now })
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    /// Creates a file at `~/...` or `/...` with `bytes` bytes (or the given data).
    @discardableResult
    func file(_ path: String, bytes: Int = 10, data: Data? = nil, modified: Date? = nil) -> URL {
        let url = env.resolve(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! (data ?? Data(repeating: 0x41, count: bytes)).write(to: url)
        if let modified {
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func dir(_ path: String) -> URL {
        let url = env.resolve(path)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plist(_ path: String, _ dict: [String: Any]) {
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        file(path, data: data)
    }

    /// A minimal .app bundle.
    @discardableResult
    func app(_ path: String, id: String, name: String, version: String = "1.0", build: String = "1",
             feed: String? = nil, appStore: Bool = false) -> URL {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name,
                                   "CFBundleShortVersionString": version, "CFBundleVersion": build]
        if let feed { info["SUFeedURL"] = feed }
        plist(path + "/Contents/Info.plist", info)
        file(path + "/Contents/MacOS/\(name)", bytes: 2000)
        if appStore { file(path + "/Contents/_MASReceipt/receipt", bytes: 5) }
        return env.resolve(path)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: env.resolve(path).path) }
}

/// Records commands instead of running them.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var responses: [String: CommandResult] = [:]
    var defaultResult = CommandResult(status: 0)

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let call = [executable] + arguments
        lock.withLock { calls.append(call) }
        let key = call.joined(separator: " ")
        return responses.first { key.hasPrefix($0.key) }?.value ?? defaultResult
    }
}

/// Deletes for real (inside the sandbox) and remembers what was trashed vs deleted.
final class RecordingRemover: FileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var trashed: [URL] = []
    private(set) var deleted: [URL] = []
    var failOn: Set<String> = []

    struct Failure: Error {}

    /// Where "trashed" items go. nil: they are simply deleted (and no landing place is reported).
    var trashFolder: URL?

    func moveToTrash(_ url: URL) throws -> URL? {
        if failOn.contains(url.lastPathComponent) { throw Failure() }
        lock.withLock { trashed.append(url) }
        guard let trashFolder else {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let landed = trashFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
    }

    func removePermanently(_ url: URL) throws {
        if failOn.contains(url.lastPathComponent) { throw Failure() }
        try FileManager.default.removeItem(at: url)
        lock.withLock { deleted.append(url) }
    }
}

let day: TimeInterval = 86_400
