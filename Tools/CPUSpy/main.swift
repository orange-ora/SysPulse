import Darwin
import Foundation

// 测量指定进程的 CPU 占用（100% = 一个核心满载）
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("用法: CPUSpy <pid> [秒数]"); exit(1)
}
let seconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 5) : 5

func usage(_ pid: Int32) -> (user: UInt64, sys: UInt64, rss: UInt64)? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
    guard rc == size else { return nil }
    return (info.pti_total_user, info.pti_total_system, info.pti_resident_size)
}

guard let first = usage(pid) else { print("无法读取进程 \(pid) 的统计信息"); exit(1) }
Thread.sleep(forTimeInterval: seconds)
guard let second = usage(pid) else { print("读取失败"); exit(1) }

let userDelta = Double(second.user &- first.user) / 1_000_000_000
let sysDelta = Double(second.sys &- first.sys) / 1_000_000_000
let cpu = (userDelta + sysDelta) / seconds * 100
print(String(format: "进程 %d 在 %.0f 秒内平均 CPU 占用: %.2f%%   常驻内存: %.1f MB",
             pid, seconds, cpu, Double(second.rss) / 1_048_576))
