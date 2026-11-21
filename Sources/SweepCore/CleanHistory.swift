import Foundation

/// Every clean MyOpenCleaner has done, with enough detail to put Trash items back where they were.
public struct CleanHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let module: String
    public let freedBytes: Int64
    public let removedCount: Int
    /// Items that went to the Trash and can be restored.
    public let trashed: [TrashedItem]
    public var restoredAt: Date?

    /// Items removed for good (Trash emptied, permanent mode, privacy, shredder, simulators).
    public var permanentCount: Int { removedCount - trashed.count }
}

public struct RestoreReport: Sendable {
    public var restored: [URL] = []
    public var failed: [(url: URL, reason: String)] = []
}

public final class CleanHistory: @unchecked Sendable {
    public let fileURL: URL
    public private(set) var entries: [CleanHistoryEntry] = []
    private let lock = NSLock()
    static let limit = 100

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let e = try? dec.decode([CleanHistoryEntry].self, from: data) {
            entries = e
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyOpenCleaner/clean-history.json")
    }

    /// Records a clean; returns the entry, or nil when nothing was removed.
    @discardableResult
    public func record(module: String, report: CleanReport, at date: Date = Date()) -> CleanHistoryEntry? {
        guard !report.removed.isEmpty else { return nil }
        let entry = CleanHistoryEntry(id: UUID(), date: date, module: module, freedBytes: report.freedBytes,
                                      removedCount: report.removed.count, trashed: report.trashed, restoredAt: nil)
        lock.withLock {
            entries.insert(entry, at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        save()
        return entry
    }

    /// How many of the entry's items are still in the Trash and can go back.
    public func restorableCount(_ entry: CleanHistoryEntry) -> Int {
        guard entry.restoredAt == nil else { return 0 }
        return entry.trashed.filter {
            FileManager.default.fileExists(atPath: $0.inTrash.path) && !FileManager.default.fileExists(atPath: $0.original.path)
        }.count
    }

    /// Moves the entry's items from the Trash back to where they were. Nothing is overwritten:
    /// an item whose original place is taken again stays in the Trash.
    public func restore(_ id: UUID) -> RestoreReport {
        var report = RestoreReport()
        guard let index = lock.withLock({ entries.firstIndex { $0.id == id } }) else { return report }
        let fm = FileManager.default
        for item in entries[index].trashed {
            guard fm.fileExists(atPath: item.inTrash.path) else {
                report.failed.append((item.original, "No longer in the Trash"))
                continue
            }
            guard !fm.fileExists(atPath: item.original.path) else {
                report.failed.append((item.original, "Something else is in its place now"))
                continue
            }
            do {
                try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: item.inTrash, to: item.original)
                report.restored.append(item.original)
            } catch {
                report.failed.append((item.original, error.localizedDescription))
            }
        }
        if !report.restored.isEmpty {
            lock.withLock { entries[index].restoredAt = Date() }
            save()
        }
        return report
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = lock.withLock { try? enc.encode(entries) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
