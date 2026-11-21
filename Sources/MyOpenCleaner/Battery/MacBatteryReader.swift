import Foundation
import IOKit
import IOKit.ps

struct MacSystemInfo {
    var computerName: String
    var modelID: String
    var marketingName: String?
    var chip: String?
    var serial: String?
    var osVersion: String

    var title: String { marketingName ?? modelID }

    /// Model year parsed from names like "MacBook Pro (16-inch, 2021)".
    var modelYear: Int? {
        guard let name = marketingName,
              let r = name.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(name[r])
    }
}

enum MacBatteryReader {
    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let top = properties(service) else { return nil }
        if let installed = top["BatteryInstalled"] as? NSNumber, !installed.boolValue { return nil }

        // macOS keeps temperature, lifetime stats and the manufacture date on
        // the pack child, and per-cell voltages on the bank grandchildren.
        var pack: [String: Any]?
        var banks: [[String: Any]] = []
        for child in children(of: service) {
            defer { IOObjectRelease(child) }
            guard className(child) == "AppleSmartBatteryPack" else { continue }
            pack = properties(child)
            for bank in children(of: child) {
                defer { IOObjectRelease(bank) }
                if className(bank) == "AppleSmartBatteryBank", let p = properties(bank) { banks.append(p) }
            }
        }

        guard var info = BatteryInfo(top: top, pack: pack, banks: banks) else { return nil }
        applyPowerSourceInfo(&info)
        return info
    }

    private static func applyPowerSourceInfo(_ info: inout BatteryInfo) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let health = d[kIOPSBatteryHealthKey] as? String
            let cond = d[kIOPSBatteryHealthConditionKey] as? String
            if let reported = cond ?? health { info.condition = reported }
            let key = info.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let m = asInt(d[key]), m > 0 {
                info.minutesRemaining = m
            } else if info.externalConnected && !info.isCharging {
                info.minutesRemaining = nil
            }
        }
    }

    static func systemInfo() -> MacSystemInfo {
        var marketing: String?
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            if let d = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data {
                marketing = String(data: d.prefix { $0 != 0 }, encoding: .utf8)
            }
            IOObjectRelease(product)
        }
        var serial: String?
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            serial = IORegistryEntryCreateCFProperty(expert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            IOObjectRelease(expert)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        return MacSystemInfo(
            computerName: Host.current().localizedName ?? "Mac",
            modelID: sysctl("hw.model") ?? "Mac",
            marketingName: marketing,
            chip: sysctl("machdep.cpu.brand_string"),
            serial: serial,
            osVersion: os
        )
    }

    // MARK: - IOKit helpers

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    private static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [io_registry_entry_t] = []
        while true {
            let child = IOIteratorNext(iter)
            if child == 0 { break }
            out.append(child)
        }
        return out
    }

    private static func className(_ entry: io_registry_entry_t) -> String? {
        IOObjectCopyClass(entry)?.takeRetainedValue() as String?
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
