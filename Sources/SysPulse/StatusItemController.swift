import AppKit
import Combine
import SwiftUI


/// 状态栏项 + 下拉面板的控制器。
///
/// 位置由系统统一排版（从右往左挤），右侧空间不足时会自动降级成更窄的档位。
///
/// 曾经尝试用自绘窗口把读数钉在刘海左侧以获得固定位置，但菜单栏层的自绘窗口
/// **收不到点击**（窗口在最前面、`ignoresMouseEvents = false`，仍然一个鼠标事件
/// 都收不到），会导致面板打不开，因此回到系统状态栏项方案。
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor = SystemMonitor()
    private let preferences = Preferences.shared
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    /// 自己维护的开关状态：popover.isShown 在开合动画期间会滞后，不能用来判断
    private var isPanelOpen = false
    /// 上一次 `popover.show` 用的锚点矩形，用来判断锚点是否真的动了
    private var lastAnchorRect: NSRect?
    /// 上一次看到的**状态栏窗口 frame**（观测用）。窗口一变就说明系统在动它。
    ///
    /// ⚠️ 它必须和"上次用来定位的 frame"（`lastStatusWindowFrame`）**分开**：
    /// 曾经共用一个变量、并且只在"真的执行了定位"时才记账，结果去抖期间每次重绘
    /// 都拿**旧基准**和当前 frame 比 → 同一个 frame 被反复判定成"又变了" →
    /// 去抖被无限刷新，只能靠上限强制（实测等了 442ms 才定位，中间态还多停了一会儿）。
    /// 现在：观测到变化立刻记账，于是第一次变化只调度一次去抖，等待期间不再刷新。
    private var lastSeenStatusWindowFrame: NSRect?
    /// 上一次**真正用于定位**的 frame。
    private var lastStatusWindowFrame: NSRect?
    /// 待执行的"重新锚定"任务。系统换档时会**分两拍**改状态栏窗口（见 `syncPanelAnchor`），
    /// 每一拍都去重锚就会形成"先反向跳一下、再跳到正确位置"，所以这里做去抖：
    /// 观测到变化后等窗口稳定 `anchorSettleDelay` 再定位一次。
    private var pendingAnchorWork: DispatchWorkItem?
    private var pendingAnchorSince: Date?
    /// 去抖窗口：只等到"系统排完版"就够，不能等更久。
    ///
    /// 系统换档时会在改**宽度**的同时自行把面板挪到一个中间位置（实测面板
    /// 947→902），要等它再改完 **x** 才轮到我们定位。这段等待有多长，用户就会
    /// 在那个中间位置停留多久——所以这个值要**刚好覆盖两拍间隔**（实测 45ms～110ms），
    /// 取大了反而把中间态停留时间一起拉长（曾经取 180ms，实测停留 181ms，非常显眼）。
    /// 取 60ms（约等于流光一帧）：只作为**预测不命中时**的兜底等待。
    private let anchorSettleDelay: TimeInterval = 0.06
    /// 兜底：万一窗口确实在持续变化，最多推迟这么久就按当前值定位一次
    private let anchorMaxDefer: TimeInterval = 0.3
    /// 重新定位的定时器：`popover.show` 在面板已显示时**有时会被系统整个忽略**
    /// （实测 `before=902 after=902`），单次调用不可靠。所以用一个短周期定时器
    /// **反复核对、直到面板真的落到目标位置**（最多 `relocateDeadline`）。
    private var relocateTimer: Timer?
    private var relocateTarget: NSRect?
    private var relocateDeadline: Date?
    /// 拖动校正的最长时间：超过就放弃，避免面板被反复打扰
    private let relocateMaxDuration: TimeInterval = 0.5

    /// 对"系统还会再改一次 x"的预测（纯优化，猜错会被下一拍纠正）。
    ///
    /// 实测规律：系统换档时**先改宽度、并保持窗口右边缘不动**，过一会儿才把 x 挪到
    /// 最终位置；此时"中间态"满足 `minX + width == 上一拍的右边缘`。命中这个规律就能
    /// 直接算出最终 x（`右边缘 − 新宽度`）一次定位到位，用户看不到中间态。
    /// ⚠️ 这个规律**只在第二拍出现时成立**：实测第一拍（刚改宽度那一拍）右边缘会短暂
    /// 不守恒，那一拍预测不出来，只能靠 `anchorSettleDelay` 等——中间态于是会存在
    /// 约 40ms（系统自己两拍之间的间隔），无法再压缩。
    private var predictedSettledFrame: NSRect?
    /// 动画进行中收到的点击先记账，等动画结束再补上，避免被系统忽略
    private var pendingToggle = false
    private var isAnimating = false

    /// 由宽到窄的档位顺序
    private let densityOrder: [MenuBarDensity] = [.full, .compact, .minimal]
    /// 实测得到的当前档位下标；nil 表示还没测量过，先按用户选择的上限渲染
    private var measuredDensityIndex: Int?
    /// 各档位实测过的最大图片宽度，用来判断"升档是否放得下"
    private var densityWidths: [CGFloat] = [0, 0, 0]
    /// 流光效果的定时器与当前相位（0…1）
    private var glowTimer: Timer?
    private var glowPhase: Double = 0
    /// 最近几次采样到的状态栏项左边缘位置。
    ///
    /// 为什么需要它：系统在菜单栏拥挤时会把状态项**挪到极左的折叠区**，此时读到的
    /// `window.frame.minX` 会突然变得很小（实测在 956 与 513 之间跳，对应余量
    /// −31.5 与 −474.5）。如果直接用"这一次"的 minX 判断余量，就会把系统的过渡位置
    /// 当成"完全放不下"而误降档。用最近几次的最大值既保守又抗这种瞬时跳变。
    private var recentMinX: [CGFloat] = []
    /// 上一次升降档的时间：切换后先冷却一段时间再重新判定，避免自激
    private var lastDensityChangeAt: Date?
    private let densityCooldown: TimeInterval = 2.0
    /// 升档需要多留的余量（pt）：必须明显大于"降档带来的余量增量"，否则会来回横跳
    private let densityUpgradeBuffer: CGFloat = 14

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // 不能用 .transient：点状态栏图标时系统会先把弹窗当成"点了外部"自动关掉，
        // 紧接着按钮事件才到达，此时 isShown 已经是 false，于是又被重新打开——
        // 表现就是怎么点都关不上。改用 .applicationDefined 自己管外部点击，状态才可控。
        popover.behavior = .applicationDefined
        // 动画关掉：NSPopover 的动画由系统绘制，帧率观感不佳（发卡），
        // 而且时长不可调。关掉后展开只要约 110ms，跟手得多。
        popover.animates = false
        popover.delegate = self

        // 点到别的 App / 桌面就收起。
        // 注意：状态栏项的窗口属于 WindowServer，对全局监听来说也算"别的 App"，
        // 所以必须排除落在图标自身区域内的点击，否则每次点击都会先被这里关掉、
        // 再被按钮 action 重新打开，表现为"快速连点被吞"。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            if self.isPointOnStatusItem(NSEvent.mouseLocation) { return }
            self.closePopoverIfShown()
        }


        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateStatusItem(with: snapshot)
            }
            .store(in: &cancellables)

        // 任何偏好变化都要立刻按新设置重画状态栏项
        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.updateStatusItem(with: self.monitor.snapshot)
                }
            }
            .store(in: &cancellables)

        // 只有刷新频率变了才重启定时器。
        // 之前是"任何偏好变化都重启"，于是改一个显示项会在极短时间内把状态栏重画两次
        // （立刻一次 + 刚重启的定时器紧接着又一次），看起来就像闪了两下。
        preferences.$refreshInterval
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.monitor.restartTimer()
            }
            .store(in: &cancellables)

        monitor.start()

        // 流光效果：只在开启时跑一个 15fps 的轻量定时器。
        // 注意它**只重画那一层渐变**（`MenuBarImage.drawGlow`），文字的排版与绘制仍然
        // 只跟着数据刷新走；关掉开关就立刻停表，不留常驻开销。
        preferences.$menuBarGlow
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.startGlowTimer() } else { self.stopGlowTimer(); self.updateStatusItem(with: self.monitor.snapshot) }
            }
            .store(in: &cancellables)
        if preferences.menuBarGlow { startGlowTimer() }

    }

    private func startGlowTimer() {
        guard glowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.glowPhase = (self.glowPhase + 1.0 / (15.0 * 12.0)).truncatingRemainder(dividingBy: 1)
            self.updateStatusItem(with: self.monitor.snapshot, allowLayoutChange: false)
        }
        timer.tolerance = 1.0 / 60.0
        RunLoop.main.add(timer, forMode: .common)
        glowTimer = timer
    }

    private func stopGlowTimer() {
        glowTimer?.invalidate()
        glowTimer = nil
        glowPhase = 0
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    /// 判断某个屏幕坐标点是否落在状态栏图标上
    private func isPointOnStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frameInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frameInScreen.contains(point)
    }

    /// 收起面板（外部点击、菜单选项选完都走这里）。
    ///
    /// 注意：菜单项刚被点击时 `NSMenu` 还在收尾，直接 `performClose` **不会失效但也不会
    /// 立刻从屏幕消失**（实测 `isShown` 立刻变 false，窗口却还在），所以丢到下一个 runloop
    /// 再关，让菜单先收干净。
    func closePopoverIfShown() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPanelOpen || self.popover.isShown else { return }
            self.isPanelOpen = false
            self.isAnimating = true
            self.popover.performClose(nil)
        }
    }

    @objc private func screenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatusItem(with: self.monitor.snapshot)
        }
    }

    // MARK: - 交互

    @objc private func togglePopover(_ sender: Any?) {
        // 开合动画进行中，系统会忽略反向操作；这里先记下这次点击的净效果，
        // 等 popoverDidShow / popoverDidClose 到达时再补上，点击就不会丢。
        guard !isAnimating else {
            pendingToggle.toggle()
            return
        }
        applyToggle()
    }

    private func applyToggle() {
        if isPanelOpen {
            isPanelOpen = false
            isAnimating = true
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        // 面板内容按需创建：NSHostingController + 整个 SwiftUI 视图树（含窗口图层）
        // 实测要占 35MB 左右，而且关掉之后系统也不回收，还会每秒跟着数据重绘。
        // 所以关闭时释放，下次打开再建（历史曲线在 SystemMonitor 里，不受影响）。
        if popover.contentViewController == nil {
            // 底部三个菜单里选完任一项就收起整个面板：菜单（NSMenu）自己会关，
            // 但面板是独立的 NSPopover，不主动收就会留在屏幕上挡视线。
            let view = DashboardView(
                monitor: monitor,
                preferences: preferences,
                onMenuSelection: { [weak self] in
                    self?.closePopoverIfShown()
                }
            )
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
        }

        // 关键：先激活 App。状态栏 App 平时不是活动 App，否则面板里的第一次点击会被
        // 系统用去「激活 App + 让弹窗成为 key window」，这一次点击不会传给控件。
        isPanelOpen = true
        isAnimating = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorRect(for: button), of: button, preferredEdge: .minY)
        lastAnchorRect = anchorRect(for: button)
        // 初始定位用的是当前 frame：观测基准与定位基准一起记账，
        // 这样面板刚打开时不会被"误判成刚变化"而白等一次去抖。
        lastStatusWindowFrame = button.window?.frame
        lastSeenStatusWindowFrame = lastStatusWindowFrame
        pendingAnchorWork?.cancel()
        pendingAnchorWork = nil
        pendingAnchorSince = nil
        popover.contentViewController?.view.window?.makeKey()
    }

    /// 面板箭头锚定的矩形。
    ///
    /// 直接返回 `button.bounds`：这是 `NSPopover` 的标准用法，系统会把面板居中在这个矩形上、
    /// 箭头对准矩形中心。
    private func anchorRect(for button: NSStatusBarButton) -> NSRect {
        button.bounds
    }

    /// 面板开着时，只要**状态栏窗口的 frame 变了**，就把面板重新锚定到新的图标中心。
    ///
    /// - `NSPopover` **不会跟着锚点自己走**：图标宽度变了，面板停在原地；实测甚至会反向跑
    ///   （图标中心左移 54pt、面板右移 54pt，偏差 +107.5pt，箭头直接指到图标边缘）。
    /// - 触发条件用"**窗口 frame 变化**"，而不是定时/延时猜测：窗口 frame 变了就是
    ///   "系统已经在挪它"的最直接证据。这个检查每次重绘都会跑（含流光的 15fps 帧），
    ///   所以窗口一挪动就能在一帧内跟上；没变化时只是一次 rect 比较。
    /// - ⚠️ **必须去抖，不能一看到 frame 变了就定位**（2026-09-16 定位到根因并修复）：
    ///   系统换档（显示项开关、启动升档）时**分两拍**改状态栏窗口——
    ///   先改**宽度**（`x` 暂时不动），过一会儿才把 `x` 挪到最终位置。3ms 采样实测：
    ///   ```
    ///   t=2.028  w 119→121        （先动一点点）
    ///   t=2.072  x 1104→1102, w→229   ← 中间态：新宽度 + 旧 x，锚点中心算出来是错的
    ///   t=2.138  x →994               ← 最终位置
    ///   ```
    ///   若在"中间态"定位一次，用户看到的就是"箭头先向左跳一下、再跳到右边"。
    ///   这里改成：**观测到变化先记账**（和"上次定位用的 frame"分开记），
    ///   再用两种手段避开中间态：
    ///   1. **能预测就直接跳到最终位置**——若这一拍的宽度变了、且窗口右边缘与上一拍
    ///      相同，就按"右边缘守恒"算出最终 x（`右边缘 − 新宽度`），一次定位到位。
    ///      实测这个预测与系统最终给出的 x 完全一致（994 / 1039 都对上），
    ///      真实场景下"面板换档"只剩**一次**移动，中间态根本不出现。
    ///   2. **预测不了就等 `anchorSettleDelay`（60ms）再定位**（兜底还有 `anchorMaxDefer`）。
    ///      注意等待期间**不要重置计时**：在 15fps 重绘下每 67ms 就被推后一次，
    ///      会永远等不到，只能靠上限强制（实测拖到 442ms，中间态反而停得更久）。
    ///   分开记账是关键：共用"上次定位用的 frame"会让同一个 frame 被反复当成新变化。
    /// - 这里**不做位移动画**（曾经用 CVDisplayLink 逐帧插值锚点做过，已按需求回滚）：
    ///   `popover.show` 到新锚点是一帧到位。想要平滑滑动只能放弃 `NSPopover` 自绘面板。
    private func syncPanelAnchor() {
        guard let button = statusItem.button, let win = button.window else { return }
        let frame = win.frame
        let frameChanged = (lastSeenStatusWindowFrame != frame)
        lastSeenStatusWindowFrame = frame

        guard isPanelOpen else { return }

        // 兜底：窗口持续变化时去抖等不到"稳定"，到点就按当前值强制定位一次
        enforceAnchorDeadlineIfNeeded()

        if frameChanged {
            // 命中"系统还会再改一次 x"的规律时，直接按最终 x 定位，一次到位。
            // 判据只看"宽度变了"——宽度的变化本身就说明系统还在排版，那就是中间态。
            // ⚠️ 不要要求"右边缘与上一拍严格相等"：图标**减少**的方向上系统会先带一个
            // 约 −5pt 的偏移（实测右边缘 1223→1218），条件一严格就漏判，
            // 面板便会被系统按中间态挪走——用户看到的正是"面板往右移时会先向左跳一下"。
            if let shown = lastStatusWindowFrame,
               frame.width != shown.width {
                var predicted = frame
                predicted.origin.x = shown.minX + shown.width - frame.width
                predictedSettledFrame = predicted
                lastSeenStatusWindowFrame = predicted
                pendingAnchorWork?.cancel()
                pendingAnchorWork = nil
                pendingAnchorSince = nil
                showPanel(at: predicted, button: button)
                return
            }
            // 没有把握就只能等：已经有待执行的任务就**不要重置计时**，
            // 稳定 `anchorSettleDelay` 后自然执行。反复刷新的话，在 15fps 重绘下
            // 会永远等不到（每 67ms 就被推后一次）。
            // 到这里说明当前 frame 没有被预测覆盖，预测要么已过期要么是错的——丢掉。
            predictedSettledFrame = nil
            if pendingAnchorWork == nil {
                if pendingAnchorSince == nil { pendingAnchorSince = Date() }
                scheduleAnchorWork()
            }
            return
        }

        // 窗口已经稳定在这个 frame：如果上次定位用的不是它，才需要补一次定位。
        guard lastStatusWindowFrame != frame else { return }
        if pendingAnchorWork == nil {
            if pendingAnchorSince == nil { pendingAnchorSince = Date() }
            scheduleAnchorWork(delay: 0)
        }
    }

    /// 安排一次（去抖后的）重新锚定。延迟执行期间若已有任务在等，不重复安排。
    private func scheduleAnchorWork(delay: TimeInterval? = nil) {
        guard pendingAnchorWork == nil else { return }
        let wait = delay ?? anchorSettleDelay
        let work = DispatchWorkItem { [weak self] in self?.runPendingAnchorWork() }
        pendingAnchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func runPendingAnchorWork() {
        pendingAnchorWork = nil
        pendingAnchorSince = nil
        guard isPanelOpen, let btn = statusItem.button else {
            return
        }
        // 优先用预测的落定 frame；没有预测就用当前 frame（此时窗口已经稳定）
        let settled = predictedSettledFrame ?? btn.window?.frame ?? .zero
        predictedSettledFrame = nil
        // 已经对着这个 frame 定位过（比如等待期间帧又回到原样）就不用再动
        guard lastStatusWindowFrame != settled || lastSeenStatusWindowFrame != settled else {
            return
        }
        showPanel(at: settled, button: btn)
    }

    /// 以给定的状态栏窗口 frame 为中心重新锚定面板（一次到位，不做动画）。
    ///
    /// ⚠️ **面板已经显示时，`popover.show` 有时会被系统整个忽略**（2026-09-16 实测：
    /// 状态栏窗口刚被系统挪过之后，系统认为"面板还在正确位置"，调用前后面板 frame
    /// 完全相同）。所以这里不是"调一次就完事"，而是把目标记下来、由
    /// `startRelocateCorrection()` 反复校正到真的落位。
    private func showPanel(at frame: NSRect, button btn: NSStatusBarButton) {
        let rect = anchorRect(for: btn)
        popover.show(relativeTo: rect, of: btn, preferredEdge: .minY)
        lastAnchorRect = rect
        lastStatusWindowFrame = frame
        lastSeenStatusWindowFrame = frame
        startRelocateCorrection(aimingAt: frame)
    }

    /// 面板没落到目标位置时，用 16ms 的定时器反复重新锚定（每次都用**最新**的
    /// `button.bounds`，所以箭头始终居中），直到落位或超过 `relocateMaxDuration`。
    ///
    /// 为什么需要它：系统偶尔会吞掉 `popover.show`；单次重试也不够稳（实测会出现
    /// "箭头不居中"）。持续校正能同时解决"跳一下"和"不居中"两个问题。
    private func startRelocateCorrection(aimingAt winFrame: NSRect) {
        let target = expectedPanelFrame(for: winFrame)
        relocateTarget = target
        if relocateDeadline == nil { relocateDeadline = Date().addingTimeInterval(relocateMaxDuration) }
        guard relocateTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickRelocateCorrection()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        relocateTimer = timer
    }

    private func tickRelocateCorrection() {
        guard isPanelOpen, let btn = statusItem.button, let target = relocateTarget else {
            stopRelocateCorrection(); return
        }
        let current = popover.contentViewController?.view.window?.frame
        let reached = current.map { abs($0.minX - target.minX) < 1 } ?? false
        if reached || Date() >= (relocateDeadline ?? Date()) {
            stopRelocateCorrection(); return
        }
        popover.show(relativeTo: anchorRect(for: btn), of: btn, preferredEdge: .minY)
    }

    private func stopRelocateCorrection() {
        relocateTimer?.invalidate()
        relocateTimer = nil
        relocateTarget = nil
        relocateDeadline = nil
    }

    /// 给定的状态栏窗口 frame 对应的"面板应当落到的位置"（面板宽 368，箭头对准窗口中心）。
    ///
    /// ⚠️ 必须传入**我们认为系统最终会稳定到的那个 frame**，不能在这里重新读
    /// `statusItem.button?.window?.frame`：系统的窗口变动与我们的检测不同步，
    /// 实测重新读会读到"中间态"（mid=1086），算出的目标把面板校正到错误位置
    /// （表现为"箭头不居中"）。
    private func expectedPanelFrame(for winFrame: NSRect) -> NSRect? {
        guard winFrame.width > 0 else { return nil }
        let panelWidth = popover.contentViewController?.view.window?.frame.width ?? 368
        var f = winFrame
        f.origin.x = winFrame.midX - panelWidth / 2
        return f
    }

    /// 兜底：万一窗口长时间持续变化，去抖会一直等不到"稳定"，
    /// 到 `anchorMaxDefer` 就按当前值强制定位一次，避免完全不跟随。
    private func enforceAnchorDeadlineIfNeeded() {
        guard let since = pendingAnchorSince,
              Date().timeIntervalSince(since) >= anchorMaxDefer
        else { return }
        pendingAnchorWork?.cancel()
        pendingAnchorWork = nil
        runPendingAnchorWork()
    }

    func popoverDidShow(_ notification: Notification) {
        finishAnimation()
    }

    func popoverDidClose(_ notification: Notification) {
        isPanelOpen = false
        stopRelocateCorrection()
        // 丢掉还没执行的重新锚定任务，并清掉观测基准：下次打开时重新按当时的窗口算
        pendingAnchorWork?.cancel()
        pendingAnchorWork = nil
        pendingAnchorSince = nil
        lastSeenStatusWindowFrame = nil
        lastAnchorRect = nil
        finishAnimation()
        // 释放面板视图：不释放的话它会一直跟着数据每秒重绘，
        // 空闲 CPU 从 0.01% 涨到 0.05%。（窗口本身约 35MB 由 AppKit 持有，
        // 换掉弹窗对象也回收不了，只能等系统在内存紧张时压缩。）
        popover.contentViewController = nil
    }

    private func finishAnimation() {
        isAnimating = false
        guard pendingToggle else { return }
        pendingToggle = false
        applyToggle()
    }

    // MARK: - 状态栏

    /// - Parameter allowLayoutChange: 是否允许在本次调用里重新决定排版档位。
    ///   流光的定时器每帧都会调用这里，**必须传 false**——否则升降档会以 15Hz 反复触发，
    ///   测量值还没稳定就被下一次决策推翻，档位就会 full↔compact↔minimal 无限横跳。
    private func updateStatusItem(with snapshot: MetricsSnapshot, allowLayoutChange: Bool = true) {
        guard let button = statusItem.button else { return }

        let index = currentDensityIndex

        // 菜单栏外观跟着壁纸明暗走，状态栏项按钮是最可靠的取样点
        let appearance = button.effectiveAppearance
        let image = MenuBarImage.render(
            snapshot: snapshot,
            preferences: preferences,
            appearance: appearance,
            density: densityOrder[index],
            glowPhase: preferences.menuBarGlow ? glowPhase : nil
        )
        if let width = image?.size.width {
            densityWidths[index] = max(densityWidths[index], width)
        }
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = MenuBarImage.tooltip(snapshot: snapshot)

        // 只有"数据真的刷新了"这一次才允许重算排版档位。
        // 流光的定时器每帧也会调用这里（allowLayoutChange: false）——如果让它也触发
        // 升降档判定，就会以 15Hz 反复决策：测量值还没稳定就被下一次推翻，档位在
        // full↔compact↔minimal 之间无限横跳（实测每秒一轮，菜单栏看起来在"转"）。
        if allowLayoutChange {
            adaptToAvailableSpace()
        }

        // 图标宽度/位置可能变了（切显示项、换排版档位、**启动时自动升档**）：
        // 只要当前锚点和上次对齐用的不一致，就把面板重新锚定一次。
        //
        // 关键：这一步**不放在 `allowLayoutChange` 里、也不依赖"是谁触发的"**。
        // 之前放在换档逻辑里，于是"启动时两行档自动升成单行"会漏掉——
        // 升档发生在渲染之后，那次检查时窗口还是旧位置，之后就再没机会对齐
        // （实测偏差停在 +107.5pt，正是用户看到的"箭头还留在两行档的中间"）。
        // 做成每次重绘都跑的幂等操作后，窗口无论什么时候挪到位，下一拍就追上。
        syncPanelAnchor()
    }

    /// 用户选择的档位是「最宽上限」。「自动适应」从单行开始，放不下再逐级降。
    private var ceilingIndex: Int {
        switch preferences.menuBarLayout {
        case .auto, .full: return 0
        case .compact: return 1
        case .minimal: return 2
        }
    }

    /// 实际档位下标。
    ///
    /// 只有「自动适应」才会因为空间不足换用更窄的档位；用户明确选了某一档就一直用它，
    /// 空间不够时交给系统自己的收纳（菜单栏折叠箭头），这样单行样式不会被悄悄换掉。
    private var currentDensityIndex: Int {
        guard preferences.menuBarLayout == .auto else { return ceilingIndex }
        let measured = measuredDensityIndex ?? ceilingIndex
        return max(0, min(max(measured, ceilingIndex), densityOrder.count - 1))
    }

    private func resolvedDensity() -> MenuBarDensity {
        densityOrder[currentDensityIndex]
    }

    /// 菜单栏项只要跨进刘海区域就完全不会被绘制，而右侧剩余宽度会随其他 App 的图标增减。
    ///
    /// 这里读取上一次布局后的实际横坐标来决定档位。关键是**升档必须确认"更宽的那一档
    /// 真的放得下"**：只按余量判断的话，降档后条目变窄、左边缘右移、余量又变大，
    /// 于是立刻升回宽档，宽档又放不下——就会每秒左右横跳，宽档那一秒还会被刘海吞掉。
    private func adaptToAvailableSpace() {
        guard preferences.menuBarLayout == .auto,
              let window = statusItem.button?.window,
              window.frame.width > 0
        else { return }

        // 被刘海吞掉的条目拿不到 window.screen，这里退回带刘海的那块屏幕，
        // 否则一旦被挤进去就再也降不了级，永远显示不出来。
        let screen = window.screen
            ?? NSScreen.screens.first { $0.auxiliaryTopRightArea != nil }
            ?? NSScreen.main
        guard let screen, let safeArea = screen.auxiliaryTopRightArea else { return }

        // 记录本次采样，并用**最近几次的最大 minX** 算余量（见 recentMinX 的注释）
        recentMinX.append(window.frame.minX)
        if recentMinX.count > 5 { recentMinX.removeFirst() }
        let effectiveMinX = recentMinX.max() ?? window.frame.minX

        // 实测：刘海右侧还要再留约 40pt 余量，太贴近边缘时系统不会绘制
        let slack = effectiveMinX - (safeArea.minX + 40)

        // 刚切换过就等一会儿再判：切换会立刻改变图标宽度和左边缘，
        // 紧接着的那次测量是"切换中的过渡值"，拿它做决策必然自激。
        if let last = lastDensityChangeAt, Date().timeIntervalSince(last) < densityCooldown {
            return
        }

        // 从已实测档位出发决定目标档位（不用 currentDensityIndex——它会被 ceiling 夹住，
        // 用户换成固定档位时目标会算错）。
        func iconWidth(_ index: Int) -> CGFloat { densityWidths[min(max(index, 0), densityWidths.count - 1)] }

        var target = measuredDensityIndex ?? ceilingIndex


        // ① 太挤就降一级——**一次只降一级**，不要一路降到"放得下"为止。
        //    降级判断依赖"下一档的图标宽度"，而没渲染过的档位宽度是 0（未知）；
        //    一路降就会跳过中间档，导致那一档永远没被测量、之后再也升不回去
        //    （实测表现：冷启动后一路卡在极简档，两行档的宽度始终是 0）。
        if slack < 0, target < densityOrder.count - 1 {
            target += 1
        }
        // ② 想升档：要求"当前档"与"更宽那一档"**都已测量**（未测量的宽度是 0，
        //    算出来的 gain 不会是正数，自然就不会升——留在当前档渲染一次，下轮就测到了），
        //    且余量要比两档宽度差再多留 `densityUpgradeBuffer`（吃掉测量噪声，
        //    否则会"升上去又放不下→再降"来回跳）。
        //    ⚠️ gain 的变量顺序写反过（得到负数），后果是升档分支永远进不去，
        //    表现为"自动档明明有空间却永远停在窄档"。
        if target > ceilingIndex {
            let wider = target - 1
            let gain = iconWidth(wider) - iconWidth(target)
            // 关键：不能用"当前档的余量"去判断能不能升档。
            // 升档会多占 gain 宽度，左边缘会相应**左移 gain**——必须看**升档后的左边缘**
            // 还满不满足"离安全区至少 40pt"。
            // 实测反例：两行档时 minX=1072（余量 84.5，看着够），但升到单行要多占 108，
            // 左边缘落到 964 —— 比要求的 988 还靠左 24pt，属于画不出来的区域。
            // 用旧写法（`slack > gain + buffer`）就会误升，结果单行整条被刘海吞掉。
            let margin = safeArea.minX + 40
            if gain > 0, effectiveMinX - gain >= margin + densityUpgradeBuffer {
                target = wider
            }
        }

        if target != (measuredDensityIndex ?? ceilingIndex) {
            measuredDensityIndex = target
            lastDensityChangeAt = Date()
        }

    }

    /// 占用越高颜色越警示，平时保持系统主色以适配浅色 / 深色菜单栏。
    static func tint(for fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.80: return .labelColor
        case ..<0.92: return .systemOrange
        default: return .systemRed
        }
    }
}
