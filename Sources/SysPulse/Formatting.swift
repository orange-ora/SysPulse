import Foundation

/// 统一的数字 / 容量 / 速度格式化工具。
enum Format {
    private static let units = ["B", "K", "M", "G", "T", "P"]

    /// 把字节数拆成 (数值, 单位) 的形式。
    private static func scaled(_ value: Double) -> (value: Double, unit: String) {
        var v = max(value, 0)
        var index = 0
        while v >= 1000, index < units.count - 1 {
            v /= 1000
            index += 1
        }
        return (v, units[index])
    }

    /// 容量：`1.2 GB`
    static func bytes(_ value: Double) -> String {
        let (v, unit) = scaled(value)
        if unit == "B" { return String(format: "%.0f B", v) }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, unit)
    }

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    /// 速度：`1.2 MB/s`
    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// 状态栏用的紧凑速度：`1.2M`
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let (v, unit) = scaled(bytesPerSecond)
        if unit == "B" { return String(format: "%.0fB", v) }
        return String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, unit)
    }

    /// 百分比：`63%`
    static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        let clamped = min(max(fraction, 0), 1)
        return String(format: "%.\(decimals)f%%", clamped * 100)
    }

    /// 运行时长：`3 天 4 小时`
    static func uptime(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}
