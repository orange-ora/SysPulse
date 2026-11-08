import Foundation

/// 统一的数字 / 容量 / 速度格式化工具。
enum Format {
    private static let units = ["B", "K", "M", "G", "T", "P"]

    /// 容量进位：1024（`1 GB = 1024³ B`）。
    ///
    /// 内存、交换、显存都走这一档，所以 16 GiB 的机器显示 `16 G`，和「关于本机」
    /// 「活动监视器」里用户看到的 16 GB 对得上。单位字面仍写 `GB`，不引入 `GiB`。
    private static let capacityStep: Double = 1024

    /// 速度进位：1000（`1 MB/s = 10⁶ B/s`），与网络带宽的十进制习惯一致。
    /// 菜单栏槽位宽度是按这套数值实测的，不要改成 1024。
    private static let speedStep: Double = 1000

    /// 把字节数拆成 (数值, 单位) 的形式。
    private static func scaled(_ value: Double, step: Double) -> (value: Double, unit: String) {
        var v = max(value, 0)
        var index = 0
        while v >= step, index < units.count - 1 {
            v /= step
            index += 1
        }
        return (v, units[index])
    }

    /// 容量：`1.2 GB`（1024 进位）
    static func bytes(_ value: Double) -> String {
        let (v, unit) = scaled(value, step: capacityStep)
        if unit == "B" { return String(format: "%.0f B", v) }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, unit)
    }

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    /// 速度：`1.2 MB/s`（1000 进位）
    static func speed(_ bytesPerSecond: Double) -> String {
        let (v, unit) = scaled(bytesPerSecond, step: speedStep)
        if unit == "B" { return String(format: "%.0f B/s", v) }
        return String(format: v < 10 ? "%.1f %@/s" : "%.0f %@/s", v, unit)
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
        var (v, unit) = scaled(bytesPerSecond, step: speedStep)
        if v >= 999.5, let index = units.firstIndex(of: unit), index < units.count - 1 {
            v /= speedStep
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
