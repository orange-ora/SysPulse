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

    /// 底部工具栏（刷新 / 排版 / 启动 / 退出）统一的字号。
    /// 四者的图标与文字都由它派生 —— "调大一号"只改这一处，也不会再出现
    /// 谁比谁粗、谁比谁大的不一致（2026-09-17 用户要求整体调大一号）。
    private let toolbarFontSize: CGFloat = 13

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
                effectChip()
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
    /// - 五个开关（网速 / CPU / GPU / 内存 / 流光）等宽铺满卡片（`maxWidth: .infinity` 均分），
    ///   右侧不留缺口，也就和上面卡片里的进度条一样顶到同一条边缘；
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
        .buttonStyle(.plain)
    }

    /// 背景动效选择：一个和 `toggleChip` 同尺寸的胶囊，点开是「关闭 / 流光 / 漫散射」三选一。
    ///
    /// **为什么不是又一个开关**：两个效果是互斥的（同时开会互相干扰、观感更乱），
    /// 做成两个独立开关就会出现"两个都亮着"的歧义状态；做成单值枚举就不会。
    ///
    /// 未选中（关闭）时用 `eye.slash` 而不是 `checkmark`，因为这一项和左边四个
    /// "开/关"型开关语义不同 —— 它是三态，用眼睛图标一眼能看出"当前没有背景动效"。
    ///
    /// ⚠️ **这个胶囊的外观是一张整图，不是 SwiftUI 视图**（原因见 `effectChipImage`）。
    /// 开启时是**橙色圆角圈 + 橙色星星 + 白字 + 中性底**（底色不带颜色，见 `effectChipImage`）；
    /// 关闭时是灰圈 + 灰眼睛 + 灰字。
    /// 左边四个开关的绿胶囊是另一套视图（`toggleChip`），**两者互不影响**。
    ///
    /// 把 SF Symbol 染成指定颜色，返回**非模板**图片（`isTemplate = false`）。
    ///
    /// ⚠️ `color` 必须是**不透明**颜色，别传 `.clear` 想表达"不染色"：这里靠
    /// `sourceAtop` 铺色，而 `sourceAtop` 的结果是 `S·Da + D·(1−Sa)`，源 alpha 为 0 时
    /// 结果**恒等于原图**（不是变透明），于是符号保留 SF Symbol 的默认黑。
    /// 2026-10-01 实测踩过：关闭态传 `.clear`，深色面板上量到 `(0,0,0)`、191 个近黑像素的眼睛。
    private static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        color.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    /// 把整个效果胶囊（圆角圈 + 星星 + 文字）画成**一张非模板图片**。
    ///
    /// ⚠️ **为什么必须整块画成图片**（2026-10-01 逐项实测，别往回改）：
    /// 这个胶囊用 `.menuStyle(.borderlessButton)`，系统会把标签**扁平化**：
    ///   · `.foregroundStyle(.green)` → 无效（图标/文字都被渲染成系统前景色）
    ///   · `.background(Capsule().fill(Color…))` → **整块丢掉**
    ///     （面板上量到 `(59,59,62)` 对底色 `(59,59,61)`，只有 1/255 的差别）
    ///   · `.background(Image(nsImage: 非模板胶囊))` → 同样丢掉
    ///   · 把胶囊放进内容做 ZStack 兄弟 → 画出来了，但**布局错乱**（胶囊与文字并排）
    /// 唯一稳定的是**内容里的非模板图片按自身像素绘制**，所以整块画成一张图。
    /// ⚠️ 用 `NSImage(size:flipped:drawingHandler:)` 而不是 `lockFocus`：
    /// 前者按目标缩放**重新光栅化**，2x 屏上文字才清晰（与状态栏图片同一套做法）。
    private static func effectChipImage(title: String, isOn: Bool, tint: NSColor,
                                        isDark: Bool) -> NSImage {
        // ⚠️ 这张图里**一律不用语义色**（`secondaryLabelColor` 之类）。两个实测原因：
        //   ① 离屏上下文的外观不跟随面板（`NSColor.labelColor` 会解析成黑，见 `isDarkAppearance`）；
        //   ② 语义色**自带 alpha**，`withAlphaComponent()` 与它**相乘**：实测
        //      `secondaryLabelColor.withAlphaComponent(0.10)` 铺出来只比面板底色高 **6 个灰阶**
        //      （约 5% 白），底板等于没有 —— 2026-10-01 在真机面板上量到。
        // 改成按 `isDark` 显式给「白 / 黑 + alpha」：底板 Δ+12~16、灰圈 Δ+50，清清楚楚。
        let neutral = isDark ? NSColor.white : NSColor.black
        let plate = neutral.withAlphaComponent(0.10)        // 中性地板，与左边开关同档（primary 0.06~0.16）
        let ringOff = neutral.withAlphaComponent(0.22)      // 关闭态灰圈
        let inkOff = NSColor(white: isDark ? 0.72 : 0.38, alpha: 1)   // 关闭态灰字 / 灰眼睛

        let font = NSFont.systemFont(ofSize: 10.5, weight: isOn ? .semibold : .regular)
        let iconSide: CGFloat = 11
        let hPad: CGFloat = 8, vPad: CGFloat = 4, gap: CGFloat = 4
        let attributed = NSAttributedString(string: title, attributes: [
            .font: font,
            // 文字按用户要求保持白字（浅色面板上转黑字）。
            // ⚠️ 必须显式给色：`NSAttributedString.draw` 在离屏上下文里没有默认前景色，
            // 不给就是**纯黑**（实测踩过：深色面板上文字直接消失）。
            // ⚠️ 也不能用 `NSColor.labelColor` —— 离屏上下文的外观不跟随面板，
            // 解析出来同样是黑的。所以外观由调用方按 `NSApp` 实际外观显式传进来。
            .foregroundColor: isOn ? (isDark ? NSColor.white : NSColor.black) : inkOff
        ])
        let textSize = attributed.size()
        let size = NSSize(width: hPad * 2 + iconSide + gap + ceil(textSize.width),
                          height: vPad * 2 + max(iconSide, ceil(textSize.height)))
        // ⚠️ 关闭态的图标要显式给灰（不能传 `.clear`，见 `tintedSymbol` 的说明）
        let icon = tintedSymbol(isOn ? "sparkles" : "eye.slash",
                                color: isOn ? tint : inkOff, pointSize: 9)
        let image = NSImage(size: size, flipped: false) { _ in
            // 圆角圈：**橙色描边 + 不带颜色的中性底**。
            // ⚠️ 底色曾经是 `tint.withAlphaComponent(0.16)`（淡橙），用户 2026-10-01 要求
            // **底色不要用橙色、干脆不用颜色**：描边和星星保持橙色，只有内部这层地板改成中性。
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            plate.setFill()
            path.fill()
            (isOn ? tint.withAlphaComponent(0.75) : ringOff).setStroke()
            path.lineWidth = 1
            path.stroke()
            if let icon {
                icon.draw(at: NSPoint(x: hPad, y: (size.height - icon.size.height) / 2),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
            attributed.draw(at: NSPoint(x: hPad + iconSide + gap,
                                        y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 当前是不是深色外观。
    ///
    /// ⚠️ **不能用 SwiftUI 的 `@Environment(\.colorScheme)`** —— 实测它在面板这个
    /// popover 里报 **light**（面板实际是深色），于是白字被画成黑字、压在深色面板上
    /// 等于没字。也不能用 `NSColor.labelColor`：离屏绘制上下文的外观同样不跟随面板，
    /// 解析出来也是黑的。直接问 App 的实际外观最可靠。
    private static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func effectChip() -> some View {
        let effect = preferences.menuBarEffect
        let isOn = effect != .off
        return Menu {
            ForEach(MenuBarEffect.allCases, id: \.self) { option in
                Button {
                    preferences.menuBarEffect = option
                } label: {
                    menuRow(option.title, isOn: option == effect)
                }
            }
        } label: {
            Image(nsImage: Self.effectChipImage(title: effect.title, isOn: isOn,
                                                tint: .systemOrange,
                                                isDark: Self.isDarkAppearance))
                .accessibilityLabel(effect.title)
        }
        // `.borderlessButton` 会忽略 `.foregroundStyle`（标签由系统按菜单样式渲染），
        // 于是关闭态下会和左边四个开关的"灰"不一致 —— 所以只靠文字/图标本身表达状态，
        // 颜色交给系统，这样在浅色面板上也不会发灰。
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                Menu {
                    ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { interval in
                        Button {
                            preferences.refreshInterval = interval
                            onMenuSelection()
                        } label: {
                            menuRow(intervalTitle(interval), isOn: abs(preferences.refreshInterval - interval) < 0.01)
                        }
                    }
                } label: {
                    Label("刷新", systemImage: "clock").font(.system(size: toolbarFontSize))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(MenuBarLayout.allCases, id: \.self) { layout in
                        let title = layout.detail.map { "\(layout.title) · \($0)" } ?? layout.title
                        Button {
                            preferences.menuBarLayout = layout
                            onMenuSelection()
                        } label: {
                            menuRow(title, isOn: preferences.menuBarLayout == layout)
                        }
                    }
                } label: {
                    Label("排版", systemImage: "rectangle.split.3x1").font(.system(size: toolbarFontSize))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Button {
                        login.set(!login.isEnabled)
                        onMenuSelection()
                    } label: {
                        menuRow("开机自动启动", isOn: login.isEnabled)
                    }
                } label: {
                    Label("启动", systemImage: "power.circle").font(.system(size: toolbarFontSize))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer(minLength: 4)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    // 字重 / 颜色对齐左边那三个菜单：`Menu` 的标签由
                    // `.menuStyle(.borderlessButton)` 渲染（偏粗 + 主色），
                    // 而 `.borderless` 的普通按钮标签更轻更淡，并排看会像两种样式。
                    // 图标与文字**分开设样式**：左边那三个菜单的图标（时钟 / 分栏 / 电源）
                    // 本身是细轮廓，而 `xmark.circle` 里的叉天生更粗 —— 不单独压一下，
                    // 即使文字对齐了，图标还是会显得比它们重（用户："太丑了"）。
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: toolbarFontSize, weight: .regular))
                        Text("退出")
                            .font(.system(size: toolbarFontSize, weight: .medium))
                    }
                    // 退出是"破坏性"操作，用橙色和左边三个设置项区分开（2026-09-17 按需求改）
                    .foregroundStyle(Color.orange)
                }
                .buttonStyle(.borderless)
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
    /// 徽章边长。上方四张卡片与「显示项」**统一用默认的 20pt**，
    /// 这样两者的标题才落在同一条竖线上（见 `metricToggles` 的注释）。
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
