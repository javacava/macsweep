import Foundation

/// "Activity": how much space was freed and when maintenance last ran. Stored as JSON.
public struct ActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let module: String
    public let freedBytes: Int64
    public let itemCount: Int
}

public final class ActivityLog: @unchecked Sendable {
    public struct State: Codable, Equatable {
        public var entries: [ActivityEntry] = []
        public var lastMaintenance: [String: Date] = [:]
    }

    public let fileURL: URL
    public private(set) var state: State
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyOpenCleaner/activity.json")
    }

    public var totalFreed: Int64 { state.entries.reduce(0) { $0 + $1.freedBytes } }

    public func freed(since: Date) -> Int64 {
        state.entries.filter { $0.date >= since }.reduce(0) { $0 + $1.freedBytes }
    }

    public func record(module: String, freed: Int64, items: Int, at date: Date = Date()) {
        lock.withLock {
            state.entries.append(ActivityEntry(date: date, module: module, freedBytes: freed, itemCount: items))
            if state.entries.count > 1000 { state.entries.removeFirst(state.entries.count - 1000) }
        }
        save()
    }

    public func markMaintenance(_ ids: [String], at date: Date = Date()) {
        lock.withLock { for id in ids { state.lastMaintenance[id] = date } }
        save()
    }

    func save() {
        let data = lock.withLock { try? JSONEncoder().encode(state) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
