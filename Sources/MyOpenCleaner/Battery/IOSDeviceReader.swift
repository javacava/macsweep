import Foundation

struct IOSDevice: Identifiable {
    enum Link: String { case usb = "USB", wifi = "Wi-Fi", unknown = "—" }

    let id: String                 // UDID
    var name = "iOS device"
    var productType = ""
    var modelName: String?
    var deviceClass = "iPhone"
    var osVersion = ""
    var build = ""
    var serial: String?
    var link = Link.unknown
    var battery: BatteryInfo?
    var lockdownPercent: Int?
    var problem: String?

    var symbol: String {
        switch deviceClass {
        case "iPad": return "ipad"
        case "iPod": return "ipodtouch"
        default: return "iphone"
        }
    }

    var osName: String { deviceClass == "iPad" ? "iPadOS" : "iOS" }
}

/// Reads every paired iPhone/iPad the Mac can see (USB or Wi-Fi sync).
/// Not thread-safe: call from one serial queue.
final class IOSDeviceReader {
    private let lib: MobileDeviceLib?
    private var modelNames: [String: String] = [:]
    private var lastPairAttempt: [String: Date] = [:]

    init() { lib = MobileDeviceLib.shared }

    var available: Bool { lib != nil }

    func readAll() -> [IOSDevice] {
        guard let lib, let list = lib.createDeviceList()?.takeRetainedValue() as? [AnyObject] else { return [] }
        var byID: [String: IOSDevice] = [:]
        var order: [String] = []
        for obj in list {
            let dev = Unmanaged.passUnretained(obj).toOpaque()
            guard let udid = lib.copyIdentifier(dev)?.takeRetainedValue() as String? else { continue }
            let link: IOSDevice.Link = lib.interfaceType(dev) == 1 ? .usb : .wifi
            // The same device can show up once per transport; USB wins.
            if let existing = byID[udid], existing.battery != nil || existing.link == .usb { continue }
            if byID[udid] == nil { order.append(udid) }
            byID[udid] = read(lib, dev, udid: udid, link: link)
        }
        return order.compactMap { byID[$0] }
    }

    private func read(_ lib: MobileDeviceLib, _ dev: MobileDeviceLib.Dev, udid: String, link: IOSDevice.Link) -> IOSDevice {
        var d = IOSDevice(id: udid)
        d.link = link
        guard lib.connect(dev) == 0 else {
            d.problem = "Could not connect to the device."
            return d
        }
        defer { _ = lib.disconnect(dev) }

        func fill() {
            if let v = lib.string(dev, key: "DeviceName") { d.name = v }
            if let v = lib.string(dev, key: "ProductType") { d.productType = v }
            if let v = lib.string(dev, key: "DeviceClass") { d.deviceClass = v }
            if let v = lib.string(dev, key: "ProductVersion") { d.osVersion = v }
            if let v = lib.string(dev, key: "BuildVersion") { d.build = v }
            if let v = lib.string(dev, key: "SerialNumber") { d.serial = v }
        }
        fill()
        d.modelName = modelNames[udid]

        if lib.isPaired(dev) == 0 {
            // Asks the device to show its "Trust This Computer?" prompt.
            let last = lastPairAttempt[udid] ?? .distantPast
            if Date().timeIntervalSince(last) > 30 {
                lastPairAttempt[udid] = Date()
                _ = lib.pair?(dev)
            }
            d.problem = "Unlock the device and tap Trust in the \"Trust This Computer?\" alert."
            return d
        }
        let validated = lib.validatePairing(dev)
        guard validated == 0 else {
            d.problem = Self.describe(validated)
            return d
        }
        let session = lib.startSession(dev)
        guard session == 0 else {
            d.problem = Self.describe(session)
            return d
        }
        defer { _ = lib.stopSession(dev) }
        fill()

        if let b = lib.dictionary(dev, domain: "com.apple.mobile.battery") {
            d.lockdownPercent = asInt(b["BatteryCurrentCapacity"])
        }

        var conn: MobileDeviceLib.Conn?
        let started = lib.startService(dev, "com.apple.mobile.diagnostics_relay" as CFString, nil, &conn)
        guard started == 0, let conn else {
            d.problem = "The diagnostics service did not start (\(Self.hex(started))). Unlock the device and try again."
            return d
        }
        defer {
            _ = lib.request(conn, ["Request": "Goodbye"])
            lib.invalidate(conn)
        }

        func registry(_ entry: [String: String]) -> [String: Any]? {
            var req: [String: Any] = ["Request": "IORegistry"]
            entry.forEach { req[$0.key] = $0.value }
            guard let resp = lib.request(conn, req), (resp["Status"] as? String) == "Success",
                  let diag = resp["Diagnostics"] as? [String: Any],
                  let reg = diag["IORegistry"] as? [String: Any], !reg.isEmpty else { return nil }
            return reg
        }

        // Newer iOS answers to the class name; older releases only to the entry name.
        let top = registry(["EntryClass": "AppleSmartBattery"])
            ?? registry(["EntryName": "AppleSmartBattery"])
            ?? registry(["EntryClass": "IOPMPowerSource"])
        let pack = registry(["EntryClass": "AppleSmartBatteryPack"])
        let bank = registry(["EntryClass": "AppleSmartBatteryBank"])

        if let top {
            d.battery = BatteryInfo(top: top, pack: pack, banks: bank.map { [$0] } ?? [])
        }
        if d.battery == nil {
            d.problem = "The device returned no battery data. Unlock it and try again."
        }

        if d.modelName == nil, let product = registry(["EntryName": "product"]),
           let data = product["product-name"] as? Data,
           let name = String(data: data.prefix { $0 != 0 }, encoding: .utf8), !name.isEmpty {
            modelNames[udid] = name
            d.modelName = name
        }
        return d
    }

    private static func hex(_ code: Int32) -> String {
        "0x" + String(UInt32(bitPattern: code), radix: 16)
    }

    private static func describe(_ code: Int32) -> String {
        switch UInt32(bitPattern: code) {
        case 0xE800001A:
            return "The device is locked with a passcode. Unlock it to read the battery."
        case 0xE8000095:
            return "Confirm Trust on the device screen."
        case 0xE8000096:
            return "The device declined to trust this Mac. Reconnect the cable and tap Trust."
        default:
            return "The device is unavailable (\(hex(code))). Unlock it or reconnect the cable."
        }
    }
}
