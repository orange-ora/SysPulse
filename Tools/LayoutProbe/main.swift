// 排版探针：用真实源码量出三档菜单栏图片的宽度，核对 README 里写的数值。
//
//   swiftc -O -framework IOKit -framework AppKit -framework SwiftUI \
//       -o build/LayoutProbe \
//       Sources/SysPulse/{Monitors,Formatting,Preferences,MenuBarImage,StatusItemController,LaunchAtLogin,SystemMonitor}.swift \
//       Tools/LayoutProbe/main.swift
//
// 注意：StatusItemController.swift 里持有 NSPopover / NSStatusItem，这里只是把它作为
// 依赖编进来（MenuBarImage 引用它的 tint(for:)），不会实例化。

import AppKit
import Foundation

/// 造一个"最宽"的指标快照：速度占满 4 位、百分比都是 100，
/// 这样量到的就是该档位在真实使用中的上限宽度。
func widestSnapshot() -> MetricsSnapshot {
    var s = MetricsSnapshot()
    s.cpuUsage = 1.0
    s.gpuUsage = 100.0
    s.memoryFraction = 1.0
    s.downSpeed = 999_000_000
    s.upSpeed = 999_000_000
    return s
}

/// 造一个"最窄"的快照：全部读数为 0，用来确认宽度不随数值变化。
func narrowestSnapshot() -> MetricsSnapshot {
    var s = MetricsSnapshot()
    s.downSpeed = 0
    s.upSpeed = 0
    return s
}

let prefs = Preferences.shared
let densityNames: [(String, MenuBarDensity, String)] = [
    ("full  单行", .full, "≈215pt"),
    ("compact 两行", .compact, "≈110pt"),
    ("minimal 极简", .minimal, "≈80pt"),
]

print("=== 三档排版实测宽度（四项指标全开）===")
for (name, density, docWidth) in densityNames {
    let wide = MenuBarImage.render(
        snapshot: widestSnapshot(), preferences: prefs,
        appearance: nil, density: density
    )?.size
    let narrow = MenuBarImage.render(
        snapshot: narrowestSnapshot(), preferences: prefs,
        appearance: nil, density: density
    )?.size
    let w = wide.map { String(format: "%.1f", $0.width) } ?? "--"
    let h = wide.map { String(format: "%.1f", $0.height) } ?? "--"
    let nw = narrow.map { String(format: "%.1f", $0.width) } ?? "--"
    print("\(name): README 写 \(docWidth) → 实测 最宽 \(w)pt x \(h)pt，全零 \(nw)pt")
}

print()
print("=== 宽度稳定性（同一档位，读数全零 vs 全满）===")
for (name, density, _) in densityNames {
    let a = MenuBarImage.render(snapshot: widestSnapshot(), preferences: prefs, appearance: nil, density: density)?.size.width ?? -1
    let b = MenuBarImage.render(snapshot: narrowestSnapshot(), preferences: prefs, appearance: nil, density: density)?.size.width ?? -1
    print("\(name): 差 \(String(format: "%.4f", abs(a - b)))pt \(abs(a - b) < 0.01 ? "✓ 稳定" : "✗ 会跳动")")
}

print()
print("=== 变色阈值（README: ≥80% 橙, ≥92% 红）===")
for pct in [0, 50, 79, 79.9, 80, 91, 91.9, 92, 100] {
    let color = StatusItemController.tint(for: Double(pct) / 100)
    let name: String
    switch color {
    case .systemOrange: name = "橙"
    case .systemRed: name = "红"
    case .labelColor: name = "主色"
    default: name = "其他(\(color))"
    }
    print("  \(pct)% → \(name)")
}

print()
print("=== 单项指标关闭时的宽度（compact 两行）===")
let combos: [(String, (Preferences) -> Void)] = [
    ("全开", { _ in }),
    ("关网速", { $0.showNetwork = false }),
    ("关CPU", { $0.showCPU = false }),
    ("关内存", { $0.showMemory = false }),
    ("关GPU", { $0.showGPU = false }),
]
let saved = (prefs.showNetwork, prefs.showCPU, prefs.showMemory, prefs.showGPU)
for (label, apply) in combos {
    apply(prefs)
    let size = MenuBarImage.render(snapshot: widestSnapshot(), preferences: prefs, appearance: nil, density: .compact)?.size
    print("  \(label): \(size.map { String(format: "%.1f x %.1f", $0.width, $0.height) } ?? "--")")
}
prefs.showNetwork = saved.0
prefs.showCPU = saved.1
prefs.showMemory = saved.2
prefs.showGPU = saved.3

print()
print("=== 指标全关时的占位图标 ===")
prefs.showNetwork = false; prefs.showCPU = false; prefs.showMemory = false; prefs.showGPU = false
let placeholder = MenuBarImage.render(snapshot: widestSnapshot(), preferences: prefs, appearance: nil, density: .full)
print("  返回\(placeholder == nil ? " nil ✗（状态栏会变空白）" : " 图片 \(placeholder!.size)")")
prefs.showNetwork = saved.0
prefs.showCPU = saved.1
prefs.showMemory = saved.2
prefs.showGPU = saved.3
