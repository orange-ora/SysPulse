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
    ///
    /// ⚠️ **必须保证输出不超过 4 个字形**（`1.2M` / `66M` 这一档）。
    ///
    /// 原因：菜单栏给网速段预留的槽位就是按 `↓888M`（4 字形）量的宽度
    /// （`MenuBarImage.buildRows` 的 `speedSlot`），而各段之间**只隔一个空格**。
    /// 字号 11.5 实测：槽位 `↓888M` = 41.74pt，空格 = 3.17pt，而
    /// `↓10.0M` = 45.40pt、`↓1000K` = 46.79pt、`↓1000M` = 49.19pt ——
    /// 溢出 3.66~7.45pt，**比空格还宽**，渲染出来会和后面的 `CPU` 字形相碰
    /// （实测：`↓10.0MCPU 30`，间隔完全消失）。
    ///
    /// 所以这里两件事一起做：
    /// 1. 到 `999.5` 就**提前进一位**（避免吐出 `1000K` 这种 5 字形）；
    /// 2. 到 `9.95` 就**不再保留小数**（避免吐出 `10.0M` 这种 5 字形）。
    ///
    /// 两个阈值合起来保证任意单位的整数部分最多 3 位。唯一的例外是单位表顶端
    /// （`P`，10¹⁵ 量级）无法再进位 —— 那需要 10¹⁸ B/s，物理上不可达。
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        var (v, unit) = scaled(bytesPerSecond)
        if v >= 999.5, let index = units.firstIndex(of: unit), index < units.count - 1 {
            v /= 1000
            unit = units[index + 1]
        }
        if unit == "B" { return String(format: "%.0fB", v) }
        return String(format: v < 9.95 ? "%.1f%@" : "%.0f%@", v, unit)
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
