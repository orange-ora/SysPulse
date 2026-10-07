import Foundation

/// 命令行自检模式：采样两次后打印所有指标，便于验证数据源是否可用。
enum DumpMode {
    static func run() {
        let monitor = SystemMonitor()
        monitor.sampleOnce()

        // 间隔 1 秒再采一次，让 CPU / 网络差分有意义。
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        monitor.sampleOnce()

        let snapshot = monitor.snapshot
        print("=== SysPulse 指标自检 ===")
        print("CPU         : \(Format.percent(snapshot.cpuUsage, decimals: 1))  (用户 \(Format.percent(snapshot.cpuUser, decimals: 1)) / 系统 \(Format.percent(snapshot.cpuSystem, decimals: 1)), \(snapshot.cpuCores) 核)")
        if let gpu = snapshot.gpuUsage {
            print("GPU         : \(Format.percent(gpu / 100, decimals: 1))" + (snapshot.gpuMemory.map { "  显存 \(Format.bytes($0))" } ?? ""))
        } else {
            print("GPU         : 不可用")
        }
        print("内存        : \(Format.percent(snapshot.memoryFraction, decimals: 1))  已用 \(Format.bytes(snapshot.memoryUsed)) / \(Format.bytes(snapshot.memoryTotal))  交换 \(Format.bytes(snapshot.swapUsed))")
        print("内存压力    : \(snapshot.memoryPressure.title)")
        print("网络下行    : \(Format.speed(snapshot.downSpeed))")
        print("网络上行    : \(Format.speed(snapshot.upSpeed))")
        print("本次运行流量: 接收 \(Format.bytes(snapshot.totalDown)) / 发送 \(Format.bytes(snapshot.totalUp))")
        print("运行时长    : \(Format.uptime(snapshot.uptime))")
        print("进程数      : \(snapshot.processCount)")
        print("状态栏预览  : ↓\(Format.compactSpeed(snapshot.downSpeed))  CPU \(Format.percent(snapshot.cpuUsage))  GPU \(snapshot.gpuUsage.map { Format.percent($0 / 100) } ?? "--")  MEM \(Format.percent(snapshot.memoryFraction))")
    }
}
