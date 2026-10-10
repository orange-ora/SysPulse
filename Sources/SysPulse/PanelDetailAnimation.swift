import AppKit
import QuartzCore
import SwiftUI

/// 详情的自然布局只在端点改变；显示帧只移动原生包装视图和窗口底边。
final class PanelDetailAnimation: NSObject, ObservableObject {
    @Published private(set) var reservesDetail: Bool
    private(set) var currentOffset: CGFloat = 0
    private(set) var frameStepCount = 0
    var isAnimating: Bool { link != nil || awaitingLayout }

    private weak var controller: PanelContentController?
    private weak var section: PanelDetailSectionView?
    private var targetExpanded: Bool
    private var reduceMotion = false
    private var initialized = false
    private var fullOffset: CGFloat = 0
    private var documentOffset: CGFloat = 0
    private var baseBodyHeight: CGFloat = 0
    private var chromeHeight: CGFloat = 0
    private var top: CGFloat = 0
    private var width: CGFloat = 0
    private var awaitingLayout = false
    private var awaitingCollapsedMeasurement = false
    private var sourceOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var sourceVisibility: CGFloat = 0
    private var visibility: CGFloat = 0
    private var startTimestamp: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.24
    private var link: CADisplayLink?
    private var generation = 0
    private var scheduledGeneration: Int?

    init(initiallyExpanded: Bool = false) {
        reservesDetail = initiallyExpanded
        targetExpanded = initiallyExpanded
        super.init()
    }

    /// 仅首次 Dashboard 构造调用；初始详情 fixture 不应播放用户操作动画。
    func initialize(expanded: Bool) {
        guard !initialized, section == nil else { return }
        targetExpanded = expanded
        reservesDetail = expanded
    }

    func attach(_ controller: PanelContentController) {
        self.controller = controller
        controller.bindDetailAnimation(self)
    }

    func request(expanded: Bool) {
        guard expanded != targetExpanded else { return }
        captureWindowGeometryIfNeeded()
        generation += 1
        scheduledGeneration = nil
        stopLink()
        targetExpanded = expanded
        awaitingCollapsedMeasurement = false
        awaitingLayout = true
        // 开启前先预留完整空间；关闭的占位直到显示终点才回收。
        if expanded && controller?.isPresentationSizingSuspended != true { reservesDetail = true }
        section?.setInteractive(expanded)
        if !expanded && !reservesDetail && currentOffset == 0 {
            awaitingLayout = false
            return
        }
        scheduleStart()
    }

    func resumeAfterPresentation() {
        guard awaitingLayout else { return }
        captureWindowGeometryIfNeeded()
        if targetExpanded { reservesDetail = true }
        scheduleStart()
    }

    /// 外层开合/锚点移动接管窗口之前，精确完成当前详情端点。
    func cancel() {
        generation += 1
        scheduledGeneration = nil
        stopLink()
        awaitingLayout = false
        awaitingCollapsedMeasurement = false
        currentOffset = targetExpanded ? fullOffset : 0
        visibility = targetExpanded ? 1 : 0
        // 展开原生布局已预备好，preferred 尺寸可能不变；仍须先让真实窗口落到端点。
        applyWindowAndSection()
        section?.apply(offset: currentOffset, visibility: visibility, slides: false)
        if let controller, baseBodyHeight > 0 {
            documentOffset = currentOffset
            let size = NSSize(width: 360, height: baseBodyHeight + currentOffset)
            controller.commitDetailSize(size)
        }
        if reservesDetail != targetExpanded { reservesDetail = targetExpanded }
        baseBodyHeight = 0
    }

    deinit { link?.invalidate() }

    fileprivate func bind(_ section: PanelDetailSectionView, expanded: Bool,
                          reduced: Bool, offset: CGFloat) {
        self.section = section
        reduceMotion = reduced
        let oldOffset = fullOffset
        fullOffset = offset
        if !initialized {
            initialized = true
            targetExpanded = expanded
            currentOffset = expanded ? offset : 0
            documentOffset = currentOffset
            visibility = expanded ? 1 : 0
            section.apply(offset: currentOffset, visibility: visibility, slides: false)
            return
        }
        // 更新详情种类时仅重新测量一次真实行高，不从零重播展开。
        if targetExpanded && abs(oldOffset - offset) > 0.25 {
            captureWindowGeometryIfNeeded()
            generation += 1
            scheduledGeneration = nil
            stopLink()
            awaitingLayout = true
        }
        section.apply(offset: currentOffset, visibility: visibility, slides: !reduced)
        if reduced && isAnimating { finish() }
        else if awaitingLayout { scheduleStart() }
    }

    fileprivate func sectionDidAttach() {
        if awaitingLayout { scheduleStart() }
    }

    fileprivate func detach(_ section: PanelDetailSectionView) {
        guard self.section === section else { return }
        cancel()
        self.section = nil
        initialized = false
    }

    /// 展开正文只暂存一次完整布局；显示帧不回写 NSPopover 尺寸。
    /// 未参与详情过渡的普通页面测量仍由原容器处理。
    func receiveMeasuredSize(_ size: NSSize) -> Bool {
        if awaitingCollapsedMeasurement {
            guard !reservesDetail else { return true }
            awaitingCollapsedMeasurement = false
            documentOffset = 0
            controller?.commitDetailSize(size)
            baseBodyHeight = 0
            return true
        }
        guard isAnimating, reservesDetail, let section else {
            if section != nil { documentOffset = reservesDetail ? fullOffset : 0 }
            return false
        }
        captureWindowGeometryIfNeeded()
        let expected = baseBodyHeight + fullOffset
        // 预留空间发布与正文测量之间可能夹着一条旧折叠测量。
        guard baseBodyHeight == 0 || abs(size.height - expected) < 2 else { return true }
        baseBodyHeight = size.height - fullOffset
        documentOffset = fullOffset
        controller?.stageDetailSize(size)
        section.apply(offset: currentOffset, visibility: visibility, slides: !reduceMotion)
        scheduleStart()
        return true
    }

    private func captureWindowGeometryIfNeeded() {
        guard baseBodyHeight == 0, let controller, !controller.isPresentationSizingSuspended,
              let window = controller.view.window else { return }
        // 保留实际正文的占位，不能用已提前发布的 reservesDetail 推断旧布局。
        baseBodyHeight = max(controller.naturalContentSize.height - documentOffset, 1)
        chromeHeight = max(window.frame.height - controller.naturalContentSize.height, 0)
        top = window.frame.maxY
        width = window.frame.width
    }

    private func scheduleStart() {
        guard awaitingLayout, scheduledGeneration != generation else { return }
        let token = generation
        scheduledGeneration = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduledGeneration = nil
            self.startIfReady()
        }
    }

    private func startIfReady() {
        guard awaitingLayout, let section else { return }
        guard let controller, let window = section.window, window === controller.view.window else {
            awaitingLayout = false
            currentOffset = targetExpanded ? fullOffset : 0
            visibility = targetExpanded ? 1 : 0
            section.apply(offset: currentOffset, visibility: visibility, slides: false)
            if !targetExpanded { reservesDetail = false }
            return
        }
        guard !controller.isPresentationSizingSuspended else { return }
        captureWindowGeometryIfNeeded()
        let staged = NSSize(width: 360, height: baseBodyHeight + fullOffset)
        // 展开前必须等根布局已经预留一次完整空间；关闭沿用展开宿主。
        guard abs(controller.detailDocumentSize.height - staged.height) < 2,
              section.frame.height >= section.naturalHeight - 1 else { return }
        awaitingLayout = false
        if reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
            return
        }
        sourceOffset = currentOffset
        targetOffset = targetExpanded ? fullOffset : 0
        sourceVisibility = visibility
        duration = max(0.24 * sqrt(Double(abs(targetOffset - sourceOffset) / max(fullOffset, 1))), 0.12)
        startTimestamp = CACurrentMediaTime()
        frameStepCount = 0
        let displayLink = window.displayLink(target: self, selector: #selector(step(_:)))
        let reported = window.screen?.maximumFramesPerSecond ?? 60
        let rate = Float(reported > 0 ? reported : 60)
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 60), maximum: rate, preferred: rate)
        link = displayLink
        displayLink.add(to: .main, forMode: .common)
        applyWindowAndSection()
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        guard link === displayLink else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        let timestamp = max(displayLink.timestamp, displayLink.targetTimestamp)
        let t = CGFloat(min(max((timestamp - startTimestamp) / duration, 0), 1))
        let eased = t * t * (3 - 2 * t)
        currentOffset = sourceOffset + (targetOffset - sourceOffset) * eased
        visibility = sourceVisibility + ((targetExpanded ? 1 : 0) - sourceVisibility) * eased
        frameStepCount += 1
        applyWindowAndSection()
        if t >= 1 { finish() }
    }

    private func applyWindowAndSection() {
        guard let window = controller?.view.window, baseBodyHeight > 0 else { return }
        let height = baseBodyHeight + currentOffset + chromeHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        section?.apply(offset: currentOffset, visibility: visibility, slides: !reduceMotion)
        // 不回写 NSPopover.contentSize，不改变正文 hosting 的 bounds。
        window.setFrame(NSRect(x: window.frame.minX, y: top - height, width: width, height: height), display: false)
        CATransaction.commit()
    }

    private func finish() {
        stopLink()
        awaitingLayout = false
        currentOffset = targetExpanded ? fullOffset : 0
        visibility = targetExpanded ? 1 : 0
        applyWindowAndSection()
        if targetExpanded {
            if baseBodyHeight > 0 {
                controller?.commitDetailSize(NSSize(width: 360, height: baseBodyHeight + fullOffset))
            }
            baseBodyHeight = 0
        } else {
            // 发布折叠占位后由一次最终根测量提交真实自然尺寸。
            awaitingCollapsedMeasurement = true
            reservesDetail = false
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }
}

struct PanelDetailSection: NSViewRepresentable {
    let animation: PanelDetailAnimation
    let expanded: Bool
    let reduceMotion: Bool
    let detail: AnyView
    let tail: AnyView

    func makeNSView(context: Context) -> PanelDetailSectionView {
        let view = PanelDetailSectionView(animation: animation)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PanelDetailSectionView, context: Context) {
        view.update(detail: AnyView(detail.environment(\.self, context.environment)
                                      .accessibilityHidden(!expanded).allowsHitTesting(expanded)),
                    tail: AnyView(tail.environment(\.self, context.environment)),
                    expanded: expanded, reduced: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelDetailSectionView,
                      context: Context) -> CGSize? {
        NSSize(width: 332, height: nsView.naturalHeight)
    }

    static func dismantleNSView(_ view: PanelDetailSectionView, coordinator: ()) {
        view.animation?.detach(view)
    }
}

/// hosting 的 bounds 只在内容更新时测量和设置；显示帧只移动包装视图。
final class PanelDetailSectionView: NSView {
    weak var animation: PanelDetailAnimation?
    private let detailController = NSHostingController(rootView: AnyView(EmptyView()))
    private let tailController = NSHostingController(rootView: AnyView(EmptyView()))
    private let detailClip = PanelDetailClipView(frame: .zero)
    private let tailWrapper = PanelDetailFlippedView(frame: .zero)
    private var detailHeight: CGFloat = 0
    private var tailHeight: CGFloat = 0
    private var visibleOffset: CGFloat = 0
    private var visibleAlpha: CGFloat = 0
    private var slides = true
    var naturalHeight: CGFloat {
        tailHeight + (animation?.reservesDetail == true ? detailHeight + 12 : 0)
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 332, height: naturalHeight) }

    init(animation: PanelDetailAnimation) {
        self.animation = animation
        super.init(frame: NSRect(x: 0, y: 0, width: 332, height: 1))
        wantsLayer = true
        autoresizesSubviews = false
        clipsToBounds = false
        detailController.safeAreaRegions = []
        tailController.safeAreaRegions = []
        detailController.sizingOptions = []
        tailController.sizingOptions = []
        detailController.view.identifier = NSUserInterfaceItemIdentifier("panel.detail.host")
        tailController.view.identifier = NSUserInterfaceItemIdentifier("panel.detail.tail.host")
        detailClip.identifier = NSUserInterfaceItemIdentifier("panel.detail.clip")
        tailWrapper.identifier = NSUserInterfaceItemIdentifier("panel.detail.tail.wrapper")
        detailController.view.setAccessibilityIdentifier("panel.detail.host")
        tailController.view.setAccessibilityIdentifier("panel.detail.tail.host")
        detailClip.setAccessibilityIdentifier("panel.detail.clip")
        tailWrapper.setAccessibilityIdentifier("panel.detail.tail.wrapper")
        addSubview(detailClip)
        addSubview(tailWrapper)
        detailClip.addSubview(detailController.view)
        tailWrapper.addSubview(tailController.view)
    }

    required init?(coder: NSCoder) { nil }

    func update(detail: AnyView, tail: AnyView, expanded: Bool, reduced: Bool) {
        detailController.rootView = detail
        tailController.rootView = tail
        let maximum = NSSize(width: 332, height: CGFloat.greatestFiniteMagnitude)
        let measuredDetail = detailController.sizeThatFits(in: maximum)
        let measuredTail = tailController.sizeThatFits(in: maximum)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        detailHeight = ceil(measuredDetail.height * scale) / scale
        tailHeight = ceil(measuredTail.height * scale) / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailController.view.frame = NSRect(x: 0, y: 0, width: 332, height: detailHeight)
        tailController.view.frame = NSRect(x: 0, y: 0, width: 332, height: tailHeight)
        tailWrapper.setFrameSize(NSSize(width: 332, height: tailHeight))
        CATransaction.commit()
        setInteractive(expanded)
        animation?.bind(self, expanded: expanded, reduced: reduced, offset: detailHeight + 12)
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animation?.sectionDidAttach()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // AppKit/root 布局调整仅更新原生包装位置，不测量 hosting。
        apply(offset: visibleOffset, visibility: visibleAlpha, slides: slides)
        animation?.sectionDidAttach()
    }

    func setInteractive(_ expanded: Bool) { detailClip.acceptsHits = expanded }

    func apply(offset: CGFloat, visibility: CGFloat, slides: Bool) {
        visibleOffset = max(offset, 0)
        visibleAlpha = min(max(visibility, 0), 1)
        self.slides = slides
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let slide = slides ? -4 * (1 - visibleAlpha) : 0
        detailClip.frame = NSRect(x: 0, y: 0, width: 332, height: min(detailHeight, visibleOffset))
        detailController.view.setFrameOrigin(NSPoint(x: 0, y: slide))
        detailClip.alphaValue = visibleAlpha
        detailClip.isHidden = visibleOffset <= 0 || visibleAlpha <= 0
        tailWrapper.setFrameOrigin(NSPoint(x: 0, y: visibleOffset))
        CATransaction.commit()
    }
}

private class PanelDetailFlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { nil }
}

private final class PanelDetailClipView: PanelDetailFlippedView {
    var acceptsHits = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsHits ? super.hitTest(point) : nil
    }
}
