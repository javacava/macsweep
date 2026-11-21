import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var fullCharge: Int
    var design: Int
    var cycles: Int
    var temperature: Double?
    /// The headline health figure at the time; missing in entries from older versions.
    var osHealth: Double?

    var health: Double { osHealth ?? min(100, design > 0 ? Double(fullCharge) / Double(design) * 100 : 0) }
}

struct HistoryDevice: Codable, Identifiable {
    var id: String
    var name: String
    var kind: String        // "mac" | "ios"
    var entries: [HistoryEntry] = []
}

/// Battery health snapshots over time, one JSON file in Application Support.
final class HistoryStore: ObservableObject {
    @Published private(set) var devices: [HistoryDevice] = []
    private let url: URL

    init(url fixedURL: URL? = nil) {
        if let fixedURL {
            url = fixedURL
            load()
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("MyOpenCleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("battery-history.json")
        // First run: start from Bettary's history (a copy, so the two apps never write the same file).
        let bettary = support.appendingPathComponent("Bettary/history.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: bettary.path) {
            try? FileManager.default.copyItem(at: bettary, to: url)
        }
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        devices = (try? dec.decode([HistoryDevice].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(devices) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func device(_ id: String) -> HistoryDevice? { devices.first { $0.id == id } }

    /// Adds a snapshot. With `onlyOncePerDay` it is skipped when today already has one.
    @discardableResult
    func record(id: String, name: String, kind: String, battery: BatteryInfo, onlyOncePerDay: Bool) -> Bool {
        guard battery.fullChargeCapacity > 0, battery.designCapacity > 0 else { return false }
        var idx = devices.firstIndex { $0.id == id }
        if idx == nil {
            devices.append(HistoryDevice(id: id, name: name, kind: kind))
            idx = devices.count - 1
        }
        guard let i = idx else { return false }
        if onlyOncePerDay, let last = devices[i].entries.last, Calendar.current.isDateInToday(last.date) {
            // Today's entry from an older version lacks the health figure; fill it in.
            if last.osHealth == nil {
                devices[i].entries[devices[i].entries.count - 1].osHealth = battery.displayHealth
                devices[i].name = name
                save()
            } else if devices[i].name != name {
                devices[i].name = name
                save()
            }
            return false
        }
        devices[i].name = name
        devices[i].entries.append(HistoryEntry(
            date: Date(), fullCharge: battery.fullChargeCapacity, design: battery.designCapacity,
            cycles: battery.cycleCount, temperature: battery.temperature, osHealth: battery.displayHealth
        ))
        save()
        return true
    }

    func delete(entries ids: Set<UUID>, from deviceID: String) {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[i].entries.removeAll { ids.contains($0.id) }
        if devices[i].entries.isEmpty { devices.remove(at: i) }
        save()
    }

    func csv(for deviceID: String) -> String {
        guard let d = device(deviceID) else { return "" }
        let f = ISO8601DateFormatter()
        var lines = ["date,full_charge_mah,design_mah,health_percent,cycles,temperature_c"]
        for e in d.entries {
            let t = e.temperature.map { String(format: "%.1f", $0) } ?? ""
            lines.append("\(f.string(from: e.date)),\(e.fullCharge),\(e.design),\(String(format: "%.1f", e.health)),\(e.cycles),\(t)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
