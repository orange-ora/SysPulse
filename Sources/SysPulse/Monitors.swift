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
    /// 本机是否**确认**拿不到 GPU 计数器（见 `GPUMonitor.unavailable`）。
    /// 用来把「数据还没到位」和「本机永远没有」分开——两者的宽度记账处置相反。
    var gpuUnavailable: Bool = false

    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryFraction: Double = 0
    var swapUsed: UInt64 = 0

    var downSpeed: Double = 0
    var upSpeed: Double = 0
    /// 本次运行期间累计（内核只提供 32 位计数器，无法还原开机以来的真实总量）
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0

    /// GPU 是否**有计数器可用**。宽度记账用它判断"要不要因为 GPU 段缺失而重量三档宽度"，
    /// 不能改用 `gpuUsage != nil` —— 节流跳采时那个值会被沿用，分不出"没采"和"采了没值"。
    var gpuAvailable: Bool = true

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

    /// 复用的 sysctl 缓冲与接口名缓存。
    ///
    /// 为什么要有：`NetworkMonitor.sample` 原本每拍做两件事都很浪费 ——
    /// ① 每拍 `[UInt8](repeating: 0, count: length)` 新分配一块（几 KB）缓冲，用完就扔；
    /// ② 对表里**每一个**接口都调一次 `if_indextoname` 并造一个 `String`，
    ///    只为判断它是不是 `en*`，而实际上真正要统计的只有 1~2 个。
    /// 实测 `NetworkMonitor.sample` 410µs/次（2026-09-30，占空闲基线约 25%）。
    ///
    /// 改成：缓冲留作实例属性按需增长复用；接口名按 index 缓存（接口 index 在进程生命周期内
    /// 不会重编号，但插拔网卡会新增 index，所以是缓存而不是一次性快照）。
    ///
    /// ⚠️ 尺寸缓存必须**允许增长**：两次 `sysctl` 之间接口表一旦变大（VPN 连断、插拔 USB 网卡、
    /// iPhone 共享网络），旧尺寸会直接 ENOMEM。所以失败且 `length` 变大时就重分配再试一次，
    /// 而不是把旧缓冲硬套上去。
    private var buffer: [UInt8] = []
    private var interfaceNameCache: [UInt16: String] = [:]

    /// 读一次所有 `en*` 的累计收发字节。
    ///
    /// ⚠️ **返回 nil 表示「这一拍没读到」，绝不能用 `(0, 0)` 冒充读数。**
    /// 因为 0 一定小于上一次的值，会被 `delta` 判成「32 位计数器回绕」而走补偿分支，
    /// 凭空算出一个 0~4 GiB 的差分（实测：上次 5 GB → 幻影 3.34 GiB；2 秒刷新周期下
    /// 折合 **1795 MB/s** 的假读数），而且 `sample()` 里的 `&+=` 会把这笔幻影字节数
    /// **永久**累加进「本次运行流量」——错了不会自愈。
    ///
    /// 什么时候会失败：第二次 `sysctl` 的缓冲区长度取自第一次调用，两次之间接口表
    /// 一旦增长（VPN 连接/断开、插拔 USB 网卡、iPhone 共享网络）就会 ENOMEM。
    /// 下面失败后重试一次正是为了吃掉这种情况。
    private func counters() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length: size_t = buffer.count

        if length == 0 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) >= 0, length > 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: length)
        }

        if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) < 0 {
            // 尺寸不够（接口表变大了）：按新尺寸重分配再试一次
            guard length > buffer.count else { return nil }
            buffer = [UInt8](repeating: 0, count: length)
            guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) >= 0 else { return nil }
        }

        var rx: UInt64 = 0
        var tx: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= Int(length) {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    // 只有 `en*` 才计入。接口名按 index 缓存 —— 原来对表里每个接口
                    // 都调一次 if_indextoname 并造 String，而绝大多数都不是 en*。
                    if let name = interfaceName(header.ifm_index), name.hasPrefix("en") {
                        let message = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                        rx += UInt64(message.ifm_data.ifi_ibytes)
                        tx += UInt64(message.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }

        return (rx, tx)
    }

    private func interfaceName(_ index: UInt16) -> String? {
        if let cached = interfaceNameCache[index] { return cached }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        let resolved = String(cString: name)
        interfaceNameCache[index] = resolved
        return resolved
    }

    func sample() {
        // 读不到就**整拍作废**：既不更新 downSpeed / upSpeed，也不更新 `last`。
        // 不更新 `last` 是关键——下一拍成功时 elapsed 覆盖的是这整段间隔，
        // 差分除以真实间隔仍然是正确均值，不会因为漏了一拍就把速率算飞。
        guard let current = counters() else { return }
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

    /// 本机是否**确认**拿不到 GPU 计数器（虚拟机、部分 Intel 核显机型等）。
    ///
    /// 必须把两种 `utilization == nil` 分开，因为它们的正确处置**相反**：
    /// - ①「刚启动、数据还没到位」—— 只是这几拍没有。此时**绝不能**记账宽度：
    ///   缺了 GPU 段渲出来的宽度偏小（实测单行档 159pt vs 真实 213pt），
    ///   拿它当升档依据会算出「装得下」，把宽档升到一个其实放不下的位置，
    ///   窗口落进刘海折叠区、完全不绘制（README.dev.md bug 6 实测 9.93 秒看不见图标）。
    /// - ②「该机型根本没有」—— 永远不会有。此时**必须**照常记账：
    ///   否则 `StatusItemController.widthIsTrustworthy` 永远为 false，
    ///   三档宽度恒为 0 → `gain = 0 - 0 = 0` → 升档判据 `gain > 0` 永不成立，
    ///   自动适应会**只能降档、永远升不回去**（症状与 README.dev.md bug 2「gain 写反」一模一样）。
    ///
    /// 判据：连续 `unavailableAfterMisses` 拍都没能枚举到任何带
    /// `PerformanceStatistics` 的 IOAccelerator 服务。真机上 IOAccelerator
    /// 从开机就存在（哪怕利用率是 0），所以正常机器第一拍就会把它清掉；
    /// 用「连续几拍」而不是「一拍」是为了躲开启动瞬间 IORegistry 尚未就绪的情况。
    private(set) var unavailable = false
    private var misses = 0
    private let unavailableAfterMisses = 3

    /// 本机是否**拿到了** GPU 计数器（= `unavailable` 的反面，含"数据还没到位"）。
    ///
    /// 宽度记账用的是这个、而不是 `snapshot.gpuUsage != nil`：**采集节流之后**
    /// 跳过的那些拍会沿用上一次的 `utilization`，于是"这一拍没采"和"这一拍采了但没有值"
    /// 在快照上看起来一样，`gpuUsage != nil` 就分不出来了。而 GPU 可用性一变，
    /// 三档宽度必须重量 —— 漏掉就会一直用着缺 GPU 段时量到的偏小值（README.dev.md bug 6）。
    var available: Bool { !unavailable }

    func sample() {
        // 无论从哪条路径离开都要更新「连续未命中」计数（含下面两个 early return）
        var sawStatistics = false
        defer {
            if sawStatistics {
                misses = 0
                unavailable = false      // 一旦真的读到，就不再是「不可用」
            } else {
                misses += 1
                if misses >= unavailableAfterMisses { unavailable = true }
            }
        }

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

            // 见到任何一个带 PerformanceStatistics 的 IOAccelerator，就说明
            // 这台机器有 GPU 计数器（哪怕这一拍恰好没有可用的利用率字段）
            sawStatistics = true

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
