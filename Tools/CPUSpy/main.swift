import Darwin
import Foundation

// 测量指定进程的 CPU 占用（100% = 一个核心满载）
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("用法: CPUSpy <pid> [秒数]"); exit(1)
}
let seconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 5) : 5

// ⚠️ **`proc_taskinfo` 的 `pti_total_user` / `pti_total_system` 单位是 mach absolute
// time，不是纳秒。** 必须用 `mach_timebase_info` 换算，直接除以 1e9 会少算
// `numer/denom` 倍 —— 本机实测 numer=125 denom=3，即 41.67 倍。
//
// 这个 bug 的后果（2026-09-30 发现并修正）：README.dev.md 里整张"开销实测"表都由此产生，
// 表中所有 CPU 数字都要**乘以约 41.67** 才是真实占用（例如标的 0.02% 实为 0.84%）。
// 标定方法：跑一个已知单线程满载进程，正确换算应报 ≈100%，
// 旧写法只报 2.39%（`Tools/CPUSpy` 对 `/tmp/burn` 的实测）。
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let nsPerTick = Double(timebase.numer) / Double(timebase.denom)

func usage(_ pid: Int32) -> (cpuSeconds: Double, rss: UInt64)? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
    guard rc == size else { return nil }
    let ticks = info.pti_total_user &+ info.pti_total_system
    return (Double(ticks) * nsPerTick / 1_000_000_000, info.pti_resident_size)
}

guard let first = usage(pid) else { print("无法读取进程 \(pid) 的统计信息"); exit(1) }
Thread.sleep(forTimeInterval: seconds)
guard let second = usage(pid) else { print("读取失败"); exit(1) }

let cpu = (second.cpuSeconds - first.cpuSeconds) / seconds * 100
print(String(format: "进程 %d 在 %.0f 秒内平均 CPU 占用: %.2f%%   常驻内存: %.1f MB",
             pid, seconds, cpu, Double(second.rss) / 1_048_576))

