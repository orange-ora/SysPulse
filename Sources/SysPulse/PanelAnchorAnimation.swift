import AppKit
import QuartzCore

/// 把面板锚点在 `duration` 内从 `from` 平滑推到 `to`（ease-out），逐帧回调。
///
/// 为什么不用别的办法（都在 2026-09-16 试过或核对过）：
/// - `NSWindow.animator().setFrame(...)`：面板是平滑了，但**箭头不会跟**（箭头由系统按锚点绘制），
///   而且动画结束再 `show` 会把窗口弹回锚点（实测跳 200pt）；
/// - `Timer`：挂在主 runloop 上会被流光帧挤后，实测 0.22 秒只出 5 个中间帧；
/// - `CVDisplayLink`：能用（上一版就是这么调通 60fps 的），但 macOS 15 起已被标记弃用，
///   用它会让编译出现告警（本项目要求 0 告警）。
///
/// 现在用官方替代品 `NSWindow.displayLink(target:selector:)`（macOS 14 起可用）：
/// 回调在主线程、与显示器刷新同步，`CADisplayLink` 直接给出帧时间戳。
final class PanelAnchorAnimation {
    private let from: CGFloat
    /// 本次动画的终点（锚点在屏幕上的横坐标）。外面用它判断"新的目标是不是同一个"。
    let target: CGFloat
    private let duration: CFTimeInterval
    private let onFrame: (CGFloat) -> Void
    private let onFinish: (() -> Void)?

    private var link: CADisplayLink?
    private var startTimestamp: CFTimeInterval = 0

    init(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
         onFrame: @escaping (CGFloat) -> Void, onFinish: (() -> Void)? = nil) {
        self.from = from
        self.target = to
        self.duration = max(duration, 0.01)
        self.onFrame = onFrame
        self.onFinish = onFinish
    }

    /// 在指定窗口所在的显示器上起跑。**先摆一次起点**：换档时系统会抢先把面板按中间态
    /// 摆错一次，这一帧要在同一轮 runloop 里被覆盖掉，才不会"先跳一下再滑"。
    func start(in window: NSWindow) {
        onFrame(from)
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        if startTimestamp == 0 { startTimestamp = link.timestamp }
        let raw = (link.timestamp - startTimestamp) / duration
        let t = min(max(raw, 0), 1)
        // ease-out cubic：起步快、收尾轻，落位时速度趋近 0，观感"贴"上去
        let eased = 1 - pow(1 - t, 3)
        // 最后一帧**精确落到终点**，不要留插值残差（箭头必须对准图标中心）
        onFrame(t >= 1 ? target : from + (target - from) * eased)
        if t >= 1 {
            cancel()
            onFinish?()
        }
    }
}
