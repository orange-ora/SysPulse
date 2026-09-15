import Darwin
import Foundation
import IOKit

/// 一次采样得到的全部指标。
struct MetricsSnapshot {
    var cpuUsage: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuCores: Int = 0

    var gpuUsage: Double?
    var gpuMemory: UInt64?
    /// GPU 核心数（Apple Silicon 上从 IOAccelerator 的 gpu-core-count 读）
    var gpuCores: Int?

    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryFraction: Double = 0
    var swapUsed: UInt64 = 0

    var downSpeed: Double = 0
    var upSpeed: Double = 0
    /// 本次运行期间累计（内核只提供 32 位计数器，无法还原开机以来的真实总量）
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0

    var uptime: TimeInterval = 0
    var processCount: Int = 0
    var timestamp = Date()
}

// MARK: - CPU

/// 通过 `host_processor_info` 读取每个核心的 tick 计数，做差分得到占用率。
final class CPUMonitor {
    private var previous: [UInt32] = []

    private(set) var usage: Double = 0
    private(set) var userUsage: Double = 0
    private(set) var systemUsage: Double = 0
    private(set) var cores: Int = 0

    func sample() {
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount) == KERN_SUCCESS,
              let info = cpuInfo else { return }

        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let coreCount = Int(cpuCount)
        cores = coreCount

        var ticks = [UInt32](repeating: 0, count: coreCount * 4)
        for core in 0..<coreCount {
            let base = core * Int(CPU_STATE_MAX)
            ticks[core * 4 + 0] = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            ticks[core * 4 + 1] = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            ticks[core * 4 + 2] = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            ticks[core * 4 + 3] = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        }

        defer { previous = ticks }

        guard previous.count == ticks.count else { return }

        var total = 0.0
        var user = 0.0
        var system = 0.0
        var idle = 0.0

        func delta(_ current: UInt32, _ old: UInt32) -> Double {
            Double(current >= old ? current - old : 0)
        }

        for core in 0..<coreCount {
            let u = delta(ticks[core * 4 + 0], previous[core * 4 + 0])
            let s = delta(ticks[core * 4 + 1], previous[core * 4 + 1])
            let i = delta(ticks[core * 4 + 2], previous[core * 4 + 2])
            let n = delta(ticks[core * 4 + 3], previous[core * 4 + 3])
            user += u + n
            system += s
            idle += i
            total += u + s + i + n
        }

        guard total > 0 else { return }
        usage = (total - idle) / total
        userUsage = user / total
        systemUsage = system / total
    }
}

// MARK: - 内存

/// 读取 Mach VM 统计，按「活跃 + 联动 + 压缩」估算已用内存（与活动监视器口径接近）。
final class MemoryMonitor {
    private let pageSize = UInt64(vm_kernel_page_size)

    private(set) var used: UInt64 = 0
    private(set) var total: UInt64 = 0
    private(set) var swapUsed: UInt64 = 0

    func sample() {
        total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let active = UInt64(stats.active_count) * pageSize
            let wired = UInt64(stats.wire_count) * pageSize
            let compressed = UInt64(stats.compressor_page_count) * pageSize
            used = active + wired + compressed
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        if sysctl(&mib, 2, &swap, &size, nil, 0) == 0 {
            swapUsed = swap.xsu_used
        }
    }
}

// MARK: - 网络

/// 通过 `NET_RT_IFLIST2` 读取网卡计数器并做差分。
/// 只统计物理接口（en*），避免 lo0 / utun（VPN）/ awdl 造成重复计数。
///
/// 注意：macOS 在这里给出的字节计数器实际会按 2³² 回绕（用 `netstat -ib` 对比即可发现，
/// 下行的 `ifi_ibytes` 只是真实值的低 32 位），所以差分必须做回绕处理，
/// 累计流量也只能由我们自己逐次累加。
final class NetworkMonitor {
    private struct Counters {
        let rx: UInt64
        let tx: UInt64
        let time: TimeInterval
    }

    private var last: Counters?

    private(set) var downSpeed: Double = 0
    private(set) var upSpeed: Double = 0
    private(set) var totalDown: UInt64 = 0
    private(set) var totalUp: UInt64 = 0

    private static let mask: UInt64 = 0xFFFF_FFFF

    /// 32 位计数器回绕安全的差分；对真正的 64 位计数器同样适用。
    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return (mask - (previous & mask)) + (current & mask) + 1
    }

    private static func counters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) >= 0, length > 0 else { return (0, 0) }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) >= 0 else { return (0, 0) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= Int(length) {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   let name = NetworkMonitor.interfaceName(header.ifm_index),
                   name.hasPrefix("en") {
                    let message = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    rx += UInt64(message.ifm_data.ifi_ibytes)
                    tx += UInt64(message.ifm_data.ifi_obytes)
                }
                offset += messageLength
            }
        }

        return (rx, tx)
    }

    private static func interfaceName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(cString: name)
    }

    func sample() {
        let current = NetworkMonitor.counters()
        let now = Date().timeIntervalSinceReferenceDate

        if let last {
            let elapsed = now - last.time
            if elapsed > 0.05 {
                let received = NetworkMonitor.delta(current.rx, last.rx)
                let sent = NetworkMonitor.delta(current.tx, last.tx)
                downSpeed = Double(received) / elapsed
                upSpeed = Double(sent) / elapsed
                totalDown &+= received
                totalUp &+= sent
            }
        }

        last = Counters(rx: current.rx, tx: current.tx, time: now)
    }
}

// MARK: - GPU

/// 从 IOKit 的 `IOAccelerator` 服务读取 `PerformanceStatistics`。
/// Apple Silicon 上关键字段为 `Device Utilization %`。
final class GPUMonitor {
    private(set) var utilization: Double?
    /// GPU 正在使用的统一内存（Apple Silicon 没有独立显存）
    private(set) var memoryInUse: UInt64?
    private(set) var cores: Int?

    func sample() {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            utilization = nil
            memoryInUse = nil
            return
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            utilization = nil
            memoryInUse = nil
            return
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var bestMemory: UInt64?
        var bestCores: Int?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any] else { continue }

            if let count = dictionary["gpu-core-count"] as? Int {
                bestCores = max(bestCores ?? 0, count)
            }

            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %", "Tiler Utilization %"] {
                if let value = statistics[key] as? Int {
                    best = max(best ?? 0, Double(value))
                    break
                }
                if let value = statistics[key] as? Double {
                    best = max(best ?? 0, value)
                    break
                }
            }

            for key in ["In use system memory", "Alloc system memory", "vramUsedBytes"] {
                if let value = statistics[key] as? Int, value > 0 {
                    bestMemory = max(bestMemory ?? 0, UInt64(value))
                    break
                }
                if let value = statistics[key] as? Int64, value > 0 {
                    bestMemory = max(bestMemory ?? 0, UInt64(value))
                    break
                }
            }
        }

        utilization = best
        memoryInUse = bestMemory
        cores = bestCores
    }
}

// MARK: - 进程数

enum ProcessMonitor {
    static func count() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return 0 }
        return size / MemoryLayout<kinfo_proc>.stride
    }
}
