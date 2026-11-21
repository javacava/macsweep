import Foundation

struct RawEntry: Identifiable {
    let id: String
    let key: String
    let value: String
}

struct AdapterInfo {
    var watts: Int?
    var name: String?
    var voltage: Double?
    var current: Int?
    var isWireless = false
}

struct LifetimeInfo {
    var minTemp: Double?
    var maxTemp: Double?
    var avgTemp: Double?
    var operatingHours: Int?
    var maxChargeCurrent: Int?
    var maxDischargeCurrent: Int?
    var minPackVoltage: Int?
    var maxPackVoltage: Int?
}

/// Battery state shared by the Mac and iOS readers. Both expose the same
/// AppleSmartBattery registry layout, so one parser serves both.
struct BatteryInfo {
    var currentCapacity = 0          // mAh
    var fullChargeCapacity = 0       // mAh
    var nominalCapacity: Int?        // mAh, what the OS uses for "Maximum Capacity"
    var peakCapacity: Int?           // mAh, largest capacity the gauge ever measured (Qmax)
    var designCapacity = 0           // mAh
    var percent = 0                  // what the OS shows
    var cycleCount = 0
    var designCycleCount: Int?
    var temperature: Double?         // °C
    var voltage = 0.0                // V
    var amperage = 0                 // mA, positive while charging
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var minutesRemaining: Int?
    var adapter: AdapterInfo?
    var serial: String?
    var manufactureDate: Date?
    var manufactureDateApprox = false
    var condition: String?
    var cellVoltages: [Int] = []
    var lifetime = LifetimeInfo()
    var chemID: Int?
    var gaugeName: String?
    var systemLoadWatts: Double?
    var systemInputWatts: Double?
    var dailyMinSoc: Int?
    var dailyMaxSoc: Int?
    var raw: [RawEntry] = []
    var updated = Date()

    var watts: Double { voltage * Double(amperage) / 1000 }

    var health: Double {
        designCapacity > 0 ? Double(fullChargeCapacity) / Double(designCapacity) * 100 : 0
    }

    /// The "Maximum Capacity" figure the OS shows in its own battery settings.
    /// macOS divides the nominal capacity by the design capacity. iOS does not
    /// expose its figure over the cable; a fresh iPhone pack measures above its
    /// design value, and dividing by that measured peak instead is what matched
    /// the number in Settings on the device this was checked against.
    var systemHealth: Double? {
        guard let nominalCapacity, designCapacity > 0 else { return nil }
        let reference = max(designCapacity, peakCapacity ?? 0)
        return min(100, Double(nominalCapacity) / Double(reference) * 100)
    }

    /// The one "battery health" number shown up front: the OS figure when it can
    /// be worked out, otherwise measured full capacity against design, capped at 100.
    var displayHealth: Double { systemHealth ?? min(100, health) }

    /// `displayHealth` rounded the way the OS shows it, e.g. "96%".
    var healthText: String { "\(Int(displayHealth.rounded()))%" }

    /// True when `systemHealth` rests on the measured peak rather than the design value.
    var systemHealthEstimated: Bool { (peakCapacity ?? 0) > designCapacity }

    var chargeFraction: Double {
        fullChargeCapacity > 0 && currentCapacity > 0
            ? Double(currentCapacity) / Double(fullChargeCapacity)
            : Double(percent) / 100
    }


    var stateText: String {
        if externalConnected {
            if isCharging { return "Charging" }
            if fullyCharged || percent >= 100 { return "Charged" }
            return "On power, charging paused"
        }
        return "Discharging"
    }

    /// Estimated first-use date from the gauge's operating-hours counter.
    var firstUseEstimate: Date? {
        guard let h = lifetime.operatingHours, h > 0 else { return nil }
        return Date().addingTimeInterval(-Double(h) * 3600)
    }
}

// MARK: - Parsing

func asInt(_ v: Any?) -> Int? {
    guard let n = v as? NSNumber else { return nil }
    return Int(truncatingIfNeeded: n.int64Value)
}

func asBool(_ v: Any?) -> Bool {
    (v as? NSNumber)?.boolValue ?? false
}

extension BatteryInfo {
    init?(top: [String: Any], pack: [String: Any]?, banks: [[String: Any]]) {
        let topBD = top["BatteryData"] as? [String: Any] ?? [:]
        let packBD = pack?["BatteryData"] as? [String: Any] ?? [:]

        func find(_ k: String) -> Any? { packBD[k] ?? topBD[k] ?? top[k] ?? pack?[k] }
        func int(_ keys: String...) -> Int? {
            for k in keys { if let v = asInt(find(k)) { return v } }
            return nil
        }

        let topMax = asInt(top["MaxCapacity"]) ?? 0
        let topCur = asInt(top["CurrentCapacity"]) ?? 0

        // Apple silicon / iOS report percentages at the top level and mAh in
        // the AppleRaw* keys; Intel Macs report mAh at the top level directly.
        var full = int("AppleRawMaxCapacity") ?? 0
        if full == 0 {
            full = [asInt(topBD["FullChargeCapacity"]), topMax].compactMap { $0 }.first { $0 > 100 } ?? 0
        }
        var cur = int("AppleRawCurrentCapacity") ?? 0
        if cur == 0, topMax > 100 { cur = topCur }
        let design = int("DesignCapacity") ?? 0
        guard full > 0 || design > 0 else { return nil }

        currentCapacity = cur
        fullChargeCapacity = full
        designCapacity = design
        nominalCapacity = int("NominalChargeCapacity")
        // With cells in series the weakest bank bounds the pack, hence min().
        peakCapacity = banks.compactMap { bank -> Int? in
            let data = bank["BatteryData"] as? [String: Any]
            return asInt((data?["LifetimeData"] as? [String: Any])?["MaximumQmax"])
        }.filter { $0 > 0 }.min()
        if topMax == 100 {
            percent = topCur
        } else if full > 0 {
            percent = Int((Double(cur) / Double(full) * 100).rounded())
        }
        percent = max(0, min(100, percent))

        cycleCount = int("CycleCount") ?? 0
        designCycleCount = int("DesignCycleCount9C", "DesignCycleCount")
        if let t = int("Temperature", "VirtualTemperature"), t != 0 {
            temperature = Double(t) / 100
        }
        let mV = asInt(top["Voltage"]) ?? int("AppleRawBatteryVoltage", "Voltage") ?? 0
        voltage = Double(mV) / 1000
        amperage = asInt(top["InstantAmperage"]) ?? int("InstantAmperage", "Amperage") ?? 0
        isCharging = asBool(top["IsCharging"])
        externalConnected = asBool(top["ExternalConnected"])
        fullyCharged = asBool(top["FullyCharged"])

        let ttKey = isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        if let m = asInt(top[ttKey]) ?? asInt(top["TimeRemaining"]), m > 0, m < 6000 {
            minutesRemaining = m
        }

        if externalConnected, let a = top["AdapterDetails"] as? [String: Any] {
            var ad = AdapterInfo()
            ad.watts = asInt(a["Watts"])
            ad.name = (a["Name"] as? String) ?? (a["Description"] as? String)
            if let v = asInt(a["AdapterVoltage"]) ?? asInt(a["Voltage"]) { ad.voltage = Double(v) / 1000 }
            ad.current = asInt(a["Current"])
            ad.isWireless = asBool(a["IsWireless"])
            adapter = ad
        }

        // Apple's own rule: service is recommended once capacity drops below 80%
        // of design, or when the gauge has latched a permanent failure.
        if let failure = int("PermanentFailureStatus"), failure != 0 {
            condition = "Service Recommended"
        } else if let sys = systemHealth {
            condition = sys < 80 ? "Service Recommended" : "Normal"
        }

        serial = (find("Serial") as? String) ?? (find("BatterySerialNumber") as? String)
        chemID = int("ChemID")
        gaugeName = top["DeviceName"] as? String
        dailyMinSoc = int("DailyMinSoc")
        dailyMaxSoc = int("DailyMaxSoc")

        if let pt = top["PowerTelemetryData"] as? [String: Any] {
            if let v = asInt(pt["SystemLoad"]), v > 0 { systemLoadWatts = Double(v) / 1000 }
            if let v = asInt(pt["SystemPowerIn"]), v > 0 { systemInputWatts = Double(v) / 1000 }
        }

        // Cell voltages: one per series bank on current hardware, an array on older Macs.
        cellVoltages = banks.compactMap { asInt(($0["BatteryData"] as? [String: Any])?["CellVoltage"]) }
        if cellVoltages.isEmpty, let arr = find("CellVoltage") as? [Any] {
            cellVoltages = arr.compactMap { asInt($0) }.filter { $0 > 0 }
        }

        let lt = (packBD["LifetimeData"] as? [String: Any]) ?? (topBD["LifetimeData"] as? [String: Any]) ?? [:]
        // Firmware reports these either in whole degrees or in tenths.
        func ltTemp(_ k: String) -> Double? {
            guard let v = asInt(lt[k]) else { return nil }
            return abs(v) > 100 ? Double(v) / 10 : Double(v)
        }
        lifetime.minTemp = ltTemp("MinimumTemperature")
        lifetime.maxTemp = ltTemp("MaximumTemperature")
        lifetime.avgTemp = ltTemp("AverageTemperature")
        lifetime.operatingHours = asInt(lt["TotalOperatingTime"])
        lifetime.maxChargeCurrent = asInt(lt["MaximumChargeCurrent"])
        lifetime.maxDischargeCurrent = asInt(lt["MaximumDischargeCurrent"])
        lifetime.minPackVoltage = asInt(lt["MinimumPackVoltage"])
        lifetime.maxPackVoltage = asInt(lt["MaximumPackVoltage"])

        if let (date, approx) = ManufactureDate.decode(
            raw: int("ManufactureDate"), serial: serial, operatingHours: lifetime.operatingHours
        ) {
            manufactureDate = date
            manufactureDateApprox = approx
        }

        var entries: [RawEntry] = []
        RawFlatten.flatten(top, prefix: "AppleSmartBattery", into: &entries)
        if let pack { RawFlatten.flatten(pack, prefix: "AppleSmartBatteryPack", into: &entries) }
        for (i, bank) in banks.enumerated() {
            RawFlatten.flatten(bank, prefix: "AppleSmartBatteryBank[\(i)]", into: &entries)
        }
        raw = entries
    }
}

enum ManufactureDate {
    static func decode(raw: Int?, serial: String?, operatingHours: Int?) -> (Date, Bool)? {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let thisYear = cal.component(.year, from: now)

        func valid(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (2005...thisYear).contains(y), (1...12).contains(m), (1...31).contains(d),
                  let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
                  date <= now.addingTimeInterval(86400) else { return nil }
            return date
        }

        if let raw, raw > 0xFFFF {
            // Six ASCII digits "YYMMDD" packed into an integer.
            var bytes: [UInt8] = []
            var v = UInt64(truncatingIfNeeded: raw)
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            for candidate in [bytes, bytes.reversed()] {
                guard candidate.count == 6, candidate.allSatisfy({ (48...57).contains($0) }) else { continue }
                let n = candidate.map { Int($0) - 48 }
                if let d = valid(2000 + n[0] * 10 + n[1], n[2] * 10 + n[3], n[4] * 10 + n[5]) {
                    return (d, false)
                }
            }
        } else if let raw, raw > 0 {
            // Smart Battery packed date: (year-1980)<<9 | month<<5 | day
            if let d = valid(1980 + (raw >> 9), (raw >> 5) & 0xF, raw & 0x1F) { return (d, false) }
        }

        // Fall back to the pack serial: 4th char = last digit of the year,
        // 5th-6th = week, 7th = weekday.
        guard let serial, serial.count >= 7 else { return nil }
        let c = Array(serial)
        guard let y = c[3].wholeNumberValue, let w1 = c[4].wholeNumberValue,
              let w2 = c[5].wholeNumberValue else { return nil }
        let week = w1 * 10 + w2
        guard (1...53).contains(week) else { return nil }
        var year = thisYear - ((thisYear - y) % 10 + 10) % 10
        let iso = Calendar(identifier: .iso8601)
        func build(_ year: Int) -> Date? {
            iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year))
        }
        guard var date = build(year) else { return nil }
        if date > now { year -= 10; guard let d = build(year) else { return nil }; date = d }
        // A serial that puts manufacture years before the pack first ran is not
        // following this scheme (seen on replacement packs) — better no date than a wrong one.
        if let h = operatingHours, h > 0 {
            let firstUse = now.addingTimeInterval(-Double(h) * 3600)
            if firstUse.timeIntervalSince(date) > 2.5 * 365 * 86400 { return nil }
        }
        return (date, true)
    }
}

enum RawFlatten {
    static func flatten(_ dict: [String: Any], prefix: String, into out: inout [RawEntry]) {
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let path = prefix + "." + k
            if let d = v as? [String: Any] {
                flatten(d, prefix: path, into: &out)
            } else {
                out.append(RawEntry(id: path, key: path, value: describe(v)))
            }
        }
    }

    static func describe(_ v: Any) -> String {
        switch v {
        case let d as Data:
            let trimmed = d.prefix { $0 != 0 }
            if trimmed.count >= 3, trimmed.allSatisfy({ (32...126).contains($0) }),
               d.dropFirst(trimmed.count).allSatisfy({ $0 == 0 }),
               let s = String(data: trimmed, encoding: .ascii) {
                return s
            }
            let hex = d.prefix(32).map { String(format: "%02x", $0) }.joined()
            return "<" + hex + (d.count > 32 ? "… \(d.count) bytes" : "") + ">"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if CFNumberIsFloatType(n) { return String(n.doubleValue) }
            return String(n.int64Value)
        case let s as String:
            return s
        case let a as [Any]:
            let s = "[" + a.map(describe).joined(separator: ", ") + "]"
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        case let d as [String: Any]:
            let s = "{" + d.sorted { $0.key < $1.key }.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") + "}"
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        default:
            return "\(v)"
        }
    }
}
