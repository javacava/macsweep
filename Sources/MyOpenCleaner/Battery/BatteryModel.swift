import Foundation
import AppKit

struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let watts: Double
    let percent: Int
}

/// What the UI needs to draw one device, Mac or iOS.
struct DevicePresentation: Identifiable {
    var id: String
    var kind: String            // "mac" | "ios"
    var title: String
    var subtitle: String
    var symbol: String
    var facts: [(String, String)]
    var battery: BatteryInfo?
    var problem: String?
    var osLabel: String         // "macOS" / "iOS" for the OS-reported health line
}

/// Battery readings for this Mac and for iPhones/iPads on a cable. Ported from the Bettary app.
final class BatteryModel: ObservableObject {
    static let shared = BatteryModel()

    @Published var macBattery: BatteryInfo?
    @Published var devices: [IOSDevice] = []
    @Published var samples: [String: [Sample]] = [:]
    @Published var iosScanning = false

    let macSystem = Demo.active?.system ?? MacBatteryReader.systemInfo()
    let history = Demo.active.map { HistoryStore(url: $0.historyURL) } ?? HistoryStore()

    private let iosReader = IOSDeviceReader()
    private let iosQueue = DispatchQueue(label: "myopencleaner.battery.ios")
    private var macTimer: Timer?
    private var iosTimer: Timer?
    private var intervals = (mac: 0.0, ios: 0.0)
    private var started = false

    var iosSupported: Bool { iosReader.available }
    var macID: String { "mac-" + (macSystem.serial ?? macSystem.modelID) }

    func start() {
        guard !started else { return }
        started = true
        if let demo = Demo.active {
            // Screenshot mode: a fixed, made-up battery and no device polling.
            macBattery = demo.battery
            if let b = macBattery {
                samples[macID] = (0..<40).map { i in
                    Sample(date: Date().addingTimeInterval(Double(i - 40) * 30), watts: 38 + 6 * sin(Double(i) / 4), percent: b.percent)
                }
            }
            return
        }
        refreshMac()
        refreshIOS()
        scheduleTimers()
        MobileDeviceLib.shared?.startNotifications()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .iosDeviceListChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshIOS()
        }
        // SwiftUI writes defaults in the middle of its own view updates, so this
        // must not touch published state synchronously — hop to the next runloop turn.
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleTimers() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAll()
        }
    }

    private func scheduleTimers() {
        let mac = max(1, Prefs.double(Prefs.macInterval))
        let ios = max(5, Prefs.double(Prefs.iosInterval))
        guard mac != intervals.mac || ios != intervals.ios else { return }
        intervals = (mac, ios)
        macTimer?.invalidate()
        iosTimer?.invalidate()
        macTimer = Timer.scheduledTimer(withTimeInterval: mac, repeats: true) { [weak self] _ in self?.refreshMac() }
        iosTimer = Timer.scheduledTimer(withTimeInterval: ios, repeats: true) { [weak self] _ in self?.refreshIOS() }
        macTimer?.tolerance = mac * 0.2
        iosTimer?.tolerance = ios * 0.2
    }

    func refreshAll() {
        refreshMac()
        refreshIOS()
    }

    func refreshMac() {
        macBattery = MacBatteryReader.read()
        guard let b = macBattery else { return }
        track(id: macID, name: macSystem.title, kind: "mac", battery: b)
    }

    func refreshIOS() {
        guard iosSupported, !iosScanning else { return }
        iosScanning = true
        iosQueue.async { [weak self] in
            guard let self else { return }
            let list = self.iosReader.readAll()
            DispatchQueue.main.async {
                self.iosScanning = false
                self.devices = list
                for d in list {
                    if let b = d.battery { self.track(id: d.id, name: d.name, kind: "ios", battery: b) }
                }
            }
        }
    }

    private func track(id: String, name: String, kind: String, battery: BatteryInfo) {
        var list = samples[id] ?? []
        list.append(Sample(date: battery.updated, watts: battery.watts, percent: battery.percent))
        if list.count > 720 { list.removeFirst(list.count - 720) }
        samples[id] = list
        if Prefs.bool(Prefs.autoHistory) {
            history.record(id: id, name: name, kind: kind, battery: battery, onlyOncePerDay: true)
        }
    }

    // MARK: - Presentation

    var macPresentation: DevicePresentation {
        let s = macSystem
        var facts: [(String, String)] = [("Name", s.computerName), ("Model", s.modelID)]
        if let chip = s.chip { facts.append(("Chip", chip)) }
        if let serial = s.serial { facts.append(("Serial number", serial)) }
        if let year = s.modelYear { facts.append(("Model year", String(year))) }
        facts.append(("System", s.osVersion))
        return DevicePresentation(
            id: macID, kind: "mac", title: s.title,
            subtitle: [s.modelID, s.chip, s.osVersion].compactMap { $0 }.joined(separator: " · "),
            symbol: s.modelID.lowercased().contains("book") ? "laptopcomputer" : "desktopcomputer",
            facts: facts, battery: macBattery,
            problem: macBattery == nil ? "This Mac has no battery." : nil,
            osLabel: "macOS"
        )
    }

    func presentation(_ d: IOSDevice) -> DevicePresentation {
        var facts: [(String, String)] = [("Name", d.name)]
        if let m = d.modelName { facts.append(("Model", m)) }
        if !d.productType.isEmpty { facts.append(("Identifier", d.productType)) }
        if let serial = d.serial { facts.append(("Serial number", serial)) }
        if !d.osVersion.isEmpty { facts.append(("System", "\(d.osName) \(d.osVersion) (\(d.build))")) }
        facts.append(("Connection", d.link.rawValue))
        let os = d.osVersion.isEmpty ? nil : "\(d.osName) \(d.osVersion)"
        return DevicePresentation(
            id: d.id, kind: "ios", title: d.name,
            subtitle: [d.modelName ?? d.productType, os, d.link == .unknown ? nil : d.link.rawValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            symbol: d.symbol, facts: facts, battery: d.battery, problem: d.problem, osLabel: d.osName
        )
    }

    var allPresentations: [DevicePresentation] {
        [macPresentation] + devices.map(presentation)
    }

    func saveToHistory(_ p: DevicePresentation) -> Bool {
        guard let b = p.battery else { return false }
        return history.record(id: p.id, name: p.title, kind: p.kind, battery: b, onlyOncePerDay: false)
    }

    func report(_ p: DevicePresentation) -> String {
        var lines = [p.title, p.subtitle, ""]
        for (k, v) in p.facts { lines.append("\(k): \(v)") }
        guard let b = p.battery else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append("Battery health: \(b.healthText)")
        lines.append("Charge: \(b.percent)% (\(b.currentCapacity) mAh)")
        lines.append("Full charge capacity now: \(b.fullChargeCapacity) mAh, design \(b.designCapacity) mAh")
        lines.append("Charge cycles: \(b.cycleCount)")
        lines.append("Temperature: \(Fmt.temp(b.temperature))")
        lines.append("State: \(b.stateText), \(Fmt.watts(b.watts))")
        lines.append("Voltage: \(Fmt.volts(b.voltage)), current: \(b.amperage) mA")
        if let c = b.condition { lines.append("Battery condition: \(localizedCondition(c))") }

        if let a = b.adapter, let w = a.watts { lines.append("Adapter: \(w) W \(a.name ?? "")") }
        if let d = b.manufactureDate {
            lines.append("Battery manufactured: \(b.manufactureDateApprox ? "≈ " : "")\(Fmt.date(d)) (age \(Fmt.age(since: d)))")
        }
        if let s = b.serial { lines.append("Battery serial number: \(s)") }
        lines.append("Taken: \(Fmt.dateTime(b.updated))")
        return lines.joined(separator: "\n")
    }
}
