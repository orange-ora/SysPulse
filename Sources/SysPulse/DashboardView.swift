import AppKit
import SwiftUI

/// 下拉面板：每项指标一张卡片，含实时数值、迷你曲线与进度条。
struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject private var login = LaunchAtLogin.shared

    /// 底部三个菜单里选了任一项之后调用，用来把整个面板收起来。
    ///
    /// 菜单（`NSMenu`）本身点完会自动关闭，但面板是独立的 `NSPopover`，不会跟着关；
    /// 选了「1 秒」「单行」这种一次性设置后，面板留在屏幕上只会挡视线，所以这里主动收。
    var onMenuSelection: () -> Void = {}

    private var snapshot: MetricsSnapshot { monitor.snapshot }
    /// 手动弹的菜单用的 target（见 `toolbarMenu`）
    private let menuTarget = ToolbarMenuTarget.shared

    var body: some View {
        VStack(spacing: 9) {
            header

            MetricCard(
                icon: "cpu",
                tint: .blue,
                title: "CPU",
                value: Format.percent(snapshot.cpuUsage),
                progress: snapshot.cpuUsage,
                history: monitor.cpuHistory,
                upperBound: 1,
                detail: "用户 \(Format.percent(snapshot.cpuUser)) · 系统 \(Format.percent(snapshot.cpuSystem)) · \(snapshot.cpuCores) 核"
            )

            MetricCard(
                icon: "cube.transparent",
                tint: .purple,
                title: "GPU",
                value: snapshot.gpuUsage.map { Format.percent($0 / 100) } ?? "--",
                progress: (snapshot.gpuUsage ?? 0) / 100,
                history: monitor.gpuHistory,
                upperBound: 1,
                detail: gpuDetail
            )

            MetricCard(
                icon: "memorychip",
                tint: .green,
                title: "内存",
                value: Format.percent(snapshot.memoryFraction),
                progress: snapshot.memoryFraction,
                history: monitor.memoryHistory,
                upperBound: 1,
                detail: memoryDetail
            )

            NetworkCard(
                down: snapshot.downSpeed,
                up: snapshot.upSpeed,
                downHistory: monitor.downHistory,
                upHistory: monitor.upHistory,
                totalDown: snapshot.totalDown,
                totalUp: snapshot.totalUp
            )

            metricToggles
            footer
        }
        .padding(13)
        .frame(width: 342)
    }

    /// 显示项开关行。
    ///
    /// 这四个开关原来放在「显示项」菜单里，但 macOS 上 SwiftUI 的菜单项点一次就会收起
    /// （`menuActionDismissBehavior(.disabled)` 被标记为 `@available(macOS, unavailable)`），
    /// 没法连续勾选。所以挪到面板上做成小开关，可以随手连点。
    private var metricToggles: some View {
        // 和上面的卡片同构：第一行是「图标 + 标题」，第二行才是内容（四个开关）。
        // 徽章统一 20pt、行距 7pt，标题行才能和 CPU / GPU / 内存 / 网络 的标题严格对齐，
        // 四张卡片连起来看是一条线；开关行单独留 12pt，和标题拉开层次。
        // 徽章用紫色而不是灰色：灰色徽章看着像「未启用」的占位，紫色是显示项的小开关
        // 自己的识别色（绿色留给选中勾，黄色 / 橙色是压力色，都不适合当常驻配色）。
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                IconBadge(symbol: "slider.horizontal.3", tint: .purple, size: 20, iconSize: 10.5)
                Text("显示项")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                toggleChip("网速", isOn: preferences.showNetwork) { preferences.showNetwork.toggle() }
                toggleChip("CPU", isOn: preferences.showCPU) { preferences.showCPU.toggle() }
                // GPU 排在内存前面：与上方 CPU / GPU / 内存 三张卡片的顺序、以及菜单栏读数里
                // `CPU … GPU … MEM …` 的顺序一致（2026-09-16 按需求把这两项调了个位置）。
                toggleChip("GPU", isOn: preferences.showGPU) { preferences.showGPU.toggle() }
                toggleChip("内存", isOn: preferences.showMemory) { preferences.showMemory.toggle() }
                toggleChip("流光", isOn: preferences.menuBarGlow) { preferences.menuBarGlow.toggle() }
                // 「动画」= 面板开合是否走系统动画。关掉后开合瞬时（约 110ms）更跟手，
                // 而且状态栏项那圈"高亮底"不会分成两次画（见 Preferences.panelAnimates 的注释）。
                toggleChip("动画", isOn: preferences.panelAnimates) { preferences.panelAnimates.toggle() }
            }
            .padding(.top, 5)   // 标题行 7pt + 这里 5pt = 12pt，比卡片内「标题 / 进度条」再松一点
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    /// 一个小开关。
    ///
    /// 三个排版细节：
    /// - 勾位用固定宽度的容器占宽，勾出现 / 消失时标签不会左右移动；
    /// - 四个开关等宽铺满卡片（`maxWidth: .infinity` 均分），右侧不留缺口，
    ///   也就和上面卡片里的进度条一样顶到同一条边缘；
    /// - 关掉时标签用 `.secondary`、底色几乎只剩描边，一眼能分出开 / 关。
    private func toggleChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isOn ? Color.green : Color.clear)
                    .frame(width: 9, height: 9)
                Text(title).font(.system(size: 10.5, weight: isOn ? .medium : .regular))
            }
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isOn ? Color.green.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .overlay(
                // 细描边：关掉的开关在浅色面板上不至于糊成一片
                Capsule().stroke(
                    isOn ? Color.green.opacity(0.30) : Color.primary.opacity(0.10),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(SpringyButtonStyle(pressedScale: 0.86, response: 0.24, damping: 0.42))
    }

    /// 底部工具栏的一个下拉项：普通 `Button`（这样 Q 弹动画能生效）+ 手动弹 `NSMenu`。
    ///
    /// `NSMenu` 是模态追踪的：选中后 action 触发、菜单自己关；面板由 `onMenuSelection`
    /// 负责收（它已经把 `performClose` 丢到下一个 runloop，不会和菜单收尾打架）。
    private func toolbarMenu(_ title: String, systemImage: String, items: [ToolbarMenuItem]) -> some View {
        Button {
            let menu = NSMenu()
            for item in items {
                let menuItem = NSMenuItem(title: item.title, action: #selector(ToolbarMenuTarget.fire(_:)), keyEquivalent: "")
                menuItem.target = menuTarget
                menuItem.representedObject = item.action
                // 勾用富文本画（系统勾是单色模板图，改不了颜色）——
                // 和原来 SwiftUI 版一样的做法：勾占固定宽度，未选中用空格占位保持对齐。
                var head = AttributedString(item.isOn ? "✓  " : "     ")
                if item.isOn { head.foregroundColor = .green }
                menuItem.attributedTitle = NSAttributedString(head + AttributedString(item.title))
                menu.addItem(menuItem)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 3) {
                Label(title, systemImage: systemImage).font(.system(size: 11))
                // ⌄ 原来由 SwiftUI 的 `Menu` 自带，换成普通 Button 后要自己画
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(SpringyButtonStyle(pressedScale: 0.90, response: 0.24, damping: 0.40))
    }

    /// 菜单项：标题 + 是否打勾 + 选中后做什么。
    struct ToolbarMenuItem {
        let title: String
        let isOn: Bool
        let action: () -> Void

        init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
            self.title = title
            self.isOn = isOn
            self.action = action
        }
    }

    /// `NSMenuItem` 的 target：把闭包包成 `@objc` 方法能调的形式。
    final class ToolbarMenuTarget: NSObject {
        static let shared = ToolbarMenuTarget()
        @objc func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }
    }

    /// 菜单项：选中时在文字前加一个**绿色**勾。
    ///
    /// 系统的勾是单色模板图（`Toggle` 和 `Label(_:systemImage:)` 都无法改色），
    /// 所以这里用富文本前缀自己画：绿色 ✓ + 正常的标题颜色。
    private func menuRow(_ title: String, isOn: Bool) -> Text {
        // 勾占的宽度是固定的：选中画绿色勾，未选中用 5 个空格占位
        // （实测「✓  」18.34pt vs 5 空格 17.90pt，差 0.44pt，肉眼无感），
        // 这样所有标题都在同一列对齐，未选中项也看不到任何痕迹。
        // 标题不指定颜色：交给菜单按浅色/深色背景决定，写死 .primary 在浅色菜单上会发灰。
        var head = AttributedString(isOn ? "✓  " : "     ")
        if isOn { head.foregroundColor = .green }
        return Text(head) + Text(title)
    }

    /// GPU 卡片副标题：核心数 + 正在使用的统一内存
    private var gpuDetail: String {
        var parts: [String] = []
        if let cores = snapshot.gpuCores { parts.append("\(cores) 核") }
        if let memory = snapshot.gpuMemory { parts.append("GPU 内存 \(Format.bytes(memory))") }
        return parts.isEmpty ? "该机型未暴露 GPU 计数器" : parts.joined(separator: " · ")
    }

    private var memoryDetail: String {
        var text = "已用 \(Format.bytes(snapshot.memoryUsed)) / \(Format.bytes(snapshot.memoryTotal))"
        if snapshot.swapUsed > 0 {
            text += " · 交换 \(Format.bytes(snapshot.swapUsed))"
        }
        return text
    }

    // MARK: - 头部 / 尾部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text("SysPulse")
                .font(.system(size: 12.5, weight: .bold))
            Spacer(minLength: 8)
            Text("已运行 \(Format.uptime(snapshot.uptime))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("· \(snapshot.processCount) 进程")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 1)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 1)

            HStack(spacing: 6) {
                // 这三个原来是 SwiftUI 的 `Menu`。⚠️ **`Menu` 不会把"按下"状态传给
                // `ButtonStyle`**，所以那套 Q 弹动画在它们身上根本不生效（用户 2026-09-17 反馈）。
                // 现在改成普通 `Button`（按下动画由 `SpringyButtonStyle` 驱动）+ 在 action 里
                // 手动 `NSMenu.popUp`，菜单内容与勾选逻辑保持不变。
                toolbarMenu("刷新", systemImage: "clock", items: [
                    ToolbarMenuItem(intervalTitle(0.5), isOn: abs(preferences.refreshInterval - 0.5) < 0.01) {
                        preferences.refreshInterval = 0.5; onMenuSelection()
                    },
                    ToolbarMenuItem(intervalTitle(1), isOn: abs(preferences.refreshInterval - 1) < 0.01) {
                        preferences.refreshInterval = 1; onMenuSelection()
                    },
                    ToolbarMenuItem(intervalTitle(2), isOn: abs(preferences.refreshInterval - 2) < 0.01) {
                        preferences.refreshInterval = 2; onMenuSelection()
                    },
                    ToolbarMenuItem(intervalTitle(5), isOn: abs(preferences.refreshInterval - 5) < 0.01) {
                        preferences.refreshInterval = 5; onMenuSelection()
                    }
                ])

                toolbarMenu("排版", systemImage: "rectangle.split.3x1",
                            items: MenuBarLayout.allCases.map { layout in
                    let title = layout.detail.map { "\(layout.title) · \($0)" } ?? layout.title
                    return ToolbarMenuItem(title, isOn: preferences.menuBarLayout == layout) {
                        preferences.menuBarLayout = layout; onMenuSelection()
                    }
                })

                toolbarMenu("启动", systemImage: "power.circle", items: [
                    ToolbarMenuItem("开机自动启动", isOn: login.isEnabled) {
                        login.set(!login.isEnabled); onMenuSelection()
                    }
                ])

                Spacer(minLength: 4)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出", systemImage: "xmark.circle").font(.system(size: 11))
                }
                .buttonStyle(SpringyButtonStyle(pressedScale: 0.92, response: 0.26, damping: 0.5))
            }

            if let message = login.errorMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .onChange(of: preferences.refreshInterval) { _, _ in
            monitor.restartTimer()
        }
    }

    private func intervalTitle(_ interval: Double) -> String {
        switch interval {
        case ..<0.75: return "0.5 秒"
        case ..<1.5: return "1 秒"
        case ..<3: return "2 秒"
        default: return "5 秒"
        }
    }
}

// MARK: - 卡片

/// 单指标卡片：图标 + 标题 + 大号数值 + 迷你曲线 + 进度条 + 明细。
struct MetricCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let progress: Double
    let history: [Double]
    let upperBound: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                IconBadge(symbol: icon, tint: tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 14.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StatusItemController.tint(for: progress).swiftUIColor)
                Sparkline(series: [history], colors: [tint], upperBound: upperBound)
                    .frame(width: 78, height: 20)
            }
            ProgressBar(value: progress, tint: tint)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }
}

/// 网络卡片：上下行速度分列显示，曲线按峰值自适应。
struct NetworkCard: View {
    let down: Double
    let up: Double
    let downHistory: [Double]
    let upHistory: [Double]
    let totalDown: UInt64
    let totalUp: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconBadge(symbol: "arrow.up.arrow.down", tint: .orange)
                Text("网络")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Sparkline(series: [downHistory, upHistory], colors: [.blue, .green], upperBound: nil)
                    .frame(width: 100, height: 20)
            }

            HStack(spacing: 10) {
                speedBlock(symbol: "arrow.down", tint: .blue, caption: "下载", value: Format.speed(down))
                Divider().frame(height: 26)
                speedBlock(symbol: "arrow.up", tint: .green, caption: "上传", value: Format.speed(up))
            }

            Text("本次运行接收 \(Format.bytes(totalDown)) · 发送 \(Format.bytes(totalUp))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func speedBlock(symbol: String, tint: Color, caption: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 基础组件

struct IconBadge: View {
    let symbol: String
    let tint: Color
    /// 徽章边长。上方四张卡片用默认 20pt；「显示项」用小一号，避免和标题抢注意力。
    var size: CGFloat = 20
    /// 徽章内图标的字号。
    var iconSize: CGFloat = 10.5

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.15))
            )
    }
}

struct ProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.25), value: value)
    }
}

/// 迷你折线图，`upperBound` 为 nil 时按数据峰值自适应。
struct Sparkline: View {
    let series: [[Double]]
    let colors: [Color]
    let upperBound: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let bound = resolvedBound
            ZStack {
                if let first = series.first, first.count > 1 {
                    areaPath(first, in: size, bound: bound)
                        .fill(
                            LinearGradient(
                                colors: [
                                    colors.first?.opacity(0.28) ?? .clear,
                                    colors.first?.opacity(0.02) ?? .clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                ForEach(Array(series.enumerated()), id: \.offset) { index, values in
                    linePath(values, in: size, bound: bound)
                        .stroke(
                            colors[min(index, colors.count - 1)],
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                        )
                }
            }
        }
    }

    private var resolvedBound: Double {
        if let upperBound, upperBound > 0 { return upperBound }
        let peak = series.flatMap { $0 }.max() ?? 0
        return max(peak * 1.2, 1024)
    }

    private func points(_ values: [Double], in size: CGSize, bound: Double) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let normalized = min(max(value / bound, 0), 1)
            return CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat(normalized) * (size.height - 1.5) - 0.75
            )
        }
    }

    private func linePath(_ values: [Double], in size: CGSize, bound: Double) -> Path {
        var path = Path()
        let pts = points(values, in: size, bound: bound)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.6, y: first.y))
        } else {
            for point in pts.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    private func areaPath(_ values: [Double], in size: CGSize, bound: Double) -> Path {
        var path = linePath(values, in: size, bound: bound)
        let pts = points(values, in: size, bound: bound)
        guard let first = pts.first, let last = pts.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}

extension NSColor {
    /// 把 AppKit 颜色映射到 SwiftUI 颜色，保证状态栏与面板配色一致。
    var swiftUIColor: Color {
        Color(nsColor: self)
    }
}

/// 「果冻」按钮样式：按下缩一点、松手用**欠阻尼弹簧**弹回（会过冲一下），
/// 就是 iOS 那种 Q 弹手感（2026-09-16 按需求加的）。
///
/// 只依赖 `ButtonStyle` 提供的 `isPressed`，**不需要任何状态** —— 本机命令行工具链缺少
/// SwiftUIMacros 插件，这个项目的源码刻意不用 `@State` 之类的宏。
/// 手感靠三个数调：`pressedScale` 按下缩多少、`response` 快慢、`damping` 回弹几下
/// （< 1 才有回弹；0.42 ≈ 蹦两下，0.5 ≈ 轻微过冲，0.8 ≈ 基本不弹）。
struct SpringyButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.90
    var response: Double = 0.26
    var damping: Double = 0.45

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: response, dampingFraction: damping), value: configuration.isPressed)
    }
}
