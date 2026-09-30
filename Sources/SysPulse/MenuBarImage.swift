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
    /// ⚠️ **周期刻意取互不相同且互不整除的值**（12.7 / 9.3 / 15.1 / 11.9 / 13.7 / 10.3 秒）。
    /// 如果取成相同的周期，所有光斑会一起回到起点，整条每隔一个周期就"重来一次"，
    /// 规律感立刻回来 —— 那正是要避免的。
    ///
    /// 实现成本：每个光斑**一次** `NSGradient.draw`（径向），6 个光斑 = 6 次填充。
    /// 对比 `drawGlow` 的 1 次横向渐变 + `drawRipple` 的 1 次，同量级。
    /// 注意整条动效的真实开销不在绘制（实测 0.13ms/帧），而在"每帧换一张状态栏图片"
    /// 那笔系统开销 —— 见 `contentKey` 的注释。
    static func drawDiffuse(size: NSSize, elapsed: Double) {
        let rect = NSRect(origin: .zero, size: size)
        // 裁到圆角胶囊里：光斑半径（1.3~1.7 倍条高）故意比条大，中心也游走出条外，
        // 不裁的话圆形渐变的直角边缘会在胶囊圆角处露出来。
        // 实测这个 `saveGraphicsState` + `addClip` 的开销可忽略（裁剪路径本身很便宜，
        // 真正的成本在"每帧换一张状态栏图片"那笔系统开销上）。
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: size.height / 2, yRadius: size.height / 2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        struct Blob {
            /// 基准位置（相对条宽 / 条高的比例）
            let baseX: CGFloat, baseY: CGFloat
            /// 游走半径（相对条宽 / 条高的比例）
            let ampX: CGFloat, ampY: CGFloat
            /// 方向相位（弧度）：决定它往哪个方向偏，各个不同
            let angle: CGFloat
            /// 走完一圈的秒数。**各不相等**是"不规律"的关键
            let period: Double
            /// 光斑半径（相对条高），1 以上意味着比条还高、更柔
            let radius: CGFloat
            /// 基准色相
            let hue: CGFloat
            /// 色相呼吸方向（+1 / -1）。相邻取相反值，让色相关系保持稳定，见 blobs 的注释
            let hueDrift: CGFloat
            /// 这个光点自己的时间相位偏移（0…1）。**互不相同**是关键，见 blobs 的注释
            let phaseOffset: Double
            /// 色相呼吸的相对幅度（0.6…1.4）。各光点不同，否则"同幅度只错相位"会留下
            /// 共模分量，整条平均仍会缓慢漂移。
            let amp: CGFloat
        }

        // ⚠️ **基准位置按等距铺满整条**（0.06 / 0.22 / 0.40 / 0.58 / 0.76 / 0.94）。
        //
        // 第一版把基准挤在 0.15~0.80、又给了较大的横向游走幅度，结果是
        // **整条迟迟铺不满**：光斑漂到条外时那一端直接是空的（实测首尾空隙最低到 0.00，
        // 也就是某一端完全没颜色），而中间又堆到 0.58 —— 用户看到的就是"颜色挤在中间一小块"。
        // 等距铺开之后，无论各光斑怎么游走，整条都始终有覆盖，只有**浓度**在起伏。
        //
        // 每段的游走方向仍各不相同（`angle`），所以观感依然"不拘方向"，不会变成规则流动。
        // ⚠️ **色相是一段"窄而缓"的坡**（0.58 → 0.74，跨约 58°），**不是整条色轮**。
        //
        // 第一版取 0.50(青) → 0.82(粉红)，跨 115°，用户反馈"颜色配比不好看、有点突兀、
        // 东一块西一块、融合感不够"。量化后确实：相邻取样点的**色相跳变均值 14.4~16.4°、
        // 峰值到 51°**，而流光只有 5.6~9.6° / 峰值 27.8° —— 差近一倍。
        // 现在把坡收窄到蓝紫→紫红，跳变向流光看齐。
        //
        // 另外每个光斑的 `hue` 都配了一个 `hueDrift`：**围绕自己的本色小幅呼吸**
        // （±0.06，约 ±22°），而且相位两两相反 ——
        // 相邻光斑反向漂移时，两者之间的色相**差**基本守恒，所以"谁是蓝、谁是紫"的关系
        // 保持稳定，只有整体在轻轻游移。第一版是所有光斑各自漂 ±0.22（±79°）且相位相同，
        // 于是相邻区域会各自跑到不相关的地方（紫旁边突然变青或粉）—— 这正是"突兀"的来源。
        // ⚠️ **基调：淡紫 / 淡粉 / 藕粉，低饱和 + 高透明度，要"清新通透"。**
        //
        // 参数是**扫描出来的**，不是猜的：固定色相扫 (alpha, saturation) 网格，
        // 看合成到深底后的 HSV，找"S 低（粉彩）+ V 够（看得见）"的甜点区 →
        // **alpha 0.30 / saturation 0.35 落在 S26% / V51%**，正是"浅而透"。
        //   alpha 更小（≤0.22）→ V 掉到 45% 以下，偏暗、不够"通透"；
        //   saturation 更高（≥0.55）→ S 上到 33%+，就滑向"浓"了。
        //
        // ⚠️⚠️ **但这里有个被测出来的物理冲突，别以为调参能解决**：
        // 本机菜单栏的**实际底色实测是 RGB(80,115,150) = H210°、饱和度已 44%**
        // —— 那是**壁纸透过菜单栏毛玻璃**的结果，不是中性深灰。粉彩叠在这种蓝底上，
        // **低浓度永远翻不过去**（实测：alpha 0.30 → 合成 H246° S21%，是"蓝灰"不是粉；
        // 要让 R 通道压过 B、看着像粉，alpha 得 ≥0.60）。
        // 所以"高透明度"和"看得出粉"在这台机器的这张壁纸上**不能同时满足**。
        // 现在的取值是折中：**淡紫端给低浓度**（在蓝底上呈紫、不脏），
        // **粉端给高浓度**（才翻得出粉）。若想更纯的粉，只能提高浓度、牺牲通透感；
        // 若想更通透，就得接受它偏蓝紫。
        // （参考：把菜单栏换成素色壁纸时底色会接近中性，那时低浓度就能显色。）
        // 色相取 `0.72 → 0.93`（= 259° 淡紫 → 335° 淡粉），中间经过 302°/317° 的藕粉，
        // 所以整条是 淡紫 → 藕粉 → 淡粉 的连续坡，不是几个独立颜色。
        //
        // ⚠️ **深色底上做浅色，必须靠低 alpha**：这既是"通透"的来源，也是唯一能
        // 让浅色不与白字打架的办法。粉彩 = 浅色 + 低饱和 + 低不透明度，三者缺一不可。
        //
        // 以下是之前按小米 HyperOS 启动图（8×8 网格实测：明度 90~100%、饱和度仅 7~18%、
        // 色相左上 320~328° 粉紫 → 右下 226~256° 蓝）校准时的记录，保留备查：
        //
        // 那张图的 8×8 网格实测：**明度 90~100%（几乎是白的）、饱和度仅 7~18%**，
        // 色相**左上 320~328°（粉紫）→ 右下 226~256°（蓝）**，是一条对角走向的极淡粉彩。
        //
        // 但菜单栏是**深色底 + 白字**（系统外观），照搬那个亮底会把文字涂掉。
        // 所以按用户决定：**保留暗底，取它的色相、把明度压到暗底上**。
        // 于是这里不是"照抄参考的 HSV"，而是"移植它的色相走向 + 把粉彩感翻译到暗底"：
        //   色相 0.90 → 0.65  =  324°(粉紫) → 234°(蓝)   ← 对齐参考的两个端点
        //   饱和度降到 0.90、不透明度大幅降到 0.26/0.13      ← 这才是"粉彩"，见下
        //
        // ⚠️ **不透明度是关键**：之前 alpha 给到 0.58/0.30，合成到深底上是
        // H219~264° / S36~46% / V31~53% —— 又冷又艳，等于把深底涂成实色，
        // 恰恰不是粉彩。粉彩 = 浅色 + 低饱和 + **低不透明度**，三者缺一不可。
        // 现在合成后落在 S30~40% / V35~45%，是"暗底上浮着粉紫→蓝的柔雾"。
        // 校准过程记录：alpha 0.26/0.13 时合成只有 V22~26%（比原版还暗，会"看不见"）；
        // 0.40/0.20 配 brightness 1.0 才落到目标区间。
        // 六个**基准**光斑的参数。用的时候按条的宽高比在它们之间插值取样
        // （见下面的 blobs 构造），而不是固定画 6 个 —— 原因见 `radiusY` 处的注释。
        let baseBlobs: [Blob] = [
            Blob(baseX: 0.06, baseY: 0.50, ampX: 0.05, ampY: 0.32, angle: 0.00, period: 12.7, radius: 1.95, hue: 0.72, hueDrift:  1, phaseOffset: 0, amp: 1.0),
            Blob(baseX: 0.22, baseY: 0.46, ampX: 0.06, ampY: 0.36, angle: 1.15, period:  9.3, radius: 1.85, hue: 0.78, hueDrift: -1, phaseOffset: 0, amp: 1.0),
            Blob(baseX: 0.40, baseY: 0.54, ampX: 0.05, ampY: 0.34, angle: 2.40, period: 15.1, radius: 2.00, hue: 0.84, hueDrift:  1, phaseOffset: 0, amp: 1.0),
            Blob(baseX: 0.58, baseY: 0.48, ampX: 0.06, ampY: 0.38, angle: 3.60, period: 11.9, radius: 1.90, hue: 0.88, hueDrift: -1, phaseOffset: 0, amp: 1.0),
            Blob(baseX: 0.76, baseY: 0.52, ampX: 0.05, ampY: 0.32, angle: 5.10, period: 13.7, radius: 1.95, hue: 0.91, hueDrift:  1, phaseOffset: 0, amp: 1.0),
            Blob(baseX: 0.94, baseY: 0.47, ampX: 0.05, ampY: 0.36, angle: 4.30, period: 10.3, radius: 1.85, hue: 0.93, hueDrift: -1, phaseOffset: 0, amp: 1.0),
        ]

        // 光斑数量随**宽高比**增加：窄条（两行档）少放几个，宽条（单行档）多放几个。
        // 每拍要画几次径向渐变 —— 实测 `drawGlow + drawRipple` 单次才 0.132ms，
        // 而这笔开销与"每帧换一张状态栏图片"的 ~8ms 相比可以忽略，所以多画几个无所谓。
        let aspect = size.width / max(size.height, 1)
        let count = max(2, min(4, Int((aspect / 4.0).rounded())))
        let blobs: [Blob] = (0..<count).map { i in
            // 在六个基准参数之间均匀取样（首尾相接，所以 6 个时就是原样）
            let t = Double(i) / Double(count) * Double(baseBlobs.count)
            let i0 = Int(t) % baseBlobs.count
            let i1 = (i0 + 1) % baseBlobs.count
            let f = CGFloat(t - Double(Int(t)))
            let a = baseBlobs[i0], b = baseBlobs[i1]
            func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
            return Blob(
                baseX: Double(i) / Double(count) + 0.5 / Double(count),   // 等距铺满
                baseY: lerp(a.baseY, b.baseY),
                ampX: lerp(a.ampX, b.ampX),
                ampY: lerp(a.ampY, b.ampY),
                angle: lerp(a.angle, b.angle),
                period: a.period + (b.period - a.period) * Double(f),
                radius: lerp(a.radius, b.radius),
                hue: lerp(a.hue, b.hue),
                hueDrift: (i % 2 == 0) ? 1 : -1,
                // **均匀铺开**且**关于 0.5 对称**（0, 1/N, …, (N-1)/N）——
                // 这样各点的 sin 之和在任意 phase 下都接近 0，整条平均色相才会稳住
                // （黄金分割比虽然分散均匀，但它对 0.5 有系统偏差，整条平均会缓慢漂 20°+）。
                phaseOffset: Double(i) / Double(count),
                // 各光点幅度也不同（0.6…1.4，用不可通约的步长散开）：
                // 幅度相同时各点只是"错相位"，叠加后仍有共模分量 → 整条平均照样漂；
                // 幅度也散开才是真正的"各自漫散"。
                amp: 1.0 + 0.4 * CGFloat(sin(Double(i) * 2.399963))
            )
        }

        for blob in blobs {
            let theta = 2 * .pi * CGFloat(elapsed / blob.period) + blob.angle
            let cx = (blob.baseX + cos(theta) * blob.ampX) * size.width
            let cy = (blob.baseY + sin(theta * 1.31) * blob.ampY) * size.height

            // ⚠️ **每个光点各自变化，不要让整条色带一起变。**
            //
            // 这条弯路走了三次，用户的原话正好把它们串起来：
            //   · "东一块西一块、融合感不够" —— 光点**同向**各自大幅漂 ±0.22（±79°），
            //     相邻区域的色相关系不停重组，局部就会突然跳色；
            //   · 改成"相邻反相 ±0.06" —— 融合了，但**反相会互相抵消**，
            //     整条平均只摆 ±7°，被反馈成"固定颜色了，不会再变色"；
            //   · 我于是改成"整条同向一起游走" —— 颜色是动了，但用户立刻指出
            //     "怎么是整条色带在整体变化？我想要的不是漫散射吗？"
            //     **那是整体换色，不是漫散射**。方向本身就错了。
            //
            // 正确的做法（现在）：给每个光点一个**自己的时间相位** ——
            //   `wave = phase + 该光点的固定相位偏移`（黄金分割比 0.618 铺开，互不相同）。
            //   ⚠️ **不要用"位置×波长"来生成相位**：波长长则所有点相位挨得近、一起动
            //   （实测整条平均还摆 26~44°，用户看到的就是"整条色带在整体变化"）；
            //   波长短则相邻点反相、互相抵消（实测每点摆幅掉到 25°）。
            //   固定且互不相关的偏移才能既让每个点独立变化、又让整条平均稳住。
            // 这样每个光点轮流发光、色相各自呼吸，**而相邻光点的色相差随时间变化**，
            // 于是"哪个点偏紫、哪个点偏粉"会缓慢互换 —— 正是"从内而外的漫散"。
            // 整条的平均色相基本不变（各自都在本色附近呼吸，只是不同步），
            // 所以既不会变成整条换色，也不会互相抵消到看不见。
            // ⚠️ **每个光点用自己的周期**，不是"同一个节奏错开起点"。
            //
            // 之前所有光点共用全局 `phase`（只让起点错开），它们仍然是**耦合**的 ——
            // 实测整条平均色相还在缓慢漂 37°，用户看得出"整条在变"。
            // 现在用 elapsed / 各自的 period 算**自己的相位**：period 在 9.3~15.1 秒之间
            // 各不相同，于是各光点**互不同步、且不会长期同步回来**（周期不可通约），
            // 这才是真正的"各自漫散"。
            //
            // 注意：整条平均色相会随之缓慢起伏（各光点周期不同、无法严格抵消），
            // 但那是"各自的相位关系在变化"，不是"整条一起变" —— 观感上后者才叫色带整体变化。
                        //
            // `phase` 是 0…1 的全局相位，乘上全局周期就得到"已经过了多少秒"；
            // 再除以这个光点自己的 period，就是它自己的相位。
            // ⚠️ 两个周期必须**不可通约**（这里 9.3~15.1 与全局 12 秒都不是整数倍关系），
            // 否则它们会周期性地重新同步成"一起变"。
            let selfPhase = elapsed / blob.period + blob.phaseOffset
            let pulse = CGFloat(sin(2 * .pi * selfPhase))

            // 色相：围绕本色呼吸，幅度够大才看得见；相位由上面的 wave 决定（每个点不同步）
            let hueDriftAmount: CGFloat = (count >= 8 ? 0.18 : (count >= 5 ? 0.14 : 0.10)) * blob.amp
            var hue = blob.hue + hueDriftAmount * pulse
            hue = hue.truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }

            // 亮度/浓度也跟着脉动：脉冲为正时更亮更实 —— 这就是"从内向外发光"的那一下。
            // 与色相同一个 wave，所以一个光点变亮时它的色相也正在偏离本色，观感是"活的"。
            let alphaScale = 0.80 + 0.32 * pulse
            // 半径也随时间脉动 —— 这是"从内而外"的关键：光点会自己涨大、缩小，
            // 而不是只有颜色在变。`0.85 + 0.3*pulse` 的取值范围 0.55~1.15，
            // 与色相共用同一个 selfPhase，所以一个光点"涨起来"时它的颜色也正在偏离本色。
            let breathe = 0.85 + 0.30 * pulse
            let radiusX = blob.radius * size.height * 0.85 * breathe
            let radiusY = blob.radius * size.height
            // `NSGradient` 只能画**圆**，要椭圆得靠 CTM 横向缩放（见下）。
            // 基准圆取纵向半径，横向压扁比例 = radiusX / radiusY。
            let scaleX = radiusX / max(radiusY, 0.001)
            // 径向渐变：中心最浓 → 中段渐隐 → 边缘完全透明，就是"柔和的光斑"。
            // 三段是为了让衰减接近高斯，只有两段会看出生硬的边界。
            let stops: [(CGFloat, CGFloat)] = [
                (0.00, 0.62 * alphaScale),
                (0.45, 0.30 * alphaScale),
                (1.00, 0.00)
            ]
            let colors = stops.map { NSColor(hue: hue, saturation: 0.55, brightness: 1.0, alpha: $0.1) }
            let locations = stops.map { $0.0 }

            // 归一化空间画法：先把 CTM 映射到「单位正方形 → size」，那么横向压扁
            // 就与条的实际宽高比无关，`scaleX` 的含义保持稳定（否则每种排版档位
            // 都要重算一遍系数）。裁剪路径是之前在当前 CTM 下设置的，仍按设备坐标生效。
            NSGraphicsContext.saveGraphicsState()
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.scaleBy(x: size.width, y: size.height)
                cg.translateBy(x: cx / size.width, y: cy / size.height)
                cg.scaleBy(x: scaleX, y: 1)
                let normalizedRadius = radiusY / max(size.height, 0.001)
                NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)?
                    .draw(fromCenter: .zero, radius: 0,
                          toCenter: .zero, radius: normalizedRadius, options: [])
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
