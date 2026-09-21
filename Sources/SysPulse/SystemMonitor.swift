import Combine
import Foundation

/// 采样调度 + 历史曲线缓存。
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var snapshot = MetricsSnapshot()
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

    init() {
        let zeros = [Double](repeating: 0, count: SystemMonitor.historyLength)
        cpuHistory = zeros
        gpuHistory = zeros
        memoryHistory = zeros
        downHistory = zeros
        upHistory = zeros
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
        gpu.sample()
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
        next.memoryUsed = memory.used
        next.memoryTotal = memory.total
        next.memoryFraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
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
        gpuHistory = push(gpuHistory, next.gpuUsage ?? 0)
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
