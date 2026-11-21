import Foundation
import Darwin

public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    /// Busy share between two samples, 0...1.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Double {
        let busy = Double((b.user &- a.user) &+ (b.system &- a.system) &+ (b.nice &- a.nice))
        let total = busy + Double(b.idle &- a.idle)
        return total > 0 ? min(max(busy / total, 0), 1) : 0
    }
}

public struct MemoryStats: Equatable, Sendable {
    public var total: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64

    public init(total: UInt64, free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64,
                compressed: UInt64, purgeable: UInt64, external: UInt64) {
        self.total = total; self.free = free; self.active = active; self.inactive = inactive
        self.wired = wired; self.compressed = compressed; self.purgeable = purgeable; self.external = external
    }

    /// "App memory + wired + compressed", like Activity Monitor's "Memory Used".
    public var used: UInt64 {
        let app = active + inactive > purgeable + external ? active + inactive - purgeable - external : 0
        return min(app + wired + compressed, total)
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public enum Pressure: String, Sendable { case normal, warning, critical }

    /// Rough pressure: what would be left if file cache (inactive/purgeable) were dropped.
    public var pressure: Pressure {
        let available = Double(free + inactive + purgeable) / Double(max(total, 1))
        let compressedShare = Double(compressed) / Double(max(total, 1))
        if available < 0.05 || compressedShare > 0.35 { return .critical }
        if available < 0.15 || compressedShare > 0.2 { return .warning }
        return .normal
    }
}

public struct DiskStats: Equatable, Sendable {
    public var total: Int64
    public var available: Int64

    /// Free space not counting what macOS could purge (caches, local snapshots). nil when unknown.
    public var strictlyFree: Int64?

    public init(total: Int64, available: Int64, strictlyFree: Int64? = nil) {
        self.total = total; self.available = available; self.strictlyFree = strictlyFree
    }

    /// Space macOS reports as available but only frees on demand (purgeable caches, local Time Machine snapshots).
    public var purgeable: Int64 { strictlyFree.map { max(available - $0, 0) } ?? 0 }
    public var used: Int64 { total - available }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct ProcessUsage: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let cpu: Double
    public let memoryBytes: UInt64
    public let name: String
}

public struct NetworkCounters: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64
}

public enum SystemMonitor {
    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    public static func memory() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return MemoryStats(total: ProcessInfo.processInfo.physicalMemory,
                           free: UInt64(stats.free_count) * page,
                           active: UInt64(stats.active_count) * page,
                           inactive: UInt64(stats.inactive_count) * page,
                           wired: UInt64(stats.wire_count) * page,
                           compressed: UInt64(stats.compressor_page_count) * page,
                           purgeable: UInt64(stats.purgeable_count) * page,
                           external: UInt64(stats.external_page_count) * page)
    }

    public static func disk(_ volume: URL = URL(fileURLWithPath: "/")) -> DiskStats? {
        guard let v = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                           .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskStats(total: Int64(total), available: avail, strictlyFree: v.volumeAvailableCapacity.map(Int64.init))
    }

    /// Bytes in/out over all non-loopback interfaces since boot.
    public static func network() -> NetworkCounters {
        var counters = NetworkCounters(received: 0, sent: 0)
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return counters }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                counters.received += UInt64(data.pointee.ifi_ibytes)
                counters.sent += UInt64(data.pointee.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        return counters
    }

    /// Parses `ps -Aceo pid=,pcpu=,rss=,comm=` output (rss in KB).
    public static func parseProcesses(_ output: String) -> [ProcessUsage] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, let pid = Int32(cols[0]),
                  let cpu = Double(cols[1].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(cols[2]) else { return nil }
            return ProcessUsage(pid: pid, cpu: cpu, memoryBytes: rss * 1024, name: String(cols[3]))
        }
    }

    public static func topProcesses(limit: Int = 5, byMemory: Bool = false, runner: CommandRunning = ProcessRunner()) -> [ProcessUsage] {
        let all = parseProcesses(runner.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="]).output)
        let sorted = byMemory ? all.sorted { $0.memoryBytes > $1.memoryBytes } : all.sorted { $0.cpu > $1.cpu }
        return Array(sorted.prefix(limit))
    }
}
