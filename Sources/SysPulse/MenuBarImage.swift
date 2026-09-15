import AppKit
import Foundation

/// 状态栏排版方式。
enum MenuBarLayout: String, CaseIterable {
    /// 自动：优先单行显示，空间不够时逐级换用更窄的两行样式
    case auto
    /// 单行：`↓2.9M  CPU 30  GPU 60  MEM 62`，所有指标挤在一行
    case full
    /// 两行：网速 + 内存 / CPU + GPU（两行宽度接近，比三个指标挤一行窄约 40pt）
    case compact
    /// 两行极简：下行速度 + 三个不带标签的百分比
    case minimal

    var title: String {
        switch self {
        case .auto: return "自动适应"
        case .full: return "单行（全部指标）"
        case .compact: return "两行（带标签）"
        case .minimal: return "两行（极简）"
        }
    }

    var detail: String? {
        switch self {
        case .auto: return "优先单行，不够自动变窄"
        case .full: return "约 215pt 宽"
        case .compact: return "约 110pt 宽"
        case .minimal: return "约 80pt 宽"
        }
    }
}

/// 实际绘制时采用的密度档位。
enum MenuBarDensity {
    case full
    case compact
    case minimal
}

/// 把指标画成状态栏图片。
///
/// 两个要点：
/// 1. 用自绘图片而不是 `attributedTitle`，因为状态栏项一旦跨过刘海区域就完全不会绘制，
///    自绘可以精确控制宽度；
/// 2. **每一段都按"最宽可能值"预留固定宽度**（例如百分比永远占 `C100` 的宽度），
///    这样数值变化时整条读数宽度恒定，状态栏里不会左右跳动。
enum MenuBarImage {
    /// 各槽位文字的排版宽度缓存（键含字号与字重）
    private static var slotWidthCache: [String: CGFloat] = [:]

    /// 一段内容。`slot` 是预留宽度所用的"最宽形态"，nil 表示按实际文字宽度。
    private struct Segment {
        let text: String
        let color: NSColor
        let weight: NSFont.Weight
        var slot: String?
    }

    static func render(
        snapshot: MetricsSnapshot,
        preferences: Preferences,
        appearance: NSAppearance?,
        density: MenuBarDensity,
        glowPhase: Double? = nil
    ) -> NSImage? {
        let rows = buildRows(snapshot: snapshot, preferences: preferences, density: density)
        guard !rows.isEmpty else {
            // 指标全被关掉时给一个占位图标：否则状态栏项会变成一块空白，
            // 虽然还能点开面板，但根本找不到它。
            let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "SysPulse")
            symbol?.size = NSSize(width: 15, height: 15)
            symbol?.isTemplate = true     // 交给系统按菜单栏明暗着色
            return symbol
        }

        let fontSize: CGFloat
        let lineHeight: CGFloat
        switch density {
        // 字号是排版的关键参数：调大一号（+1pt）会让每段文字变宽，
        // 整条图标也跟着变宽（实测单行 213→229pt），菜单栏放不下就会被折叠。
        // 试过 +1，观感"超距"（槽位之间空得明显），所以维持原值。
        case .full: fontSize = 11.5; lineHeight = 14.5
        case .compact: fontSize = 10.5; lineHeight = 13.5
        case .minimal: fontSize = 10.0; lineHeight = 13
        }
        let spacing: CGFloat = 4
        let horizontalPadding: CGFloat = 3

        let regular = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let semibold = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)

        func font(_ weight: NSFont.Weight) -> NSFont {
            weight == .semibold ? semibold : regular
        }

        // 槽位字符串是固定的一小撮，宽度量一次就够，没必要每秒重新排版
        func textWidth(_ text: String, _ weight: NSFont.Weight) -> CGFloat {
            let key = "\(fontSize)|\(weight == .semibold ? "b" : "r")|\(text)"
            if let cached = slotWidthCache[key] { return cached }
            let width = NSAttributedString(string: text, attributes: [.font: font(weight)]).size().width
            slotWidthCache[key] = width
            return width
        }

        // 逐段排布：每段占「最宽形态」的宽度，实际文字画在段内固定起点
        var laidOut: [[(segment: Segment, x: CGFloat)]] = []
        var maxWidth: CGFloat = 0
        for row in rows {
            var x: CGFloat = 0
            var items: [(Segment, CGFloat)] = []
            for segment in row {
                items.append((segment, x))
                // 槽位宽度一定不小于实际文字，所以直接按槽位排版，不用量实际值
                let reserved = segment.slot.map { textWidth($0, segment.weight) }
                    ?? textWidth(segment.text, segment.weight)
                x += reserved
            }
            maxWidth = max(maxWidth, x)
            laidOut.append(items)
        }

        let size = NSSize(
            width: ceil(maxWidth) + horizontalPadding * 2,
            height: CGFloat(laidOut.count) * lineHeight + (CGFloat(laidOut.count) - 1) + spacing
        )

        let draw = {
            for (rowIndex, items) in laidOut.enumerated() {
                let offset = CGFloat(laidOut.count - 1 - rowIndex) * (lineHeight + 1)
                for (segment, x) in items {
                    NSAttributedString(string: segment.text, attributes: [
                        .font: font(segment.weight),
                        .foregroundColor: segment.color
                    ]).draw(at: NSPoint(x: horizontalPadding + x, y: offset + spacing / 2))
                }
            }
        }

        let image = NSImage(size: size, flipped: false) { _ in
            if let appearance {
                appearance.performAsCurrentDrawingAppearance {
                    drawGlow(size: size, phase: glowPhase)
                    draw()
                }
            } else {
                drawGlow(size: size, phase: glowPhase)
                draw()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 流光层：**整条背景**都在流动的彩色渐变，铺在指标文字底下。
    ///
    /// - `phase` 为 nil 表示不画（功能关闭），取值 0…1 循环。
    /// - 彩色部分：沿横向放 **3 组颜色带、相位各差 120°**，每组用一个正弦"包"控制明暗——
    ///   正弦一明一暗就是一道色带，三组错开就表现为**整条上此起彼伏的彩色流动**，
    ///   而不是一道光从左扫到右。纯计算 + 一次 `NSGradient.draw`，很便宜。
    /// - 曾经在光带之上"手搓"过玻璃质感（顶部高光 + 亮边 + 底缘暗边），后来按需求去掉了；
    ///   想恢复的话见 `Backups/MenuBarImage.swift.流光-v3.5-亮且浓-2026-09-16`。
    /// - 只横向渐变（`angle: 0`）：竖向恒定，否则那点高度会从紫到蓝糊掉。
    static func drawGlow(size: NSSize, phase: Double?) {
        guard let phase else { return }
        // 三组色相：蓝 → 紫 → 青，互相错开，流动时颜色一直在变
        let baseHues: [CGFloat] = [0.58, 0.75, 0.50]
        let cycle: CGFloat = 240          // 一组色带的波长（pt）
        let turns: CGFloat = 2.5          // 相位推进速度：一相位周期内跑 2.5 个波长
        let samples = 14

        var colors: [NSColor] = []
        var locations: [CGFloat] = []
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            for (index, baseHue) in baseHues.enumerated() {
                let offset = CGFloat(index) / CGFloat(baseHues.count)
                let s = sin(2 * .pi * (u / cycle * size.width + CGFloat(phase) * turns + offset))
                var hue = (baseHue + s * 0.06).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
                let color = NSColor(hue: hue, saturation: 1.08, brightness: 1.25, alpha: 1)
                let k = pow((s + 1) / 2, 1.6) * 0.95   // 正弦起落，压一点低端 → 色带更分明
                r += color.redComponent * k
                g += color.greenComponent * k
                b += color.blueComponent * k
                a += k
            }
            colors.append(NSColor(red: min(r, 1), green: min(g, 1), blue: min(b, 1), alpha: min(a, 1) * 0.46))
            locations.append(u)
        }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)?
            .draw(in: path, angle: 0)
    }

    // MARK: - 各行内容

    private static func buildRows(
        snapshot: MetricsSnapshot,
        preferences: Preferences,
        density: MenuBarDensity
    ) -> [[Segment]] {
        // 固定宽度用的"最宽形态"：速度最长 4 字符（如 888M），百分比最长 3 位（100）
        let speedSlot = "888M"
        let percentSlot = "100"

        // 字段之间要有明确间隔：百分比占满槽位（100）时没有任何余量，
        // 不加间隔就会贴成 `GPU 100MEM 62`。
        let gap = Segment(text: " ", color: .clear, weight: .medium, slot: " ")

        // 只显示下行速度：上行速度放在悬停提示和下拉面板里
        var network: Segment?
        if preferences.showNetwork {
            network = Segment(
                text: "↓" + Format.compactSpeed(snapshot.downSpeed),
                color: .labelColor,
                weight: .medium,
                slot: "↓" + speedSlot
            )
        }

        /// 带标签指标统一使用的槽位前缀（如 `CPU `），用来跨行对齐
        let percentPrefix = density == .minimal ? "" : "CPU "

        func metric(_ label: String, _ value: Double) -> Segment {
            let number = String(Int((min(max(value, 0), 1) * 100).rounded()))
            let prefix = density == .minimal ? "" : label + " "
            return Segment(
                text: prefix + number,
                color: StatusItemController.tint(for: value),
                weight: .semibold,
                slot: prefix + percentSlot
            )
        }

        let cpu = preferences.showCPU ? metric("CPU", snapshot.cpuUsage) : nil
        let gpu = (preferences.showGPU ? snapshot.gpuUsage : nil).map { metric("GPU", $0 / 100) }
        let memory = preferences.showMemory ? metric("MEM", snapshot.memoryFraction) : nil

        /// 用固定间隔把若干段拼成一行，空段自动跳过。
        /// `columnSlots` 可以给某一列指定统一的槽位宽度，用来让多行的同一列左右对齐。
        func line(_ segments: [Segment?], columnSlots: [String?] = []) -> [Segment] {
            var result: [Segment] = []
            for (index, segment) in segments.compactMap({ $0 }).enumerated() {
                var item = segment
                if index < columnSlots.count, let slot = columnSlots[index] {
                    item.slot = slot
                }
                if !result.isEmpty { result.append(gap) }
                result.append(item)
            }
            return result
        }

        let rows: [[Segment]]
        switch density {
        case .full:
            // 单行：网速 → CPU → GPU → 内存
            rows = [line([network, cpu, gpu, memory])]
        case .compact:
            // 两行：网速 + 内存 / CPU + GPU。
            // 这样两行宽度接近，比"三个指标挤一行"窄不少。
            // 第一列统一按 CPU/GPU 的槽位宽度（比 ↓888M 宽），第二列才能上下对齐。
            rows = [
                line([network, memory], columnSlots: [percentPrefix + percentSlot]),
                line([cpu, gpu], columnSlots: [percentPrefix + percentSlot])
            ]
        case .minimal:
            rows = [line([network]), line([cpu, gpu, memory])]
        }
        return rows.filter { !$0.isEmpty }
    }

    /// 悬停提示，展示完整信息。
    static func tooltip(snapshot: MetricsSnapshot) -> String {
        var lines: [String] = []
        lines.append("网速  ↓\(Format.speed(snapshot.downSpeed))  ↑\(Format.speed(snapshot.upSpeed))")
        lines.append("CPU   \(Format.percent(snapshot.cpuUsage))（\(snapshot.cpuCores) 核）")
        lines.append("内存  \(Format.percent(snapshot.memoryFraction))  \(Format.bytes(snapshot.memoryUsed)) / \(Format.bytes(snapshot.memoryTotal))")
        if let gpu = snapshot.gpuUsage {
            lines.append("GPU   \(Format.percent(gpu / 100))")
        }
        return lines.joined(separator: "\n")
    }
}
