import Foundation
import Testing
@testable import MyOpenCleaner

@Suite struct BatteryParsingTests {
    /// Registry layout of an Apple silicon MacBook: percentages on top, mAh in AppleRaw* keys.
    let appleSilicon: [String: Any] = [
        "MaxCapacity": 100, "CurrentCapacity": 81, "AppleRawMaxCapacity": 5600, "AppleRawCurrentCapacity": 4536,
        "DesignCapacity": 6075, "NominalChargeCapacity": 5710, "CycleCount": 212, "DesignCycleCount9C": 1000,
        "Temperature": 3055, "Voltage": 12456, "InstantAmperage": -1500, "IsCharging": false,
        "ExternalConnected": false, "FullyCharged": false, "AvgTimeToEmpty": 245, "Serial": "F8Y2345ABCD",
        "DeviceName": "bq40z651",
        "BatteryData": ["ChemID": 6950, "LifetimeData": ["MaximumTemperature": 412, "MinimumTemperature": 105,
                                                            "TotalOperatingTime": 8760]],
    ]

    @Test func parsesAppleSiliconLayout() throws {
        let b = try #require(BatteryInfo(top: appleSilicon, pack: nil, banks: []))
        #expect(b.percent == 81)
        #expect(b.currentCapacity == 4536)
        #expect(b.fullChargeCapacity == 5600)
        #expect(b.designCapacity == 6075)
        #expect(b.cycleCount == 212)
        #expect(b.designCycleCount == 1000)
        #expect(b.temperature == 30.55)
        #expect(b.voltage == 12.456)
        #expect(b.amperage == -1500)
        #expect(abs(b.watts - (-18.684)) < 0.001)
        #expect(b.minutesRemaining == 245)
        #expect(b.stateText == "Discharging")
        #expect(b.gaugeName == "bq40z651")
        #expect(b.chemID == 6950)
        #expect(b.lifetime.maxTemp == 41.2, "tenths of a degree")
        #expect(b.lifetime.operatingHours == 8760)
        #expect(!b.raw.isEmpty)
    }

    @Test func healthFollowsTheSystemFormula() throws {
        let b = try #require(BatteryInfo(top: appleSilicon, pack: nil, banks: []))
        // macOS: nominal / design.
        #expect(abs(b.systemHealth! - 5710.0 / 6075.0 * 100) < 0.0001)
        #expect(b.healthText == "94%")
        #expect(b.condition == "Normal")
        #expect(abs(b.health - 5600.0 / 6075.0 * 100) < 0.0001)
        #expect(!b.systemHealthEstimated)
    }

    @Test func wornBatteryGetsServiceRecommended() throws {
        var d = appleSilicon
        d["NominalChargeCapacity"] = 4500
        let b = try #require(BatteryInfo(top: d, pack: nil, banks: []))
        #expect(b.displayHealth < 80)
        #expect(b.condition == "Service Recommended")
        #expect(localizedCondition(b.condition!) == "Service recommended")
    }

    @Test func healthNeverExceedsHundred() throws {
        var d = appleSilicon
        d["NominalChargeCapacity"] = 6500
        d["AppleRawMaxCapacity"] = 6500
        let b = try #require(BatteryInfo(top: d, pack: nil, banks: []))
        #expect(b.displayHealth == 100)
        #expect(b.health > 100, "raw full/design can exceed 100 on a fresh pack")
    }

    @Test func parsesIntelLayoutWithMahOnTop() throws {
        let intel: [String: Any] = ["MaxCapacity": 5200, "CurrentCapacity": 2600, "DesignCapacity": 6000,
                                    "CycleCount": 400, "Voltage": 11400, "Amperage": 2000, "IsCharging": true,
                                    "ExternalConnected": true,
                                    "AdapterDetails": ["Watts": 61, "Name": "61W USB-C Power Adapter", "AdapterVoltage": 20000]]
        let b = try #require(BatteryInfo(top: intel, pack: nil, banks: []))
        #expect(b.fullChargeCapacity == 5200)
        #expect(b.currentCapacity == 2600)
        #expect(b.percent == 50)
        #expect(b.isCharging && b.externalConnected)
        #expect(b.stateText == "Charging")
        #expect(b.adapter?.watts == 61)
        #expect(b.adapter?.voltage == 20)
        #expect(b.systemHealth == nil, "no nominal capacity reported")
        #expect(abs(b.displayHealth - 5200.0 / 6000.0 * 100) < 0.0001)
    }

    @Test func packAndBanksAreRead() throws {
        let pack: [String: Any] = ["BatteryData": ["LifetimeData": ["MaximumPackVoltage": 13100]], "Temperature": 2900]
        let banks: [[String: Any]] = [
            ["BatteryData": ["CellVoltage": 4150, "LifetimeData": ["MaximumQmax": 6200]]],
            ["BatteryData": ["CellVoltage": 4148, "LifetimeData": ["MaximumQmax": 6150]]],
        ]
        let b = try #require(BatteryInfo(top: appleSilicon, pack: pack, banks: banks))
        #expect(b.cellVoltages == [4150, 4148])
        #expect(b.peakCapacity == 6150, "the weakest bank bounds the pack")
        #expect(b.lifetime.maxPackVoltage == 13100)
        #expect(b.systemHealthEstimated, "peak above design: health is measured against the peak")
        #expect(abs(b.systemHealth! - 5710.0 / 6150.0 * 100) < 0.0001)
    }

    @Test func emptyRegistryIsNoBattery() {
        #expect(BatteryInfo(top: [:], pack: nil, banks: []) == nil)
        #expect(BatteryInfo(top: ["CycleCount": 5], pack: nil, banks: []) == nil)
    }

    @Test func chargedOnMainsStates() throws {
        var d = appleSilicon
        d["ExternalConnected"] = true; d["FullyCharged"] = true; d["CurrentCapacity"] = 100
        #expect(try #require(BatteryInfo(top: d, pack: nil, banks: [])).stateText == "Charged")
        d["FullyCharged"] = false; d["CurrentCapacity"] = 80
        #expect(try #require(BatteryInfo(top: d, pack: nil, banks: [])).stateText == "On power, charging paused")
    }
}

@Suite struct ManufactureDateTests {
    let cal = Calendar(identifier: .gregorian)

    @Test func smartBatteryPackedDate() throws {
        // (year-1980)<<9 | month<<5 | day → 14 March 2021
        let raw = (2021 - 1980) << 9 | 3 << 5 | 14
        let (date, approx) = try #require(ManufactureDate.decode(raw: raw, serial: nil, operatingHours: nil))
        #expect(cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2021, month: 3, day: 14))
        #expect(!approx)
    }

    @Test func asciiDigitsDate() throws {
        // "220915" packed as six ASCII bytes.
        let raw = "220915".utf8.reduce(0) { $0 << 8 | Int($1) }
        let (date, approx) = try #require(ManufactureDate.decode(raw: raw, serial: nil, operatingHours: nil))
        #expect(cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2022, month: 9, day: 15))
        #expect(!approx)
    }

    @Test func invalidValuesGiveNoDate() {
        #expect(ManufactureDate.decode(raw: nil, serial: nil, operatingHours: nil) == nil)
        #expect(ManufactureDate.decode(raw: 0, serial: "abc", operatingHours: nil) == nil)
        // month 15 is impossible
        #expect(ManufactureDate.decode(raw: (2020 - 1980) << 9 | 15 << 5 | 1, serial: nil, operatingHours: nil) == nil)
    }

    @Test func serialFallbackIsMarkedApproximate() throws {
        let year = cal.component(.year, from: Date()) - 1
        let serial = "ABC\(year % 10)10XYZ"          // 4th char: year digit, then week "10"
        let (date, approx) = try #require(ManufactureDate.decode(raw: nil, serial: serial, operatingHours: nil))
        #expect(approx)
        #expect(Calendar(identifier: .iso8601).component(.yearForWeekOfYear, from: date) == year)
        #expect(Calendar(identifier: .iso8601).component(.weekOfYear, from: date) == 10)
    }

    @Test func serialContradictingOperatingHoursIsRejected() {
        // Serial says ~9 years ago, but the pack has only run for 100 hours.
        let year = cal.component(.year, from: Date()) - 9
        let serial = "ABC\(year % 10)10XYZ"
        #expect(ManufactureDate.decode(raw: nil, serial: serial, operatingHours: 100) == nil)
    }
}

@Suite struct BatteryFormattingTests {
    @Test func rawValuesAreDescribed() {
        #expect(RawFlatten.describe(true as NSNumber) == "true")
        #expect(RawFlatten.describe(42 as NSNumber) == "42")
        #expect(RawFlatten.describe("x") == "x")
        #expect(RawFlatten.describe(Data("bq40z651".utf8) + Data([0, 0])) == "bq40z651")
        #expect(RawFlatten.describe(Data([0xde, 0xad])) == "<dead>")
        #expect(RawFlatten.describe([1, 2] as [Any]) == "[1, 2]")
    }

    @Test func flattenUsesDottedPaths() {
        var out: [RawEntry] = []
        RawFlatten.flatten(["B": ["C": 1], "A": 2], prefix: "Top", into: &out)
        #expect(out.map(\.key) == ["Top.A", "Top.B.C"])
        #expect(out.map(\.value) == ["2", "1"])
    }

    @Test func durationsAndAges() {
        #expect(Fmt.duration(minutes: 245) == "4:05")
        #expect(Fmt.mAh(5600) == "5600 mAh")
        let now = Date()
        let cal = Calendar.current
        #expect(Fmt.age(since: cal.date(byAdding: .day, value: -5, to: now)!, now: now) == "5 days")
        #expect(Fmt.age(since: cal.date(byAdding: .month, value: -3, to: now)!, now: now) == "3 mo")
        #expect(Fmt.age(since: cal.date(byAdding: DateComponents(year: -4, month: -3), to: now)!, now: now) == "4 yr 3 mo")
        #expect(Fmt.temp(nil) == "—")
    }

    @Test func symbolsAndConditions() {
        #expect(batterySymbol(percent: 95, charging: false) == "battery.100percent")
        #expect(batterySymbol(percent: 50, charging: false) == "battery.50percent")
        #expect(batterySymbol(percent: 5, charging: false) == "battery.0percent")
        #expect(batterySymbol(percent: 5, charging: true) == "battery.100percent.bolt")
        #expect(localizedCondition("Normal") == "Normal")
        #expect(localizedCondition("Something new") == "Something new")
    }

    @Test func historyHealthPrefersTheSystemFigure() {
        let old = HistoryEntry(date: Date(), fullCharge: 5000, design: 6000, cycles: 10)
        #expect(abs(old.health - 83.333) < 0.01)
        let new = HistoryEntry(date: Date(), fullCharge: 5000, design: 6000, cycles: 10, osHealth: 91)
        #expect(new.health == 91)
        #expect(HistoryEntry(date: Date(), fullCharge: 7000, design: 6000, cycles: 1).health == 100)
    }

    @Test func liveMacReaderDoesNotCrash() {
        // On a MacBook this returns real data; on a desktop Mac it is nil. Both are fine.
        if let b = MacBatteryReader.read() {
            #expect((0...100).contains(b.percent))
            #expect(b.designCapacity > 0)
            #expect(b.displayHealth > 0 && b.displayHealth <= 100)
        }
        #expect(!MacBatteryReader.systemInfo().modelID.isEmpty)
    }
}
