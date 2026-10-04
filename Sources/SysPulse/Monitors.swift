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
    /// 本次运行期间可信采样的累计；不把新接口已有计数或无法恢复的暂停区间冒充流量。
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0

    /// 采样能力提示，包含尚未就绪状态；布局宽度使用实际gpuUsage段及gpuUnavailable判断。
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

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount) == KERN_SUCCESS,
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

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
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

/// 内核计数器的纯差分状态。输入身份包含 index、名字和链路地址；不使用永久名字缓存。
struct NetworkInterfaceID: Hashable {
    let index: UInt16
    let name: String
    let linkAddress: [UInt8]

    init(index: UInt16, name: String, linkAddress: [UInt8] = []) {
        self.index = index
        self.name = name
        self.linkAddress = linkAddress
    }
}

struct NetworkInterfaceCounters {
    enum Width { case automatic, bits32, bits64 }
    let received: UInt64
    let sent: UInt64
    var width: Width = .automatic
}

/// 在可观测边界内累计本次运行流量。没有读数时不调用 ingest，即保留基线。
/// 仅靠两个读数不能区分边界附近的重置与回绕，也不能恢复多次32位回绕：
/// 这里只接受≤1GiB的边界回绕候选；其余下降按重置丢弃该方向增量。
/// 超过30秒的间隔（含休眠）仅重建可能32位的方向基线；确认64位的方向继续累计。
struct NetworkAccumulator {
    private struct Baseline {
        var counters: NetworkInterfaceCounters
        var receivedIs64: Bool
        var sentIs64: Bool
    }
    private var previous: [NetworkInterfaceID: Baseline] = [:]
    private var previousTime: TimeInterval?
    private(set) var downSpeed: Double = 0
    private(set) var upSpeed: Double = 0
    private(set) var totalDown: UInt64 = 0
    private(set) var totalUp: UInt64 = 0

    static let minimumInterval: TimeInterval = 0.05
    static let maximumInterval: TimeInterval = 30
    private static let mask = UInt64(UInt32.max)
    private static let maximumWrapDelta: UInt64 = 1 << 30

    /// false 表示时间无效或过短；既不推进时间，也不推进计数基线。
    @discardableResult
    mutating func ingest(_ current: [NetworkInterfaceID: NetworkInterfaceCounters],
                         at time: TimeInterval, resetBaseline: Bool = false) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        if let oldTime = previousTime, !resetBaseline {
            let elapsed = time - oldTime
            guard elapsed.isFinite, elapsed > Self.minimumInterval else { return false }
            var received: UInt64 = 0
            var sent: UInt64 = 0
            for (identity, counters) in current {
                guard let old = previous[identity] else { continue } // 新接口只建基线
                guard counters.width == old.counters.width else { continue }
                let receivedIs64 = old.receivedIs64 || counters.received > Self.mask
                let sentIs64 = old.sentIs64 || counters.sent > Self.mask
                if elapsed <= Self.maximumInterval || receivedIs64 {
                    received = Self.add(received, Self.delta(counters.received, old.counters.received,
                                                            is64: receivedIs64, width: counters.width))
                }
                if elapsed <= Self.maximumInterval || sentIs64 {
                    sent = Self.add(sent, Self.delta(counters.sent, old.counters.sent,
                                                    is64: sentIs64, width: counters.width))
                }
            }
            downSpeed = Double(received) / elapsed
            upSpeed = Double(sent) / elapsed
            totalDown = Self.add(totalDown, received)
            totalUp = Self.add(totalUp, sent)
        } else {
            downSpeed = 0
            upSpeed = 0
        }
        // 完整替换会移除消失接口；下次同名设备接入不继承已移除的基线。
        var next: [NetworkInterfaceID: Baseline] = [:]
        for (identity, counters) in current {
            let old = previous[identity].flatMap { $0.counters.width == counters.width ? $0 : nil }
            next[identity] = Baseline(counters: counters,
                                     receivedIs64: counters.width == .bits64 || counters.received > Self.mask || old?.receivedIs64 == true,
                                     sentIs64: counters.width == .bits64 || counters.sent > Self.mask || old?.sentIs64 == true)
        }
        previous = next
        previousTime = time
        return true
    }

    private static func delta(_ current: UInt64, _ old: UInt64, is64: Bool,
                              width: NetworkInterfaceCounters.Width) -> UInt64 {
        if current >= old { return current - old }
        guard width != .bits64, !is64, old <= mask, current <= mask,
              old >= mask - maximumWrapDelta, current <= maximumWrapDelta else { return 0 }
        let wrapped = mask - old + current + 1
        return wrapped <= maximumWrapDelta ? wrapped : 0
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = a.addingReportingOverflow(b)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

/// 通过 NET_RT_IFLIST2 读取每个 en* 接口，逐接口差分后求和。
final class NetworkMonitor {
    private var accumulator = NetworkAccumulator()
    private var buffer: [UInt8] = []
    var downSpeed: Double { accumulator.downSpeed }
    var upSpeed: Double { accumulator.upSpeed }
    var totalDown: UInt64 { accumulator.totalDown }
    var totalUp: UInt64 { accumulator.totalUp }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private func counters() -> [NetworkInterfaceID: NetworkInterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length: size_t = buffer.count
        if length == 0 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
            guard length > 0 else { return [:] }
            buffer = [UInt8](repeating: 0, count: length)
        }
        // ENOMEM 返回长度不保证是新容量；失败时重新查询，不冒充0读数。
        var readSucceeded = false
        for _ in 0..<3 {
            length = buffer.count
            let result = buffer.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0)
            }
            if result == 0 { readSucceeded = true; break }
            guard errno == ENOMEM else { return nil }
            length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
            guard length > 0 else { return [:] }
            buffer = [UInt8](repeating: 0, count: length)
        }
        guard readSucceeded, length <= buffer.count else { return nil }

        return buffer.withUnsafeBytes { Self.parseCounters($0, length: length, resolveName: Self.interfaceName) }
    }

    static func parseCounters(_ raw: UnsafeRawBufferPointer, length: Int,
                              resolveName: (UInt16) -> String? = { _ in nil }) -> [NetworkInterfaceID: NetworkInterfaceCounters]? {
        guard length >= 0, length <= raw.count else { return nil }
        var result: [NetworkInterfaceID: NetworkInterfaceCounters] = [:]
        var offset = 0
        while offset < length {
            // 所有路由消息只有前4字节布局相同；NEWADDR等消息比if_msghdr短。
            guard length - offset >= 4 else { return nil }
            let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard messageLength >= 4, messageLength <= length - offset else { return nil }
            defer { offset += messageLength }
            guard Int32(raw[offset + 3]) == RTM_IFINFO2 else { continue }
            guard messageLength >= MemoryLayout<if_msghdr2>.size else { return nil }
            let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            var name: String?
            var linkAddress: [UInt8] = []
            if message.ifm_addrs & RTA_IFP != 0 {
                // 地址按RTAX位图顺序排列，跳过IFP之前的sockaddr（4字节对齐）。
                var addressOffset = offset + MemoryLayout<if_msghdr2>.size
                for bit in 0..<Int(RTAX_IFP) where message.ifm_addrs & (1 << bit) != 0 {
                    guard addressOffset < offset + messageLength else { return nil }
                    let precedingLength = Int(raw[addressOffset])
                    let paddedLength = max(4, (precedingLength + 3) & ~3)
                    guard paddedLength <= offset + messageLength - addressOffset else { return nil }
                    addressOffset += paddedLength
                }
                let remaining = offset + messageLength - addressOffset
                guard remaining >= 8 else { return nil }
                let addressLength = Int(raw[addressOffset])
                guard addressLength >= 8, addressLength <= remaining,
                      Int32(raw[addressOffset + 1]) == AF_LINK else { return nil }
                let nameLength = Int(raw[addressOffset + 5])
                let linkLength = Int(raw[addressOffset + 6])
                guard 8 + nameLength + linkLength <= addressLength else { return nil }
                let dataOffset = addressOffset + 8
                name = String(decoding: raw[dataOffset..<(dataOffset + nameLength)], as: UTF8.self)
                linkAddress = Array(raw[(dataOffset + nameLength)..<(dataOffset + nameLength + linkLength)])
            }
            // 少数服务没有链路地址。只在本拍查询，不缓存失败/旧名字；非en接口不影响其他读数。
            if name == nil || name?.isEmpty == true { name = resolveName(message.ifm_index) }
            guard let name, name.hasPrefix("en") else { continue }
            let identity = NetworkInterfaceID(index: message.ifm_index, name: name, linkAddress: linkAddress)
            result[identity] = NetworkInterfaceCounters(received: UInt64(message.ifm_data.ifi_ibytes),
                                                        sent: UInt64(message.ifm_data.ifi_obytes))
        }
        return result
    }

    private static func interfaceName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(cString: name)
    }

    func sample() {
        guard let current = counters() else { return }
        // continuous mach time单调递增且包含睡眠；长间隔由accumulator明确重建基线。
        let now = Double(mach_continuous_time()) * Self.secondsPerTick
        accumulator.ingest(current, at: now)
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
    /// 连续unavailableAfterMisses次实际采样没有支持的有效利用率字段后确认不可用；
    /// 统计字典存在但缺利用率也算未命中，避免部分Intel机型永久停在等待状态。
    /// 0%是有效读数；节流跳过的拍不改变此计数，后续恢复有效值会清除不可用状态。
    private(set) var unavailable = false
    private var misses = 0
    private let unavailableAfterMisses = 3

    /// 尚未被连续缺值确认不可用的能力提示，可能仍没有数值。
    /// 状态栏不得用available || unavailable判断完整快照（该表达式恒真）；
    /// 应按实际利用率段是否存在判断形状。节流跳采保留上一份数值及状态。
    var available: Bool { !unavailable }

    /// 读支持的百分数字段。0是有效读数；缺字段、负值或非有限值不是已就绪。
    static func readUtilization(from statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %", "Tiler Utilization %"] {
            guard let number = statistics[key] as? NSNumber else { continue }
            let value = number.doubleValue
            guard value.isFinite, value >= 0 else { continue }
            return min(value, 100)
        }
        return nil
    }

    func sample() {
        // 未命中计数覆盖所有返回路径；仅支持的利用率字段读到有效值才算就绪。
        var sawUtilization = false
        defer {
            if sawUtilization {
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

            if let value = Self.readUtilization(from: statistics) {
                sawUtilization = true
                best = max(best ?? 0, value)
            }

            if let count = dictionary["gpu-core-count"] as? Int {
                bestCores = max(bestCores ?? 0, count)
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
        // nil 缓冲查询返回的是预估容量（可能含预留槽），不是实际记录数。
        // 查询和填充之间进程可能增长；重新查询最多三次，避免在主线程无限重试。
        for _ in 0..<3 {
            var size: size_t = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return 0 }
            guard size > 0 else { return 0 }
            let stride = MemoryLayout<kinfo_proc>.stride
            var records = [kinfo_proc](repeating: kinfo_proc(), count: (size + stride - 1) / stride)
            size = records.count * stride
            let result = records.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if result == 0 { return size / stride }
            guard errno == ENOMEM else { return 0 }
        }
        return 0
    }
}
