import Combine
import Foundation

/// 采样调度 + 历史曲线缓存。
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var snapshot = MetricsSnapshot()
    @Published private(set) var deviceInformation = DeviceInformation.fallback()
    @Published private(set) var cpuHistory: [Double]
    @Published private(set) var gpuHistory: [Double]
    @Published private(set) var memoryHistory: [Double]
    @Published private(set) var downHistory: [Double]
    @Published private(set) var upHistory: [Double]

    private let cpu = CPUMonitor()
    private let gpu = GPUMonitor()
    private let memory = MemoryMonitor()
    private let network = NetworkMonitor()

    private var timer: Timer?
    private var tick = 0

    /// GPU 采集的节流周期（拍）。**`GPUMonitor.sample` 实测 961.6µs/次，是全部采样操作里最贵的一项**
    /// （2026-09-30 基准：CPU 11.3µs / 内存 1.4µs / 网络 410µs / 进程数 13.8µs / 渲染 9.7µs）。
    /// 原因是它每次都要 `IOServiceGetMatchingServices` 枚举 IOAccelerator 并对每个服务
    /// `IORegistryEntryCreateCFProperties`（会把整个属性字典建出来，我们只读其中两三个键）。
    ///
    /// GPU 利用率本来也不会秒级突变，而且**渲染出来的百分比是取整的**
    /// （`MenuBarImage` 里 `Int(value * 100)`），所以隔几拍取一次几乎看不出来。
    /// 空闲时它占基线约 48%（961.6µs × 0.5 拍/秒 ≈ 0.48ms/秒），节流到每 4 拍一次
    /// 就降到约 12%，而 GPU 读数最多滞后 8 秒（2 秒刷新时）。
    ///
    /// ⚠️ 跳过的拍**完全不调用 `gpu.sample()`**（不是调用后忽略结果）：`GPUMonitor` 的
    /// `unavailable` 判定数的是"连续几拍没读到"，如果照常调用就还是每拍都扫，
    /// 节流就白做了。见 `GPUMonitor.unavailable` 的注释。
    private let gpuSampleEveryTicks = 4

    init() {
        let zeros = [Double](repeating: 0, count: SystemMonitor.historyLength)
        cpuHistory = zeros
        gpuHistory = zeros
        memoryHistory = zeros
        downHistory = zeros
        upHistory = zeros
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let information = DeviceInformation.load()
            DispatchQueue.main.async { [weak self] in
                self?.deviceInformation = information
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 生命周期

    func start() {
        sampleOnce()
        // 网速需要两次采样才能算出差分，启动后补一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.sampleOnce()
        }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = max(Preferences.shared.refreshInterval, 0.25)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleOnce()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - 采样

    func sampleOnce() {
        cpu.sample()
        // GPU 按周期节流（见 gpuSampleEveryTicks 的注释）。跳过的拍沿用上一次读数，
        // 所以 `gpu.utilization` / `unavailable` 这两个状态量保持上一次的值不变。
        // tick从0起，第一拍就尝试GPU采样；读数未就绪时由状态栏宽度保护禁用升级。
        if tick % gpuSampleEveryTicks == 0 { gpu.sample() }
        memory.sample()
        network.sample()
        tick += 1

        var next = MetricsSnapshot()
        next.cpuUsage = cpu.usage
        next.cpuUser = cpu.userUsage
        next.cpuSystem = cpu.systemUsage
        next.cpuCores = cpu.cores
        next.gpuUsage = gpu.utilization
        next.gpuMemory = gpu.memoryInUse
        next.gpuCores = gpu.cores
        next.gpuUnavailable = gpu.unavailable
        next.gpuAvailable = gpu.available
        next.memoryUsed = memory.used
        next.memoryTotal = memory.total
        next.memoryFraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
        next.memoryPressure = memory.pressure
        next.swapUsed = memory.swapUsed
        next.downSpeed = network.downSpeed
        next.upSpeed = network.upSpeed
        next.totalDown = network.totalDown
        next.totalUp = network.totalUp
        next.uptime = ProcessInfo.processInfo.systemUptime
        next.processCount = tick % 5 == 1 ? ProcessMonitor.count() : snapshot.processCount
        next.timestamp = Date()

        snapshot = next
        cpuHistory = push(cpuHistory, next.cpuUsage)
        gpuHistory = push(gpuHistory, (next.gpuUsage ?? 0) / 100)
        memoryHistory = push(memoryHistory, next.memoryFraction)
        downHistory = push(downHistory, next.downSpeed)
        upHistory = push(upHistory, next.upSpeed)
    }

    private func push(_ history: [Double], _ value: Double) -> [Double] {
        var next = history
        next.append(value)
        if next.count > SystemMonitor.historyLength {
            next.removeFirst(next.count - SystemMonitor.historyLength)
        }
        return next
    }
}
