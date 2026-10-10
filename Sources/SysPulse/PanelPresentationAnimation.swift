import AppKit
import QuartzCore
import SwiftUI

/// 驱动实际外层窗口高度；自然尺寸的正文由自有视口裁切。
/// 原生根视图保持系统管理，不再强行固定其 frame 或 bounds。
final class PanelPresentationAnimation {
    private weak var window: NSWindow?
    private weak var popover: NSPopover?
    private let restingFrame: NSRect
    private let entryHeight: CGFloat
    private let restingContentSize: NSSize
    private let originalAlpha: CGFloat
    private weak var contentController: PanelContentController?
    private let contractionAnchorX: CGFloat
    private let maximumLift: CGFloat
    private var contraction: CGFloat = 0
    private var sourceContraction: CGFloat = 0
    private var targetContraction: CGFloat = 0
    private var progress: CGFloat = 1
    private var sourceProgress: CGFloat = 1
    private var targetProgress: CGFloat = 1
    private var link: CADisplayLink?
    private var startTimestamp: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.22
    private var completion: (() -> Void)?
    private var accessibilityObserver: NSObjectProtocol?

    init?(popover: NSPopover, window: NSWindow, visibleAlpha: CGFloat? = nil, menuAnchor: NSRect? = nil) {
        (popover.contentViewController as? PanelContentController)?.finishDetailAnimation()
        let size = popover.contentSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        self.window = window
        self.popover = popover
        restingFrame = window.frame
        restingContentSize = size
        originalAlpha = visibleAlpha ?? window.alphaValue
        contentController = popover.contentViewController as? PanelContentController
        contractionAnchorX = menuAnchor?.midX ?? window.frame.midX
        maximumLift = min(max((menuAnchor?.minY ?? window.frame.maxY) - window.frame.maxY, 0), 8)
        // 入口包含实际标题正文，不能仅留 12 pt 的宽边框 / 箭头横条。
        let bodyHeight = contentController?.naturalContentSize.height ?? size.height
        let chromeHeight = max(window.frame.height - bodyHeight, 0)
        entryHeight = min(window.frame.height, chromeHeight + 96)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.link != nil,
                      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                if self.targetProgress == 1 {
                    self.apply(progress: 1)
                } else {
                    self.window?.alphaValue = 0
                }
                self.finish()
            }
    }

    deinit {
        link?.invalidate()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    func open(completion: @escaping () -> Void) {
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply(progress: 0)
        } else {
            window?.alphaValue = originalAlpha
        }
        run(to: 1, duration: 0.22, completion: completion)
    }

    func reopen(completion: @escaping () -> Void) {
        run(to: 1, duration: 0.22, completion: completion)
    }

    func close(completion: @escaping () -> Void) {
        run(to: 0, duration: 0.24, completion: completion)
    }

    private func run(to target: CGFloat, duration: CFTimeInterval, completion: @escaping () -> Void) {
        cancel()
        guard let window else { completion(); return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = originalAlpha
            completion()
            return
        }
        let distance = restingFrame.height - entryHeight
        if distance > 0 {
            progress = min(max((window.frame.height - entryHeight) / distance, 0), 1)
        }
        sourceProgress = progress
        targetProgress = target
        sourceContraction = contraction
        targetContraction = target == 0 ? 1 : 0
        // 中途反向不退回起点，也不把很短的余程挤成一两帧。
        self.duration = max(duration * sqrt(abs(target - progress)), 0.10)
        self.completion = completion
        startTimestamp = CACurrentMediaTime()
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        let reportedRate = window.screen?.maximumFramesPerSecond ?? 60
        let nativeRate = Float(reportedRate > 0 ? reportedRate : 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, nativeRate),
                                                       maximum: nativeRate, preferred: nativeRate)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func apply(progress: CGFloat, contraction: CGFloat = 0) {
        guard let window else { return }
        self.progress = progress
        self.contraction = contraction
        let height = entryHeight + (restingFrame.height - entryHeight) * progress
        let widthScale = 1 - 0.12 * contraction
        let top = restingFrame.maxY + maximumLift * contraction
        let frame = NSRect(x: contractionAnchorX + (restingFrame.minX - contractionAnchorX) * widthScale,
                           y: top - height, width: restingFrame.width * widthScale, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(frame, display: false)
        contentController?.setContraction(contraction)
        // 仅首尾约两三帧衔接可见性；大部分下拉 / 回收保持完全可见。
        window.alphaValue = originalAlpha * min(max(progress / 0.10, 0), 1)
        CATransaction.commit()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard self.link === link else { return }
        // 使用即将显示的时刻，不拿上一帧时间计算下一帧的位置。
        let timestamp = max(link.targetTimestamp, link.timestamp)
        let t = CGFloat(min(max((timestamp - startTimestamp) / duration, 0), 1))
        // 平滑加速 / 减速降低 60 Hz 下入口的大跨度，终点速度为零。
        let eased = t * t * (3 - 2 * t)
        apply(progress: t >= 1 ? targetProgress : sourceProgress + (targetProgress - sourceProgress) * eased,
              contraction: t >= 1 ? targetContraction : sourceContraction + (targetContraction - sourceContraction) * eased)
        guard self.link === link else { return }
        if t >= 1 { finish() }
    }

    private func finish() {
        let finish = completion
        cancel()
        finish?()
    }

    private func cancel() {
        completion = nil
        link?.invalidate()
        link = nil
    }

    func restore() {
        cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popover?.contentSize = restingContentSize
        window?.setFrame(restingFrame, display: false)
        contentController?.setContraction(0)
        contraction = 0
        window?.alphaValue = originalAlpha
        CATransaction.commit()
        progress = 1
    }
}

/// 各次创建独立缓存首个正文测量；容器绑定后只向自己的容器传递。
final class PanelContentMeasurement {
    let detailAnimation = PanelDetailAnimation()
    private weak var target: PanelContentController?
    private var latest: NSSize?

    func receive(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite,
              abs(size.width - 360) < 0.5, size.height > 0 else { return }
        latest = size
        target?.acceptMeasuredContentSize(size)
    }

    func attach(_ target: PanelContentController) {
        self.target = target
        detailAnimation.attach(target)
        if let latest { target.acceptMeasuredContentSize(latest) }
    }
}

/// 正文与原生弹窗边框分开管理：这里只固定正文自然尺寸，不固定原生根视图。
final class PanelContentController: NSViewController {
    var didChangePresentationSize: ((NSSize) -> Void)?
    private(set) var naturalContentSize = NSSize.zero
    private let hosting: NSViewController
    private let viewport = PanelViewport(frame: .zero)
    private var sizeUpdatesSuspended = false
    private var pendingSize: NSSize?
    private var hasMeasuredContentSize = false
    private var pendingMeasuredSize: NSSize?
    private var measurementUpdateScheduled = false
    private weak var detailAnimation: PanelDetailAnimation?

    var isDetailAnimating: Bool { detailAnimation?.isAnimating == true }
    var isPresentationSizingSuspended: Bool { sizeUpdatesSuspended }
    var detailDocumentSize: NSSize { naturalContentSize }

    func bindDetailAnimation(_ animation: PanelDetailAnimation) { detailAnimation = animation }

    func finishDetailAnimation() { detailAnimation?.cancel() }

    func stageDetailSize(_ size: NSSize) {
        guard Self.valid(size) else { return }
        let window = viewport.window
        let visibleFrame = window?.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            naturalContentSize = size
            viewport.updateDocumentSize(size)
            // AppKit 原子提交尺寸准备和位置恢复，临时弹窗重定位不会单独显示。
            prepareFullSizeLayout()
            if let window, let visibleFrame { window.setFrame(visibleFrame, display: false) }
            viewport.updateDocumentSize(size)
            CATransaction.commit()
        }
    }

    func commitDetailSize(_ size: NSSize) {
        guard Self.valid(size) else { return }
        pendingMeasuredSize = nil
        pendingSize = nil
        naturalContentSize = size
        viewport.updateDocumentSize(size)
        // 保留当前窗口上沿；NSPopover 对半点正文尺寸会做自己的取整。
        let window = viewport.window
        let restingTop = window?.frame.maxY
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            prepareFullSizeLayout()
            if let window, let restingTop {
                var frame = window.frame
                frame.origin.y = restingTop - frame.height
                window.setFrame(frame, display: false)
            }
            viewport.updateDocumentSize(size)
            CATransaction.commit()
        }
    }

    init?<Content: View>(hosting: NSHostingController<Content>, preferences: Preferences) {
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
        let body = hosting.view
        let preferred = hosting.preferredContentSize
        let size = Self.valid(preferred) ? preferred : hosting.sizeThatFits(
            in: NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        guard Self.valid(size) else { return nil }
        naturalContentSize = size
        viewport.frame = NSRect(origin: .zero, size: size)
        let surface = PanelSurfaceHostingView(rootView: PanelWindowSurface(preferences: preferences))
        surface.safeAreaRegions = []
        surface.sizingOptions = []
        viewport.install(body, size: size, surface: surface)
        view = viewport
        preferredContentSize = size
        addChild(hosting)
    }

    required init?(coder: NSCoder) { nil }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === hosting else { return }
        receiveNaturalSize(hosting.preferredContentSize)
    }

    func acceptMeasuredContentSize(_ size: NSSize) {
        guard Self.valid(size), abs(size.width - 360) < 0.5 else { return }
        let scale = viewport.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let measured = NSSize(width: 360, height: ceil(size.height * scale) / scale)
        if !hasMeasuredContentSize { pendingSize = nil }
        hasMeasuredContentSize = true
        pendingMeasuredSize = measured
        guard !measurementUpdateScheduled else { return }
        measurementUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementUpdateScheduled = false
            guard let size = self.pendingMeasuredSize else { return }
            self.pendingMeasuredSize = nil
            if self.sizeUpdatesSuspended {
                self.pendingSize = size
            } else if self.detailAnimation?.receiveMeasuredSize(size) != true {
                self.updateNaturalSize(size)
            }
        }
    }

    private func receiveNaturalSize(_ size: NSSize) {
        guard !hasMeasuredContentSize, Self.valid(size) else { return }
        if sizeUpdatesSuspended {
            pendingSize = size
        } else {
            updateNaturalSize(size)
        }
    }

    func suspendSizeUpdates() { sizeUpdatesSuspended = true }

    func setContraction(_ amount: CGFloat) { viewport.setContraction(amount) }

    func restoreSizeUpdates() {
        sizeUpdatesSuspended = false
        detailAnimation?.resumeAfterPresentation()
        let size = pendingMeasuredSize ?? pendingSize ?? (hasMeasuredContentSize ? naturalContentSize : hosting.preferredContentSize)
        pendingMeasuredSize = nil
        pendingSize = nil
        if Self.valid(size), detailAnimation?.receiveMeasuredSize(size) != true { updateNaturalSize(size) }
    }

    @discardableResult
    func prepareFullSizeLayout() -> NSSize {
        let insets = viewport.safeAreaInsets
        let size = NSSize(width: naturalContentSize.width + insets.left + insets.right,
                          height: naturalContentSize.height + insets.top + insets.bottom)
        if preferredContentSize != size {
            preferredContentSize = size
            didChangePresentationSize?(size)
        }
        return size
    }

    private func updateNaturalSize(_ size: NSSize) {
        guard naturalContentSize != size else { return }
        naturalContentSize = size
        viewport.updateDocumentSize(size)
        if viewport.window == nil { viewport.setFrameSize(size) }
        prepareFullSizeLayout()
    }

    private static func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private final class PanelSurfaceHostingView: NSHostingView<PanelWindowSurface> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class PanelViewport: NSView {
        private weak var body: NSView?
        private weak var surface: NSView?
        private let documentView = NSView(frame: .zero)
        private var documentSize = NSSize.zero
        private var contraction: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            autoresizingMask = [.width, .height]
            autoresizesSubviews = false
            clipsToBounds = true
            wantsLayer = true
            layer?.masksToBounds = true
            documentView.wantsLayer = true
            documentView.autoresizesSubviews = false
        }

        required init?(coder: NSCoder) { nil }

        func install(_ view: NSView, size: NSSize, surface: NSView) {
            body = view
            self.surface = surface
            documentSize = size
            view.autoresizingMask = []
            surface.autoresizingMask = []
            addSubview(surface)
            addSubview(documentView)
            documentView.addSubview(view)
            pinDocumentTop()
        }

        func setContraction(_ amount: CGFloat) {
            contraction = min(max(amount, 0), 1)
            pinDocumentTop()
        }

        func updateDocumentSize(_ size: NSSize) {
            documentSize = size
            pinDocumentTop()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pinDocumentTop()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            pinDocumentTop()
        }

        override func layout() {
            super.layout()
            pinDocumentTop()
        }

        private func pinDocumentTop() {
            guard let body else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if surface?.frame != bounds { surface?.frame = bounds }
            // AppKit 会短暂回写完整视口 bounds；以实际窗口可见范围计算正文几何。
            let visible = window.map { convert(NSRect(origin: .zero, size: $0.frame.size), from: nil) } ?? bounds
            let insets = safeAreaInsets
            let safe = NSRect(x: visible.minX + insets.left, y: visible.minY + insets.bottom,
                              width: max(visible.width - insets.left - insets.right, 1),
                              height: max(visible.height - insets.top - insets.bottom, 1))
            let y = isFlipped ? safe.minY : safe.maxY - documentSize.height
            let frame = NSRect(x: safe.midX - documentSize.width / 2, y: y,
                               width: documentSize.width, height: documentSize.height)
            documentView.layer?.transform = CATransform3DIdentity
            if documentView.frame != frame { documentView.frame = frame }
            if body.frame != documentView.bounds { body.frame = documentView.bounds }
            let scaleX = contraction > 0 ? min(1, max(safe.width, 1) / documentSize.width) : 1
            let scaleY = 1 - 0.06 * contraction
            var transform = CATransform3DMakeScale(scaleX, scaleY, 1)
            // 内容缩小仍贴齐上沿；辅助容器承载变换，不改写 SwiftUI 的布局尺寸。
            transform.m42 = (isFlipped ? -1 : 1) * documentSize.height * (1 - scaleY) / 2
            documentView.layer?.transform = transform
            CATransaction.commit()
        }
    }
}

/// 附着回调只准备初次可见性，不占用事件区域或改变内容尺寸。
struct PanelWindowAttachment: NSViewRepresentable {
    let didAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { AttachmentView(didAttach: didAttach) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? AttachmentView)?.didAttach = didAttach
    }

    private final class AttachmentView: NSView {
        var didAttach: (NSWindow) -> Void
        init(didAttach: @escaping (NSWindow) -> Void) {
            self.didAttach = didAttach
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { didAttach(window) }
        }
    }
}
