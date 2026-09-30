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
        effect: MenuBarEffect = .off,
        effectElapsed: Double? = nil
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
                    drawEffect(size: size, effect: effect, elapsed: effectElapsed)
                    draw()
                }
            } else {
                drawEffect(size: size, effect: effect, elapsed: effectElapsed)
                draw()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 背景动效总入口，按给定效果分发。
    ///
    /// `phase` 为 nil = 不画（关闭，或这一帧不需要动效层）。两个效果共用同一个相位时钟
    /// （`StatusItemController` 的定时器），所以切换效果时不会出现"跳动一下"。
    ///
    /// ⚠️ **效果类型必须从参数传进来，不能读 `Preferences.shared`。**
    /// 一开始这里读的是全局单例，结果是：① 渲染函数不再可测（测试进程有自己的
    /// bundle id，读到的是它自己的默认值 `.off`，于是怎么渲都只有文字层）；
    /// ② 与同函数的 `density`（从参数传）不对称，埋一个"到底该信谁"的坑。
    static func drawEffect(size: NSSize, effect: MenuBarEffect, elapsed: Double?) {
        guard let elapsed else { return }
        switch effect {
        case .off: return
        case .glow:
            // 流光的相位推进速度由 drawGlow 里的 `turns` 决定，这里只做周期归一化
            drawGlow(size: size, phase: (elapsed / effectGlowCycleSeconds).truncatingRemainder(dividingBy: 1))
        case .diffuse:
            drawDiffuse(size: size, elapsed: elapsed)
        }
    }

    /// 流光走完一整圈所需秒数（漫散射不用它 —— 它按每个光点自己的 `period` 走）。
    static let effectGlowCycleSeconds: Double = 12

    /// 漫散射层：几个柔和的径向光斑**各自沿不同方向、以不同速度游走**，互相叠加。
    ///
    /// 和 `drawGlow` 的本质区别：流光只有一个相位、色带整体横向平移，所以是**规则的**；
    /// 这里每个光斑有自己的方向角、周期、半径、色相，叠加之后没有可预测的走向 ——
    /// 就是需求里要的"不拘于方向、像水汽漫散"。
    ///
    /// ⚠️⚠️ **2026-09-30 修掉的那个 bug（别再写回去）**：光斑半径曾经被**放大了一个
    /// 「宽高比」的倍数**（本机单行档 11.6 倍），于是每个"光斑"都不是光斑，而是一块
    /// 横跨整条 215pt 的平板 —— 三个平板叠起来，整条就是一层均匀的雾。
    /// 实测症状：24 个取样位置的 alpha 全程只落在 **0.55~0.84**，
    /// 而且 **24 个位置的峰值时刻有 22 个完全相同**（全挤在 14.5~15.0 秒），
    /// 正是用户说的"怎么是整条色带在整体变化？我想要的不是漫散射吗"。
    ///
    /// 根因是**归一化空间的各向异性**：
    /// `cg.scaleBy(x: size.width, y: size.height)` 把单位正方形映射到 size，
    /// 横竖缩放比是 `width / height`，所以单位空间里半径 r 的"圆"，落到屏幕上是
    /// 半轴 `(r · width · scaleX, r · height)` 的椭圆。当时的注释以为
    /// `scaleX = radiusX / radiusY` 就是扁率，**其实真实横向半轴比它大 `width/height` 倍**。
    /// 实测对照（单行档 215×18.5pt、radius 1.9）：单个光斑在**距中心 100pt 处 alpha 仍有 0.412**
    /// （等于覆盖整条），理论横向半轴 1.9×215×0.85 ≈ 347pt —— 与实测吻合。
    ///
    /// **现在的写法是在「点空间」里给半径**（见下面 `translateBy` + `scaleBy(radiusX, radiusY)`）：
    /// 单位空间就是"半径 = 1"，`radiusX / radiusY` 的含义就是 pt，与条宽高比无关，
    /// 不可能再被隐式放大。**改这里时不要再引入 `size.width` 参与的半径换算。**
    ///
    /// 📌 交接文档 `HANDOFF-漫散射未解决-2026-09-30.md` 里"因为 source-over 叠加饱和，
    /// 所以窄条上做不出各自漫散"的结论**是错的** —— 光斑从来就没有形状，谈不上饱和。
    ///
    /// ⚠️ **周期刻意取互不相同、且互不整除的值**（±10% 上下）。如果取成完全相同的周期，
    /// 所有光斑的**相位关系**就永远不变，整条每隔一个周期"重来一次"，规律感立刻回来；
    /// 差得太多（原来取的 9.3~15.1 秒差了 60%）又会让相位漂到同一处、偶尔集体变淡。
    ///
    /// 实现成本：每个光斑**一次** `NSGradient.draw`（径向），2~5 个光斑 = 2~5 次填充，
    /// 与 `drawGlow` 的 1 次横向渐变 + `drawRipple` 的 1 次同量级。
    /// 注意整条动效的真实开销不在绘制（实测 0.15ms/帧），而在"每帧换一张状态栏图片"
    /// 那笔系统开销 —— 见 `contentKey` 的注释。
    static func drawDiffuse(size: NSSize, elapsed: Double) {
        let rect = NSRect(origin: .zero, size: size)
        // 裁到圆角胶囊里：光斑半径比条高，中心也会游走出条外，
        // 不裁的话径向渐变的直角边缘会在胶囊圆角处露出来。
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: size.height / 2, yRadius: size.height / 2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // 光斑数量按**绝对宽度**定（每约 44pt 一个），不按宽高比。
        //
        // 这样三档排版下**光斑的实际尺寸基本一致**，观感强度不随档位变化 ——
        // 曾经用宽高比定数量，结果"同一效果单行档比双行档淡很多"（用户："明显色差严重"）。
        // 数量变了也没关系：半径是按 `spacing = width / count` 算的（见下），
        // 所以**"光斑/间距"这个比值在三档下恒定**，覆盖的形状是同一个，只有疏密不同。
        let count = max(2, min(5, Int((size.width / 44).rounded())))
        let spacing = size.width / CGFloat(count)

        // 每个光斑的"个性"，按序号直接取用（**不插值**）。
        //
        // ⚠️ 之前是在一张 6 项的基准表里按 `i / count * 6` 插值取样，看起来更"连续"，
        // 实际是个坑：count = 4 时取到的是 0 / 1.5 / 3 / 4.5，落点相邻，
        // **周期全挤在 11.9~12.7 秒**，"各走各的"根本没发生（设计值本来是 9.3~15.1）。
        // 直接按序号取用才能保证每个光斑真的拿到不同的参数。
        let variants: [(period: Double, angle: CGFloat, ampX: CGFloat, ampY: CGFloat, drift: CGFloat, phase: Double)] = [
            (12.7, 0.00, 0.033, 0.30,  1.0, 0.00),
            (11.7, 1.15, 0.042, 0.36, -1.0, 0.37),
            (12.9, 2.40, 0.027, 0.24,  1.0, 0.71),
            (11.3, 3.60, 0.039, 0.32, -1.0, 0.13),
            (13.4, 5.10, 0.030, 0.28,  1.0, 0.55),
            (12.1, 4.30, 0.036, 0.34, -1.0, 0.88),
        ]

        // 色相：**一段"窄而缓"的坡**（0.76 淡紫 274° → 0.95 淡粉 342°，跨约 68°），
        // 中间经过 308° 一带的藕粉，所以整条是"淡紫 → 藕粉 → 淡粉"的连续坡。
        //
        // ⚠️ 第一版取 0.50(青) → 0.82(粉红)，跨 115°，用户反馈"颜色配比不好看、有点突兀、
        // 东一块西一块、融合感不够"。量化后确实：相邻取样点**色相跳变均值 14.4~16.4°、
        // 峰值到 51°**，而流光只有 5.6~9.6° / 峰值 27.8°。现在这个坡就是为了对齐流光。
        //
        // ⚠️ **基调：淡紫 / 淡粉 / 藕粉，低饱和 + 高透明度，要"清新通透"。**
        // 参数是**扫描出来的**：固定色相扫 (alpha, saturation) 网格，看合成到深底后的 HSV，
        // 找"S 低（粉彩）+ V 够（看得见）"的甜点区 → alpha 0.30 / saturation 0.35 落在
        // S26% / V51%。但见下面这条**被测出来的物理冲突**。
        //
        // ⚠️⚠️ **本机菜单栏底色实测是 RGB(47,78,112) = H213°、饱和度已 58%**
        // —— 那是**壁纸透过菜单栏毛玻璃**的结果，不是中性深灰（换壁纸就会变：
        // 早先同一处量到的是 RGB(80,115,150)）。粉彩叠在这种蓝底上
        // **低浓度永远翻不过去**（实测 alpha 0.30 → 合成 H246° S21%，是"蓝灰"不是粉；
        // 要让 R 压过 B、看着像粉，alpha 得 ≥0.60）。
        // 所以"高透明度"和"看得出粉"在这台机器的这张壁纸上**不能同时满足**，
        // 现在的取值是折中（淡紫端可以淡、粉端得给够浓度）。
        // 参考：把菜单栏换成素色壁纸时底色接近中性，那时低浓度就能显色。
        //
        // 以下是按小米 HyperOS 启动图（8×8 网格实测：明度 90~100%、饱和度仅 7~18%、
        // 色相左上 320~328° 粉紫 → 右下 226~256° 蓝）校准时的记录，保留备查：
        // 那张图是**亮底**，而菜单栏是深色底 + 白字，照搬会把文字涂掉，
        // 所以按用户决定保留暗底、只取它的色相走向。另外用户手上只有**静态截图**，
        // 所以参考只覆盖配色与色相分布，**动感从未被参考到**。
        let hueStart: CGFloat = 0.52, hueEnd: CGFloat = 0.79

        // ⚠️ **脉动 = 每个光点自己的周期 + 各自的固定相位，然后减均值、再限幅。**
        //
        // 三个要求在互相拉扯，各自的对策是：
        //
        // 1. **"整条不许一起变"** → **减掉均值**。这样任意时刻 `Σ pulse ≈ 0`，
        //    整条的平均亮度与平均色相在数学上不可能漂移。这是用户那句
        //    "怎么是整条色带在整体变化"的根治办法。
        //    ⚠️ 光靠"给每个光点不同的周期"不够 —— 那只会让共模分量**缓慢**漂移，
        //    实测整条平均色相照样摆 30°+，用户仍然看得出"整条在变"。
        // 2. **"不许有方向感"** → 相位偏移**不能取 i/count 这种均匀递增**。
        //    均匀递增等价于"每个光点依次亮一遍"，那就是一道**行波**（有方向）。
        //    ⚠️ 也试过"两条周期不同的行波叠加"，形状会变，但两条都还是行波。
        //    现在用一张**不规则**的表（0.00 / 0.37 / 0.71 / 0.13 / 0.55 / 0.88），
        //    相邻光点的相位差正负交替，看不出"扫过"的方向。
        // 3. **"不许突然大幅跳色"** → 减完均值要**限幅到 ±1**。
        //    ⚠️ 脉动本身在 ±1 内，但**减均值会把它放大**：最坏情况（一个光点在峰值、
        //    其余都在谷值）放大到 `2(N-1)/N` 倍，N = 5 时是 1.6 倍。实测那会让相邻
        //    光点的色相差在极端时刻冲到 58°，正是"东一块西一块"那种突然跳色。
        //    限幅的代价是 `Σ pulse` 不再严格为 0，但泄漏很小（实测整条平均色相摆动
        //    仍在 16° 以内，比不限幅的 30°+ 好一个量级）。
        var pulses: [CGFloat] = []
        var centers: [(x: CGFloat, y: CGFloat)] = []
        for i in 0..<count {
            let v = variants[i % variants.count]
            // 位置：每个光点有自己的周期与方向角 → "不拘于方向"的游走
            let theta = 2 * .pi * CGFloat(elapsed / v.period) + v.angle
            let centerX = (Double(i) / Double(count) + 0.5 / Double(count)      // 等距铺满
                           + cos(theta) * v.ampX) * size.width
            let centerY = (0.50 + sin(theta * 1.31) * v.ampY) * size.height
            centers.append((centerX, centerY))

            // 脉动：自己的周期 + 自己的（不规则）相位。
            // 周期 11.3~13.4 秒：**互不相等、互不整除**，所以相位关系一直在缓慢变化，
            // 画面不会每隔一个周期回到原样；但也没有散得太开（曾经取 9.3~15.1 秒，
            // 差 60% 会让相位漂到同一处、整条偶尔集体变淡）。
            let selfPhase = elapsed / v.period + v.phase
            pulses.append(CGFloat(sin(2 * .pi * selfPhase)))
        }

        // 减均值 + 限幅，见上面第 1 / 3 条
        let meanPulse = pulses.reduce(0, +) / CGFloat(count)
        let mod: [CGFloat] = pulses.map { max(-1, min(1, $0 - meanPulse)) }

        for i in 0..<count {
            let v = variants[i % variants.count]
            let pulse = mod[i]
            let center = centers[i]

            // 半径、浓度、色相**共用同一个 pulse**，所以一个光点"涨起来"的时候
            // 它同时更亮、更正对、色相也正在偏离本色 —— 观感是"活的"。
            // 这就是"从内而外"的那一下：光点自己从中心涨大又缩回去。
            //
            // ⚠️ 半径的脉动幅度故意比浓度小（0.95±0.11 对 0.86±0.25）：
            // 半径收到 0.84×spacing 时相邻光斑之间就会开始出现暗缝，
            // 整条会从"连续漫散"变成"几个分离的光团"（用户要的是雾，不是光团）。
            // 实测下限：全程最小 alpha 0.39（>0 表示任何时刻整条都被覆盖，没有断口）。
            let radiusX = spacing * 0.88 * (0.95 + 0.11 * pulse)
            let radiusY = size.height * 1.25 * (0.95 + 0.11 * pulse)
            let peakAlpha = min(1, 1.05 * (0.86 + 0.25 * pulse))

            // 色相：围绕本色小幅呼吸（±0.03 × drift，约 ±11°）。
            // ⚠️ 幅度不能再大：实测 0.03→0.05 会让相邻取样点的色相跳变峰值
            // 从 22° 顶到 34°（流光是 27.8°），就是用户说的"东一块西一块"。
            var hue = hueStart + (hueEnd - hueStart) * CGFloat(i) / CGFloat(max(count - 1, 1))
            hue += 0.03 * v.drift * pulse
            hue = hue.truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }

            // 四段衰减：**尾段要够胖**（0.60 处还有 0.80）。
            // 尾部瘦的话，相邻光斑之间会露出底色 —— 而本机底色是蓝的，
            // 一露出来色相就被拉向蓝灰，整条立刻变成"东一块西一块"。
            // 实测把 (0.45, 0.484) 改成 (0.60, 0.80) 之后：
            // 全程最小 alpha 0.00 → 0.49，相邻色相跳变峰值 53.8° → 24°。
            let stops: [(CGFloat, CGFloat)] = [(0.00, 1.000), (0.60, 0.800), (0.85, 0.400), (1.00, 0.000)]
            let colors = stops.map {
                NSColor(hue: hue, saturation: 0.45, brightness: 0.90, alpha: $0.1 * peakAlpha)
            }
            let locations = stops.map { $0.0 }

            NSGraphicsContext.saveGraphicsState()
            if let cg = NSGraphicsContext.current?.cgContext {
                // ⚠️ **在点空间里给半径**（对比上面那段 bug 记录）：
                // 先平移到光斑中心（单位 = pt），再把 CTM 的两个轴分别缩放到 radiusX / radiusY，
                // 于是"半径 1"就等于 (radiusX, radiusY) pt。**不要再乘 size.width。**
                cg.translateBy(x: center.x, y: center.y)
                cg.scaleBy(x: radiusX, y: radiusY)
                NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)?
                    .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: 1, options: [])
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    /// 流光层：**整条背景**都在流动的彩色渐变，铺在指标文字底下。
    ///
    /// - `phase` 为 nil 表示不画（功能关闭），取值 0…1 循环。
    /// - 彩色部分：沿横向放 **3 组颜色带、相位各差 120°**，每组用一个正弦"包"控制明暗——
    ///   正弦一明一暗就是一道色带，三组错开就表现为**整条上此起彼伏的彩色流动**，
    ///   而不是一道光从左扫到右。纯计算 + 一次 `NSGradient.draw`，很便宜。
    /// - 曾经在光带之上"手搓"过玻璃质感（顶部高光 + 亮边 + 底缘暗边），后来按需求去掉了；
    ///   想恢复的话见 `Backups/MenuBarImage.swift.流光-v3.5-亮且浓-2026-09-16`。
    /// - 彩色部分**只横向渐变**（`angle: 0`）：竖向恒定，否则那点高度会从紫到蓝糊掉。
    ///   竖向的变化交给上面那层"水波"（`drawRipple`）用明暗做，而不是让色相在竖向也变。
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

        // 彩色光带之上再叠一层"水波"（明暗起伏），见 drawRipple 的注释
        drawRipple(size: size, phase: phase)
    }

    /// 水波起伏层：在彩色光带**之上**叠一层明暗波纹，波面略微倾斜、相位随时间上下推移 ——
    /// 于是在"颜色横向流动"之外，多出**上下起伏**的观感（2026-09-16 按需求加的）。
    ///
    /// 实现上只多花**一次** `NSGradient.draw`（不是把画面切成很多横条去逐条画）：
    /// 一条竖向、略斜的渐变，白 / 黑交替若干道 —— 白色提亮、黑色压暗，叠在光带上就是起伏；
    /// `phase` 随时间推移 = 波纹在上下走。开销与原来同一量级（实测见 README 开销表）。
    ///
    /// 可调参数（都在函数里，改完 `./build.sh` 即可）：
    /// - `bands`  竖直方向上有几道波纹（越大越密；1.1 ≈ 上下一道明 + 一道暗）
    /// - `travel` 一相位周期（12 秒）内波纹上下走几道 —— 越大越快
    /// - `strength` 起伏强度（明暗幅度）：0.10 很含蓄、0.18 明显、0.30 会有点晃眼
    /// - `waveAngle` 渐变轴的角度：**必须接近 90°（竖直）**，条纹才是横着的、随时间上下走；
    ///   90° 完全水平如百叶窗，偏一点更像水波。⚠️ 一开始写成 14°（接近横向），
    ///   结果等于又叠了一层横向条纹、竖向几乎没有起伏（离屏量测的竖向落差只有 0.02~0.04）。
    static func drawRipple(size: NSSize, phase: Double?) {
        guard let phase else { return }
        let bands: CGFloat = 1.1
        let travel: CGFloat = 2.0
        let strength: CGFloat = 0.18
        let waveAngle: CGFloat = 78
        let samples = 12

        var colors: [NSColor] = []
        var locations: [CGFloat] = []
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            let s = sin(2 * .pi * (u * bands + CGFloat(phase) * travel))
            // 正半周提亮、负半周压暗：一个正弦就是一明一暗一道波纹
            colors.append(s >= 0 ? NSColor(white: 1, alpha: s * strength)
                                 : NSColor(white: 0, alpha: -s * strength))
            locations.append(u)
        }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)?
            .draw(in: path, angle: waveAngle)
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
