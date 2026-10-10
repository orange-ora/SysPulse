import AppKit
import SwiftUI
import QuartzCore
import ObjectiveC
import ServiceManagement

// 本文件只编译进隔离 probe。系统偏好不会改变；该替换只影响当前进程的读取。
private var probeReducedMotion = false
private var probeReducedTransparency = false
extension NSWorkspace {
    @objc func panelProbeReducedMotion() -> Bool { probeReducedMotion }
    @objc func panelProbeReducedTransparency() -> Bool { probeReducedTransparency }
}

private var nativeChecks: [String] = []
private var nativeNotes: [String] = []
private var geometryRecords: [[String: Any]] = []
private var originalMotion: Bool = false
private var originalTransparency: Bool = false

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fail(name) }
    nativeChecks.append(name)
    print("PASS [native \(nativeChecks.count)]: \(name)")
    fflush(stdout)
}

@MainActor
private func settle(_ seconds: Double = 0.30) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
private func click(_ view: NSView, _ point: NSPoint) {
    guard let window = view.window else { fail("local click without window") }
    let local = view.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { fail("local native mouse event") }
        app.sendEvent(event)
    }
}

@MainActor
private func hover(_ view: NSView, _ point: NSPoint) {
    guard let window = view.window else { fail("hover without window") }
    let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: screen.x, y: top - screen.y), mouseButton: .left)?.post(tap: .cghidEventTap)
}

@MainActor
private func nativeTrackingEvent(_ view: NSView, _ point: NSPoint) {
    guard let window = view.window,
          let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { fail("native tracking event") }
    view.mouseEntered(with: event)
    view.mouseMoved(with: event)
}

/// 真实指针悬停前后比较同一控件的局部像素；只断言渲染结果变化，不断言动效的具体数值。
/// 坐标为宿主视图坐标（翻转，y 从顶部算起），与 press 的坐标体系一致。
///
/// `quiet` 是同一页面上一块不受该控件影响的区域：它必须**完全不变**。
/// 没有这条对照，`diff > 0` 可能只是整页重绘、光标闪烁或别的控件在动。
@MainActor
private func verifyHover(_ tag: String, _ name: String, at point: NSPoint, region: NSRect,
                         quiet: NSRect, host: NSView) async {
    // 星点在普通模式持续流动，悬停与复原只比较滑钮上沿（轨道从 y=220 开始）。
    // 此处仍要求真实悬停变化和静态复原，不能用粒子本身的运动冒充反馈。
    let comparisonRegion = name == "slider" && !probeReducedMotion
        ? NSRect(x: 14 + 300 * CGFloat(preferences.panelTransparency) - 3,
                 y: 214, width: 38, height: 6)
        : region
    hover(host, NSPoint(x: -20, y: 390))
    await settle()
    let neutral = bodyBitmap(host, name: tag + "-" + name + "-neutral")
    hover(host, point)
    await settle(0.5)
    save(host, name: tag + "-" + name + "-hover-native")
    let hovered = bodyBitmap(host, name: tag + "-" + name + "-hover")
    let diff = difference(neutral, hovered, rect: comparisonRegion, size: host.bounds.size)
    let quietDiff = difference(neutral, hovered, rect: quiet, size: host.bounds.size)
    print("PIXELS \(tag) \(name): hover=\(diff) quiet=\(quietDiff)")
    check(diff > 0.0001, tag + " " + name + " actual pointer hover produces a visible change")
    check(quietDiff == 0, tag + " " + name + " hover leaves the page's unrelated region untouched")
    check(darkFraction(hovered, rect: region, size: host.bounds.size) < 0.10,
          tag + " " + name + " hover preserves a light glass surface without black compositing blocks")
    hover(host, NSPoint(x: -20, y: 390))
    // 齿轮自身回转为 0.42s；边缘弹簧回落也必须先结束，再比较静止图像。
    await settle(0.55)
    let restored = bodyBitmap(host, name: tag + "-" + name + "-restored")
    let restoreDiff = difference(neutral, restored, rect: comparisonRegion, size: host.bounds.size)
    print("PIXELS \(tag) \(name): restored=\(restoreDiff)")
    check(restoreDiff < 0.002,
          tag + " " + name + " glass returns to its idle rendering after pointer exit")
}

/// 用真实鼠标分别触碰四边与四角，检查单张玻璃的方向响应、回落与固定几何。
@MainActor
private func verifyMagneticEdges(_ tag: String, reduced: Bool, panel: PanelContentController, host: NSView) async {
    let bounds = host.bounds
    let natural = panel.naturalContentSize
    let card = NSRect(x: 14, y: 67.5, width: 162, height: 136)
    let region = card.insetBy(dx: -2, dy: -2)
    let quiet = NSRect(x: 210, y: 260, width: 60, height: 30)
    hover(host, NSPoint(x: -20, y: 390))
    await settle(0.55)
    let idle = bodyBitmap(host, name: tag + "-magnet-idle")
    var first: NSBitmapImageRep?
    for (name, point) in [("top", NSPoint(x: card.midX, y: card.minY + 2)),
                          ("bottom", NSPoint(x: card.midX, y: card.maxY - 2)),
                          ("left", NSPoint(x: card.minX + 2, y: card.midY)),
                          ("right", NSPoint(x: card.maxX - 2, y: card.midY)),
                          ("top-left", NSPoint(x: card.minX + 8, y: card.minY + 8)),
                          ("top-right", NSPoint(x: card.maxX - 8, y: card.minY + 8)),
                          ("bottom-left", NSPoint(x: card.minX + 8, y: card.maxY - 8)),
                          ("bottom-right", NSPoint(x: card.maxX - 8, y: card.maxY - 8))] {
        hover(host, point)
        await settle(0.5)
        let rendered = bodyBitmap(host, name: tag + "-magnet-" + name)
        check(darkFraction(rendered, rect: region, size: bounds.size) < 0.10,
              tag + " magnetic " + name + " keeps native glass free of black blocks")
        check(difference(idle, rendered, rect: quiet, size: bounds.size) == 0,
              tag + " magnetic " + name + " leaves neighboring cards unchanged")
        if let first {
            let diff = difference(first, rendered, rect: region, size: bounds.size)
            check(reduced ? diff < 0.002 : diff > 0.0001,
                  tag + " magnetic " + name + (reduced ? " stays centered with reduced motion" : " responds to its pointer edge"))
        } else {
            first = rendered
        }
        hover(host, NSPoint(x: -20, y: 390))
        await settle(0.55)
    }
    let restored = bodyBitmap(host, name: tag + "-magnet-restored")
    check(difference(idle, restored, rect: region, size: bounds.size) < 0.002,
          tag + " all-edge magnetic sequence returns to the original single surface")
    check(host.bounds == bounds && panel.naturalContentSize == natural,
          tag + " all-edge magnetic sequence keeps layout and hit bounds fixed")
    // 最左缘仍接受真实点击；视觉向外拉动不能让原来的命中边缘失效。
    click(host, NSPoint(x: 16, y: 146))
    await settle()
    check(panel.naturalContentSize.height > natural.height + 40,
          tag + " magnetic card original edge still opens detail on click")
    click(host, NSPoint(x: 16, y: 146))
    await settle()
    check(abs(panel.naturalContentSize.height - natural.height) < 0.5,
          tag + " magnetic card edge click can collapse detail again")
}

// 只取深色文字的重心，避免把移动的浅色反光误判成内容偏转。
private func inkCenterX(_ bitmap: NSBitmapImageRep, rect: NSRect, size: NSSize) -> Double {
    let sx = Double(bitmap.pixelsWide) / size.width
    let sy = Double(bitmap.pixelsHigh) / size.height
    var weight = 0.0
    var weightedX = 0.0
    for y in max(0, Int(rect.minY * sy))..<min(bitmap.pixelsHigh, Int(rect.maxY * sy)) {
        for x in max(0, Int(rect.minX * sx))..<min(bitmap.pixelsWide, Int(rect.maxX * sx)) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let ink = max(0, 0.65 - max(color.redComponent, max(color.greenComponent, color.blueComponent)))
            weight += ink
            weightedX += ink * (Double(x) + 0.5) / sx
        }
    }
    guard weight > 1 else { fail("chrome hover crop must contain readable text") }
    return weightedX / weight
}

@MainActor
private func verifyChromeHover(_ tag: String, reduced: Bool, panel: PanelContentController, host: NSView) async {
    let bounds = host.bounds
    let natural = panel.naturalContentSize
    for (name, card, ink) in [
        ("header", NSRect(x: 14, y: 14, width: 332, height: 41.5), NSRect(x: 34, y: 15, width: 180, height: 22)),
        ("footer", NSRect(x: 14, y: 531.5, width: 332, height: 32), NSRect(x: 36, y: 533, width: 230, height: 28))
    ] {
        hover(host, NSPoint(x: -20, y: 390))
        await settle(0.55)
        let idle = bodyBitmap(host, name: tag + "-" + name + "-idle")
        hover(host, NSPoint(x: card.minX + 4, y: card.midY))
        await settle(0.55)
        let left = bodyBitmap(host, name: tag + "-" + name + "-left")
        hover(host, NSPoint(x: card.maxX - 4, y: card.midY))
        await settle(0.55)
        let right = bodyBitmap(host, name: tag + "-" + name + "-right")
        for sample in 0..<3 {
            await settle(0.12)
            let held = bodyBitmap(host, name: tag + "-" + name + "-held-\(sample)")
            let heldShift = inkCenterX(held, rect: ink, size: bounds.size) - inkCenterX(right, rect: ink, size: bounds.size)
            print("CHROME-HOLD \(tag) \(name) \(sample): shift=\(heldShift)")
            check(abs(heldShift) < 0.1,
                  tag + " " + name + " stationary pointer keeps foreground still \(sample)")
        }
        let control = name == "header" ? NSRect(x: 318, y: 11, width: 30, height: 30) : NSRect(x: 292, y: 539, width: 54, height: 20)
        check(darkFraction(right, rect: control, size: bounds.size) < 0.10,
              tag + " " + name + " child glass button remains readable")
        let shift = inkCenterX(right, rect: ink, size: bounds.size) - inkCenterX(left, rect: ink, size: bounds.size)
        print("CHROME-MOTION \(tag) \(name): foreground shift=\(shift)pt idle=\(inkCenterX(idle, rect: ink, size: bounds.size)) left=\(inkCenterX(left, rect: ink, size: bounds.size)) right=\(inkCenterX(right, rect: ink, size: bounds.size))")
        check(abs(shift) <= (reduced ? 0.1 : 1),
              tag + " " + name + (reduced ? " holds foreground still with Reduce Motion" : " keeps foreground displacement within the shared subtle card motion"))
        let region = card.insetBy(dx: -3, dy: -3)
        let directionalChange = difference(left, right, rect: region, size: bounds.size)
        check(reduced ? directionalChange < 0.002 : directionalChange > 0.0001,
              tag + " " + name + " renders the shared card directional response")
        check(darkFraction(left, rect: region, size: bounds.size) < 0.10 && darkFraction(right, rect: region, size: bounds.size) < 0.10,
              tag + " " + name + " keeps shared glass and child controls free of black blocks")
        let quiet = NSRect(x: 210, y: 260, width: 60, height: 30)
        check(difference(idle, left, rect: quiet, size: bounds.size) == 0 && difference(idle, right, rect: quiet, size: bounds.size) == 0,
              tag + " " + name + " leaves other cards stationary")
        hover(host, NSPoint(x: -20, y: 390))
        await settle(0.55)
        let restored = bodyBitmap(host, name: tag + "-" + name + "-restored")
        check(difference(idle, restored, rect: region, size: bounds.size) < 0.002,
              tag + " " + name + " returns to its original aligned rendering")
        check(host.bounds == bounds && panel.naturalContentSize == natural,
              tag + " " + name + " retains layout and hit bounds during hover")
    }
}

@MainActor
private func detailFrames(_ name: String, panel: PanelContentController, host: NSView,
                          action: () -> Void) async -> [[String: Double]] {
    guard let window = host.window else { fail("detail animation without window") }
    var frames: [[String: Double]] = []
    func record() {
        frames.append(["body": panel.naturalContentSize.height, "window": window.frame.height,
                       "top": window.frame.maxY, "width": window.frame.width])
    }
    record()
    action()
    for _ in 0..<36 { await settle(0.01); record() }
    try! JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(name + "-frames.json"))
    return frames
}

@MainActor
private func verifyDetailFrames(_ frames: [[String: Double]], name: String, reduced: Bool) {
    let start = frames.first!["window"]!
    let end = frames.last!["window"]!
    let low = min(start, end)
    let high = max(start, end)
    let interior = Set(frames.compactMap { frame -> Double? in
        let height = frame["window"]!
        return height > low + 1 && height < high - 1 ? height : nil
    })
    check(reduced ? interior.isEmpty : interior.count >= 3,
          name + (reduced ? " respects reduced motion without spatial interpolation" : " changes real native height through multiple intermediate frames"))
    // 原生 NSPopover 把半点正文高度取整为窗口尺寸，上沿最多相差 1pt。
    check(frames.allSatisfy { abs($0["top"]! - frames.first!["top"]!) <= 1 &&
                              abs($0["width"]! - frames.first!["width"]!) < 1 },
          name + " keeps the native arrow edge and width fixed")
    let direction = end > start ? 1.0 : -1.0
    check(zip(frames, frames.dropFirst()).allSatisfy { ($1["window"]! - $0["window"]!) * direction >= -0.5 },
          name + " moves continuously without a reverse height jump")
}

@MainActor
private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

private func allLayers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(allLayers) }

@MainActor
private func bodyBitmap(_ view: NSView, name: String) -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    guard CGPreflightScreenCaptureAccess(), let window = view.window else { fail("pixel verification requires WindowServer screen capture permission") }
    save(view, name: name + "-pixels-native")
    guard let data = try? Data(contentsOf: output.appendingPathComponent(name + "-pixels-native.png")),
          let image = NSBitmapImageRep(data: data), let cg = image.cgImage else { fail("WindowServer bitmap") }
    let rawFrame = window.frame
    let captureFrame = NSRect(x: CGFloat(Int(rawFrame.minX)), y: rawFrame.maxY - CGFloat(Int(rawFrame.height)),
                              width: CGFloat(Int(rawFrame.width)), height: CGFloat(Int(rawFrame.height)))
    let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
    let sx = CGFloat(image.pixelsWide) / captureFrame.width
    let sy = CGFloat(image.pixelsHigh) / captureFrame.height
    let crop = CGRect(x: (screenRect.minX - captureFrame.minX) * sx,
                      y: (captureFrame.maxY - screenRect.maxY) * sy,
                      width: screenRect.width * sx, height: screenRect.height * sy).integral
    guard let cropped = cg.cropping(to: crop) else { fail("WindowServer body crop") }
    let bitmap = NSBitmapImageRep(cgImage: cropped)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("body crop PNG") }
    try! png.write(to: output.appendingPathComponent(name + "-body.png"))
    return bitmap
}

// 比较真实渲染内容的区域；不是对源码或布局常量作文本匹配。
private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rect: NSRect, size: NSSize) -> Double {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .infinity }
    let scaleX = CGFloat(a.pixelsWide) / size.width
    let scaleY = CGFloat(a.pixelsHigh) / size.height
    let x0 = max(0, Int(rect.minX * scaleX))
    let x1 = min(a.pixelsWide, Int(rect.maxX * scaleX))
    let y0 = max(0, Int(rect.minY * scaleY))
    let y1 = min(a.pixelsHigh, Int(rect.maxY * scaleY))
    var total = 0.0
    var count = 0
    guard x1 > x0, y1 > y0 else { fail("invalid pixel crop") }
    for y in stride(from: y0, to: y1, by: 2) {
        for x in stride(from: x0, to: x1, by: 2) {
            guard let ac = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let bc = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            total += abs(ac.redComponent - bc.redComponent) + abs(ac.greenComponent - bc.greenComponent) + abs(ac.blueComponent - bc.blueComponent)
            count += 3
        }
    }
    return total / Double(max(count, 1))
}

// 只针对浅色面板的大面积黑块故障；正常文字/图标可以保留少量深色像素。
private func darkFraction(_ bitmap: NSBitmapImageRep, rect: NSRect, size: NSSize) -> Double {
    let sx = CGFloat(bitmap.pixelsWide) / size.width
    let sy = CGFloat(bitmap.pixelsHigh) / size.height
    var dark = 0
    var count = 0
    for y in stride(from: max(0, Int(rect.minY * sy)), to: min(bitmap.pixelsHigh, Int(rect.maxY * sy)), by: 2) {
        for x in stride(from: max(0, Int(rect.minX * sx)), to: min(bitmap.pixelsWide, Int(rect.maxX * sx)), by: 2) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.20 { dark += 1 }
            count += 1
        }
    }
    return Double(dark) / Double(max(1, count))
}

@MainActor
private func state(_ name: String, panel: PanelContentController, host: NSView) {
    guard let window = host.window else { fail("state has no window") }
    let safe = panel.view.safeAreaInsets
    let record: [String: Any] = ["state": name,
        "bodyWidth": panel.naturalContentSize.width, "bodyHeight": panel.naturalContentSize.height,
        "hostingWidth": host.bounds.width, "hostingHeight": host.bounds.height,
        "windowWidth": window.frame.width, "windowHeight": window.frame.height,
        "safeWidth": window.frame.width - safe.left - safe.right,
        "safeHeight": window.frame.height - safe.top - safe.bottom]
    geometryRecords.append(record)
    print("GEOMETRY: \(record)")
    check(abs(panel.naturalContentSize.width - 360) < 0.01 && abs(host.bounds.width - 360) < 0.01, name + " real natural and hosting width 360")
    check(abs(window.frame.width - safe.left - safe.right - 360) < 1, name + " full window accounts for native horizontal insets")
    check(abs(window.frame.height - safe.top - safe.bottom - panel.naturalContentSize.height) < 1, name + " full window follows natural page height")
}

@MainActor
private func hostPanel(reduced: Bool, positions: RootJumpRecorder? = nil) async -> (PanelContentController, NSHostingController<AnyView>) {
    previewPopover.close()
    previewPopover.contentViewController = nil
    let measurement = PanelContentMeasurement()
    preferences.resetDisplaySettings()
    let dashboard = DashboardView(monitor: monitor, preferences: preferences, usesWindowSurface: true,
                                  naturalSizeDidChange: { measurement.receive($0) }, detailMotion: measurement.detailAnimation)
    let root: AnyView
    if let positions {
        root = AnyView(dashboard.overlay(alignment: .topLeading) {
            PanelRootMarker(positions: positions).frame(width: 1, height: 1)
        }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { positions.geometry($0) })
    } else {
        root = AnyView(dashboard)
    }
    let host = NSHostingController(rootView: root)
    host.sizingOptions = .preferredContentSize
    host.safeAreaRegions = []
    host.preferredContentSize = host.sizeThatFits(in: NSSize(width: 360, height: 1200))
    guard let panel = PanelContentController(hosting: host, preferences: preferences),
          let button = previewItem?.button else { fail("native fixture initialization") }
    panel.didChangePresentationSize = { previewPopover.contentSize = $0 }
    previewPopover.contentViewController = panel
    measurement.attach(panel)
    previewPopover.contentSize = panel.preferredContentSize
    previewPopover.appearance = NSAppearance(named: .aqua)
    previewPopover.hasFullSizeContent = true
    app.activate(ignoringOtherApps: true)
    previewPopover.show(relativeTo: NSRect(x: button.bounds.midX - 0.5, y: 0, width: 1, height: button.bounds.height),
                        of: button, preferredEdge: .minY)
    panel.prepareFullSizeLayout()
    await settle()
    host.view.window?.makeKey()
    await settle(0.05)
    check(host.view.window?.isKeyWindow == true, "native fixture finishes key-window activation before input")
    return (panel, host)
}

private func reflected<T>(_ object: Any, _ name: String, as type: T.Type = T.self) -> T? {
    guard let value = Mirror(reflecting: object).children.first(where: { $0.label == name })?.value else { return nil }
    if let typed = value as? T { return typed }
    return Mirror(reflecting: value).children.first?.value as? T
}

@MainActor
private func controllerChecks() async {
    // Preferences.shared uses runner's CFFIXED_USER_HOME, not the installed app's preferences.
    let shared = Preferences.shared
    shared.resetDisplaySettings()
    shared.menuBarEffect = .diffuse
    let controller = StatusItemController()
    guard let item: NSStatusItem = reflected(controller, "statusItem"),
          let popover: NSPopover = reflected(controller, "popover"), let button = item.button else { fail("inspect own controller native status item") }
    await settle(0.5)
    for reduced in [false, true] {
        probeReducedMotion = reduced
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        await settle(0.1)
        button.performClick(nil)
        var opening: [[String: Double]] = []
        for _ in 0..<32 {
            if let window = popover.contentViewController?.view.window, popover.isShown {
                opening.append(["width": window.frame.width, "height": window.frame.height, "top": window.frame.maxY, "alpha": window.alphaValue])
            }
            await settle(0.01)
        }
        check(popover.isShown, "production controller " + (reduced ? "reduced" : "normal") + " actual status action opens native popover")
        guard let panel = popover.contentViewController as? PanelContentController,
              let window = panel.view.window else { fail("production full-window content container") }
        check(popover.hasFullSizeContent && panel.view.subviews.contains(where: { $0 is NSHostingView<PanelWindowSurface> }),
              "production controller uses one full-size native window surface")
        check(abs(panel.naturalContentSize.width - 360) < 0.01 && abs(window.frame.width - 386) < 1,
              "production controller actual body and safe-area window widths")
        if !reduced {
            check((opening.map { $0["height"]! }.min() ?? .infinity) < window.frame.height - 100,
                  "normal production opening changes real native window height")
            check((opening.map { $0["top"]! }.max() ?? 0) - (opening.map { $0["top"]! }.min() ?? 0) < 1,
                  "normal production opening stays pinned to top/menu anchor")
        } else {
            check((opening.map { $0["height"]! }.max() ?? 0) - (opening.map { $0["height"]! }.min() ?? 0) < 1,
                  "reduced production opening immediately uses final native window height")
        }
        save(panel.view, name: reduced ? "controller-reduced-open-native" : "controller-normal-open-native")
        let originalFrame = window.frame
        button.performClick(nil)
        var closing: [[String: Double]] = []
        var receiptSeen = false
        for _ in 0..<34 {
            closing.append(["width": window.frame.width, "height": window.frame.height, "alpha": window.alphaValue])
            receiptSeen = receiptSeen || button.layer?.animation(forKey: "panel.receipt") != nil
            await settle(0.01)
        }
        check(!popover.isShown, "production controller " + (reduced ? "reduced" : "normal") + " closes native popover")
        if !reduced {
            check((closing.map { $0["height"]! }.min() ?? .infinity) < originalFrame.height - 100,
                  "normal production close contracts actual native window height")
            check((closing.map { $0["width"]! }.min() ?? .infinity) < originalFrame.width - 20,
                  "normal production close contracts actual native window width")
            check(receiptSeen, "normal close completion installs actual menu receipt animation")
            // 收束期间再次用原状态按钮触发重开，确认真实窗口可恢复。
            button.performClick(nil)
            await settle(0.30)
            button.performClick(nil)
            await settle(0.07)
            button.performClick(nil)
            await settle(0.35)
            check(popover.isShown, "production close interrupted by status click reverses and reopens")
            if let reopened = popover.contentViewController?.view.window {
                check(abs(reopened.frame.height - originalFrame.height) < 1 && abs(reopened.frame.width - originalFrame.width) < 1,
                      "production interrupted close restores full natural window dimensions")
            } else { fail("reopened window") }
            button.performClick(nil)
            await settle(0.60)
        } else {
            check(!receiptSeen, "reduced close omits menu receipt spatial animation")
        }
        try! JSONSerialization.data(withJSONObject: ["opening": opening, "closing": closing, "receiptObserved": receiptSeen],
                                    options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(reduced ? "controller-reduced-animation.json" : "controller-normal-animation.json"))
    }
    probeReducedMotion = false
    if let glass: NSView = reflected(controller, "statusGlassView"),
       let reflection: CAGradientLayer = reflected(glass, "hoverReflection"),
       let edge: CAGradientLayer = reflected(glass, "hoverHighlight") {
        let roots = allViews(glass).compactMap(\.layer)
        check(roots.flatMap(allLayers).allSatisfy { $0.shadowOpacity == 0 }, "actual status glass hierarchy has no active depth shadow")
        shared.menuBarEffect = .diffuse
        await settle(0.25)
        let enabled: Bool = reflected(glass, "hoverEnabled") ?? false
        let tracking: NSTrackingArea? = reflected(glass, "hoverTrackingArea")
        let glassScreen = glass.window?.convertToScreen(glass.convert(glass.bounds, to: nil)) ?? .zero
        check(shared.menuBarEffect == .diffuse && enabled, "menu hover diagnostic has non-off effect and enabled receiver")
        check(tracking != nil, "menu hover diagnostic has an installed native tracking area")
        check(!glass.visibleRect.isEmpty && NSScreen.screens.contains { $0.frame.intersects(glassScreen) },
              "menu hover diagnostic glass is visible and on current screen")
        let quarter = NSPoint(x: glass.bounds.width * 0.25, y: glass.bounds.midY)
        hover(glass, quarter)
        await settle(0.3)
        let expectedPointer = glass.window?.convertPoint(toScreen: glass.convert(quarter, to: nil)) ?? .zero
        let actualPointer = NSEvent.mouseLocation
        check(hypot(expectedPointer.x - actualPointer.x, expectedPointer.y - actualPointer.y) < 3,
              "menu hover diagnostic physical pointer reaches correctly converted screen coordinate")
        let diagnostic: [String: Any] = ["effect": shared.menuBarEffect.rawValue, "hoverEnabled": enabled,
            "trackingArea": tracking != nil, "glassFrame": NSStringFromRect(glassScreen),
            "visibleRect": NSStringFromRect(glass.visibleRect), "pointerExpected": NSStringFromPoint(expectedPointer),
            "pointerActual": NSStringFromPoint(actualPointer), "cgReflectionOpacity": reflection.opacity,
            "cgEdgeOpacity": edge.opacity]
        try! JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("menu-hover-diagnostic.json"))
        nativeTrackingEvent(glass, quarter)
        await settle(0.3)
        let first = reflection.startPoint
        check(reflection.opacity > 0 && edge.opacity > 0, "native status tracking event activates actual reflection and edge layers")
        nativeTrackingEvent(glass, NSPoint(x: glass.bounds.width * 0.75, y: glass.bounds.midY))
        await settle(0.3)
        check(reflection.startPoint != first, "native status reflection changes direction for local tracking event")
        shared.menuBarEffect = .off
        await settle(0.2)
        check(reflection.opacity == 0 && edge.opacity == 0, "off effect disables native menu hover layers")
    } else {
        nativeNotes.append("No native status-glass view available on this macOS: menu reflection-layer branch not exercised.")
    }
    NSStatusBar.system.removeStatusItem(item)
    shared.resetDisplaySettings()
}

private final class RootMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PanelRootMarker: NSViewRepresentable {
    let positions: RootJumpRecorder
    func makeNSView(context: Context) -> NSView {
        let view = RootMarkerView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        positions.marker = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { positions.marker = view }
}

/// 原生标记跟随整页内容，窗口通知还能记录同一次主队列里的暂时改尺寸。
private final class RootJumpRecorder: NSObject {
    weak var marker: NSView?
    private weak var window: NSWindow?
    private weak var host: NSView?
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private(set) var samples: [[String: Any]] = []
    private var recording = false

    func start(host: NSView) {
        self.host = host
        window = host.window
        samples = []
        recording = true
        record("start")
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                self?.record(note.name == NSWindow.didResizeNotification ? "resize" : "move")
            })
        }
        let link = window!.displayLink(target: self, selector: #selector(step(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func geometry(_ rect: CGRect) { if recording { record("geometry", geometry: rect) } }
    @objc private func step(_ link: CADisplayLink) { record("display") }

    private func record(_ event: String, geometry: CGRect? = nil) {
        guard let window, let marker, let host else { return }
        let localTop = NSPoint(x: 0, y: marker.isFlipped ? 0 : marker.bounds.maxY)
        let point = window.convertPoint(toScreen: marker.convert(localTop, to: nil))
        var row: [String: Any] = ["event": event, "time": CACurrentMediaTime(),
            "windowHeight": window.frame.height, "windowTop": window.frame.maxY,
            "contentTop": point.y, "topInset": window.frame.maxY - point.y,
            "hostingHeight": host.bounds.height]
        if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]])?.first,
           let bounds = info[kCGWindowBounds as String] as? [String: Any] {
            row["serverY"] = bounds["Y"]
            row["serverHeight"] = bounds["Height"]
        }
        row["nativeGroupDuration"] = NSAnimationContext.current.duration
        if let geometry {
            row["rootY"] = geometry.minY
            row["rootHeight"] = geometry.height
        }
        samples.append(row)
    }

    @MainActor
    func stop(name: String) {
        record("end")
        recording = false
        link?.invalidate()
        link = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        try! JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name + "-positions.json"))
        func values(_ key: String, in rows: [[String: Any]]) -> [Double] {
            rows.compactMap { ($0[key] as? NSNumber)?.doubleValue }
        }
        func spread(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        let serverY = values("serverY", in: samples)
        let insets = values("topInset", in: samples)
        let display = samples.filter { ["start", "display", "end"].contains($0["event"] as? String ?? "") }
        let displayTops = values("contentTop", in: display)
        let rootY = values("rootY", in: samples)
        print("ROOT-POSITION \(name): samples=\(samples.count) serverSpread=\(spread(serverY)) insetSpread=\(spread(insets)) displaySpread=\(spread(displayTops)) modelSpread=\(spread(values("contentTop", in: samples)))")
        check(serverY.count == samples.count && !serverY.isEmpty, name + " reads committed WindowServer bounds at every event")
        check(spread(serverY) <= 1, name + " never commits a temporary window-top jump")
        check(insets.count == samples.count && spread(insets) <= 1, name + " keeps real content top fixed within the window, including synchronous layout")
        check(displayTops.count >= 3 && spread(displayTops) <= 1, name + " keeps displayed content position fixed through both endpoints")
        check(!rootY.isEmpty && spread(rootY) <= 1, name + " prevents SwiftUI root recentering during size changes")
    }
}

/// 与实际显示刷新同步采样；不会在采样期间截图或触发布局。
@MainActor
private final class DetailCadenceRecorder: NSObject {
    private let panel: PanelContentController
    private let host: NSView
    private let window: NSWindow
    private var link: CADisplayLink?
    private var detailHost: NSView?
    private var tailHost: NSView?
    private(set) var frames: [[String: Double]] = []

    init(panel: PanelContentController, host: NSView) {
        self.panel = panel
        self.host = host
        window = host.window!
        super.init()
        let views = allViews(host)
        detailHost = views.first { $0.identifier?.rawValue == "panel.detail.host" }
        tailHost = views.first { $0.identifier?.rawValue == "panel.detail.tail.host" }
    }

    func start() {
        record(CACurrentMediaTime())
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        let rate = Float(max(window.screen?.maximumFramesPerSecond ?? 60, 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() { link?.invalidate(); link = nil }
    @objc private func step(_ link: CADisplayLink) { record(link.targetTimestamp) }
    private func record(_ time: Double) {
        frames.append(["time": time, "height": window.frame.height, "top": window.frame.maxY,
                       "width": window.frame.width, "bodyBounds": host.bounds.height,
                       "detailBounds": detailHost?.bounds.height ?? -1,
                       "tailBounds": tailHost?.bounds.height ?? -1])
    }
}

@MainActor
private func focusedDetailTrace(_ name: String, reduced: Bool, panel: PanelContentController,
                                host: NSView, action: () -> Void) async {
    var sizeWrites = 0
    panel.didChangePresentationSize = { size in sizeWrites += 1; previewPopover.contentSize = size }
    let recorder = DetailCadenceRecorder(panel: panel, host: host)
    recorder.start()
    action()
    await settle(0.48)
    recorder.stop()
    let frames = recorder.frames
    let lo = min(frames.first!["height"]!, frames.last!["height"]!)
    let hi = max(frames.first!["height"]!, frames.last!["height"]!)
    let interior = frames.filter { $0["height"]! > lo + 2 && $0["height"]! < hi - 2 }
    let heights = Set(interior.map { $0["height"]! })
    var longestHold = 0.0
    var holdStart: Double?
    var heldHeight = -1.0
    for frame in interior {
        let height = frame["height"]!
        if height != heldHeight { heldHeight = height; holdStart = frame["time"]! }
        longestHold = max(longestHold, frame["time"]! - (holdStart ?? frame["time"]!))
    }
    try! JSONSerialization.data(withJSONObject: ["frames": frames, "sizeWrites": sizeWrites,
        "distinctInteriorHeights": heights.count, "longestHeightHold": longestHold], options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(name + "-cadence.json"))
    let startHeight = frames.first!["height"]!
    let endHeight = frames.last!["height"]!
    print("CADENCE \(name): samples=\(frames.count) interior=\(heights.count) maxHold=\(longestHold) sizeWrites=\(sizeWrites) first=\(startHeight) last=\(endHeight) active=\(panel.isDetailAnimating)")
    check(sizeWrites <= 1, name + " publishes native target layout only once per transition")
    check(reduced ? heights.isEmpty : heights.count >= 10,
          name + (reduced ? " omits spatial motion" : " has display-rate native height progression"))
    check(reduced || longestHold < 0.04, name + " has no prolonged intermediate-height stall")
    check(frames.allSatisfy { abs($0["top"]! - frames.first!["top"]!) <= 1 &&
                              $0["width"] == frames.first!["width"] }, name + " keeps top and width anchored")
    check(frames.allSatisfy { $0["detailBounds"]! > 0 && $0["tailBounds"]! > 0 }, name + " samples both real native content hosts")
    check(Set(frames.map { $0["detailBounds"]! }).count <= 2 &&
          Set(frames.map { $0["tailBounds"]! }).count == 1, name + " measures changed card once and keeps tail hosting bounds fixed")
    if !reduced {
        check(Set(interior.map { $0["detailBounds"]! }).count == 1, name + " keeps detail hosting bounds fixed during motion")
        check(Set(interior.map { $0["bodyBounds"]! }).count == 1, name + " avoids full SwiftUI body relayout on animation ticks")
    }
}

@MainActor
private func verifyDetailHandoff(panel: PanelContentController, host: NSView, overview: CGFloat) async {
    guard let window = host.window,
          let opening = PanelPresentationAnimation(popover: previewPopover, window: window) else { fail("detail handoff fixture") }
    var finishedOpening = false
    panel.suspendSizeUpdates()
    opening.open {
        opening.restore()
        panel.restoreSizeUpdates()
        finishedOpening = true
    }
    await settle(0.12)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.04)
    check(abs(host.bounds.height - overview) < 0.5, "detail input during panel opening keeps the old body layout stable")
    await settle(0.6)
    check(finishedOpening && !panel.isDetailAnimating, "detail queued during opening finishes after the outer animation")
    check(panel.naturalContentSize.height > overview + 40, "CPU clicked during panel opening actually expands detail")
    state("detail-opening-handoff", panel: panel, host: host)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.4)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.08)
    panel.finishDetailAnimation()
    check(!panel.isDetailAnimating, "native window handoff cancels the detail display link")
    state("detail-finish-handoff", panel: panel, host: host)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.4)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.08)
    press("打开显示与外观设置", in: host)
    await settle(0.35)
    check(panel.naturalContentSize.height < overview - 100, "settings click during detail expansion yields native window ownership")
    press("返回指标面板", in: host)
    await settle(0.4)
    check(panel.naturalContentSize.height > overview + 40, "returning from settings preserves selected detail")
    state("detail-navigation-handoff", panel: panel, host: host)
    click(host, NSPoint(x: 80, y: 120))
    await settle(0.4)
    check(abs(panel.naturalContentSize.height - overview) < 0.5, "handoff sequences restore exact overview height")
}

/// 滑块定向检查使用真实窗口事件；AX 只读取语义，不代替鼠标或键盘操作。
@MainActor
private func sliderKey(_ host: NSView, right: Bool) {
    guard let window = host.window else { fail("slider key event without window") }
    let text = right ? "\u{F703}" : "\u{F702}"
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: right ? 124 : 123) else { fail("native slider arrow event") }
        app.sendEvent(event)
    }
}

@MainActor
private func sliderDrag(_ host: NSView, y: CGFloat) async -> [Double] {
    guard let window = host.window else { fail("slider drag without window") }
    var values: [Double] = []
    // 32pt 滑钮、332pt 轨道：有效中心范围 x30...330，分别经过20/40/60/80%。
    for (type, x) in [(NSEvent.EventType.leftMouseDown, CGFloat(90)),
                      (.leftMouseDragged, 150), (.leftMouseDragged, 210),
                      (.leftMouseDragged, 270), (.leftMouseUp, 270)] {
        guard let event = NSEvent.mouseEvent(with: type,
            location: host.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { fail("native slider drag event") }
        app.sendEvent(event)
        await settle(0.06)
        values.append(preferences.panelTransparency)
    }
    return values
}

@MainActor
private func sliderZoom(_ bitmap: NSBitmapImageRep, region: NSRect, size: NSSize, name: String) {
    guard let cg = bitmap.cgImage else { fail("slider crop source") }
    let sx = CGFloat(bitmap.pixelsWide) / size.width
    let sy = CGFloat(bitmap.pixelsHigh) / size.height
    guard let cropped = cg.cropping(to: CGRect(x: region.minX * sx, y: region.minY * sy,
        width: region.width * sx, height: region.height * sy).integral),
        let zoom = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cropped.width * 3,
            pixelsHigh: cropped.height * 3, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: zoom) else { fail("slider enlarged crop") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .none
    NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width), height: CGFloat(cropped.height)))
        .draw(in: NSRect(x: 0, y: 0, width: CGFloat(zoom.pixelsWide), height: CGFloat(zoom.pixelsHigh)))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = zoom.representation(using: .png, properties: [:]) else { fail("slider crop PNG") }
    try! png.write(to: output.appendingPathComponent(name + "-slider-zoom.png"))
}

@MainActor
private func verifySliderOnly(_ tag: String, reduced: Bool, opaque: Bool,
                              panel: PanelContentController, host: NSView) async {
    press("打开显示与外观设置", in: host)
    await settle(0.5)
    guard let window = host.window else { fail("slider settings fixture window") }
    window.makeKey()
    await settle(0.05)
    check(window.isKeyWindow, tag + " settings accepts native keyboard events")
    let originalBounds = host.bounds
    let originalSize = panel.naturalContentSize
    let y: CGFloat = 228
    let region = NSRect(x: 10, y: y - 20, width: 340, height: 40)
    func sliderAX() -> NSObject? {
        accessibilityElements(window).first {
            accessibilityAttribute($0, "accessibilityIdentifier") as? String == "panel.transparency"
        }
    }
    let element = sliderAX()
    let initialAX = element.map { String(describing: accessibilityAttribute($0, "accessibilityValue") ?? "") } ?? "unavailable"
    if let element {
        check(accessibilityAttribute(element, "accessibilityLabel") as? String == "玻璃通透",
              tag + " publishes glass transparency accessibility label")
        check(!initialAX.isEmpty, tag + " publishes slider accessibility value")
    } else {
        print("SLIDER-NOTE \(tag): this probe does not expose the SwiftUI AX tree; AX runtime assertions skipped")
    }
    print("SLIDER-GEOMETRY \(tag): host=\(host.bounds) pointer center y=\(y) AX value=\(initialAX)")
    var clickValues: [Double] = []
    var axValues: [String] = []
    if opaque {
        let before = preferences.panelTransparency
        for x in [CGFloat(15), 180, 345] { click(host, NSPoint(x: x, y: y)); await settle(0.1) }
        let dragValues = await sliderDrag(host, y: y)
        sliderKey(host, right: true)
        await settle(0.1)
        check(preferences.panelTransparency == before && dragValues.allSatisfy { $0 == before },
              tag + " Reduce Transparency ignores click drag and keyboard without changing stored value")
        let bitmap = bodyBitmap(host, name: tag + "-disabled")
        sliderZoom(bitmap, region: region, size: host.bounds.size, name: tag + "-disabled")
    } else {
        for (name, x, target) in [("0", CGFloat(15), 0.0), ("50", CGFloat(180), 0.5), ("100", CGFloat(345), 1.0)] {
            click(host, NSPoint(x: x, y: y))
            await settle(0.4)
            let value = preferences.panelTransparency
            clickValues.append(value)
            check(abs(value - target) < 0.005, tag + " actual track click binds " + name + "%")
            if let currentAX = sliderAX() {
                let axValue = String(describing: accessibilityAttribute(currentAX, "accessibilityValue") ?? "")
                axValues.append(axValue)
                check(!axValue.isEmpty, tag + " AX retains value at " + name + "%")
            }
            hover(host, NSPoint(x: -20, y: y))
            await settle(0.4)
            let bitmap = bodyBitmap(host, name: tag + "-" + name)
            sliderZoom(bitmap, region: region, size: host.bounds.size, name: tag + "-" + name)
        }
        if element != nil {
            check(Set(axValues).count == 3, tag + " accessibility value follows 0 50 and 100 percent")
        }
        let dragged = await sliderDrag(host, y: y)
        print("SLIDER-DRAG \(tag): \(dragged)")
        check(dragged.count == 5 && dragged[1] > dragged[0] && dragged[2] > dragged[1] && dragged[3] > dragged[2],
              tag + " down drag up continuously changes actual binding")
        check(abs(preferences.panelTransparency - 0.8) < 0.01,
              tag + " real mouse drag releases at expected 80 percent")
        click(host, NSPoint(x: 180, y: y))
        await settle(0.1)
        let focused = preferences.panelTransparency
        sliderKey(host, right: true)
        await settle(0.1)
        check(abs(preferences.panelTransparency - focused - 0.01) < 0.005,
              tag + " focused right arrow increments exactly one percent")
        sliderKey(host, right: false)
        await settle(0.1)
        check(abs(preferences.panelTransparency - focused) < 0.005,
              tag + " focused left arrow decrements exactly one percent")
        hover(host, NSPoint(x: -20, y: y))
        await settle(0.5)
        let staticFirst = bodyBitmap(host, name: tag + "-static-first")
        await settle(0.25)
        let staticLast = bodyBitmap(host, name: tag + "-static-last")
        sliderZoom(staticLast, region: region, size: host.bounds.size, name: tag + "-static")
        if reduced {
            let delta = difference(staticFirst, staticLast, rect: region, size: host.bounds.size)
            print("SLIDER-STATIC \(tag): region difference=\(delta)")
            check(delta < 0.002, tag + " Reduce Motion leaves sparkle rendering stationary")
        }
    }
    check(host.bounds == originalBounds && panel.naturalContentSize == originalSize,
          tag + " slider input keeps settings layout fixed")
    try! JSONSerialization.data(withJSONObject: ["tag": tag, "centerY": Double(y),
        "clickValues": clickValues, "accessibilityValues": axValues, "accessibilityTreeAvailable": element != nil,
        "reduceMotion": reduced, "reduceTransparency": opaque,
        "limitation": "Glass samples the underlying content; screenshots document white sparkle fill and neutral material but cannot certify pure-color pixels or subjective texture."],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(tag + "-slider-results.json"))
}

func runFocusedDetailChecks(completion: @escaping () -> Void) {
    Task { @MainActor in
        guard let original = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("accessibilityDisplayShouldReduceMotion")),
              let replacement = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.panelProbeReducedMotion)),
              let originalGlass = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("accessibilityDisplayShouldReduceTransparency")),
              let replacementGlass = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.panelProbeReducedTransparency)) else { fail("focused accessibility accessors") }
        method_exchangeImplementations(original, replacement)
        method_exchangeImplementations(originalGlass, replacementGlass)
        defer {
            method_exchangeImplementations(original, replacement)
            method_exchangeImplementations(originalGlass, replacementGlass)
        }
        for (tag, reduced, opaque) in [("detail-normal", false, false), ("detail-reduced", true, false), ("detail-opaque", true, true)] {
            probeReducedMotion = reduced
            probeReducedTransparency = opaque
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            let positions = CommandLine.arguments.contains("--detail-jump-only") ? RootJumpRecorder() : nil
            let (panel, controller) = await hostPanel(reduced: reduced, positions: positions)
            let host = controller.view
            let overview = panel.naturalContentSize.height
            if CommandLine.arguments.contains("--slider-only") {
                await verifySliderOnly(tag.replacingOccurrences(of: "detail-", with: "slider-"),
                                       reduced: reduced, opaque: opaque, panel: panel, host: host)
                previewPopover.close()
                continue
            }
            if CommandLine.arguments.contains("--chrome-hover-only") {
                await verifyChromeHover(tag, reduced: reduced, panel: panel, host: host)
                await verifyHover(tag, "gear", at: NSPoint(x: 330, y: 34),
                                  region: NSRect(x: 306, y: 12, width: 48, height: 46),
                                  quiet: NSRect(x: 30, y: 160, width: 60, height: 34), host: host)
                await verifyHover(tag, "quit", at: NSPoint(x: 324, y: 550),
                                  region: NSRect(x: 296, y: 532, width: 56, height: 36),
                                  quiet: NSRect(x: 30, y: 160, width: 60, height: 34), host: host)
                click(host, NSPoint(x: 333, y: 26))
                await settle()
                check(panel.naturalContentSize.height < overview - 100, tag + " deflected header keeps gear clickable")
                await verifyHover(tag, "back", at: NSPoint(x: 26, y: 26),
                                  region: NSRect(x: 12, y: 12, width: 28, height: 28),
                                  quiet: NSRect(x: 170, y: 70, width: 60, height: 30), host: host)
                press("返回指标面板", in: host)
                await settle()
                click(host, NSPoint(x: 120, y: 550))
                await settle()
                check(panel.naturalContentSize.height < overview - 100, tag + " deflected footer keeps settings link clickable")
                press("返回指标面板", in: host)
                await settle()
                check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " chrome navigation restores overview geometry")
                previewPopover.close()
                continue
            }
            if let positions {
                for (name, point) in [("cpu", NSPoint(x: 80, y: 120)), ("gpu", NSPoint(x: 255, y: 120)),
                                      ("memory", NSPoint(x: 80, y: 270)), ("network", NSPoint(x: 255, y: 270))] {
                    positions.start(host: host)
                    click(host, point)
                    await settle(0.5)
                    positions.stop(name: tag + "-" + name + "-open")
                    check(panel.naturalContentSize.height > overview + 40, tag + " " + name + " position trace actually opens detail")
                    positions.start(host: host)
                    click(host, point)
                    await settle(0.5)
                    positions.stop(name: tag + "-" + name + "-close")
                    check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " " + name + " position trace restores overview")
                }
                previewPopover.close()
                continue
            }
            if CommandLine.arguments.contains("--detail-handoff-only") {
                await verifyDetailHandoff(panel: panel, host: host, overview: overview)
                previewPopover.close()
                print("PASS: focused detail handoff checks")
                completion()
                return
            }
            if CommandLine.arguments.contains("--detail-mid-only") {
                click(host, NSPoint(x: 80, y: 120))
                await settle(0.14)
                let visible = panel.view.convert(NSRect(origin: .zero, size: host.window!.frame.size), from: nil)
                print("MIDPOINT window=\(host.window!.frame) viewport=\(panel.view.frame) bounds=\(panel.view.bounds) visible=\(visible) body=\(host.frame) insets=\(panel.view.safeAreaInsets)")
                for view in panel.view.subviews { print("MIDVIEW \(type(of: view)) frame=\(view.frame) bounds=\(view.bounds)") }
                var ancestor = panel.view.superview
                while let view = ancestor {
                    print("MIDANCESTOR \(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) clips=\(view.clipsToBounds)")
                    ancestor = view.superview
                }
                save(host, name: "detail-mid-native", layout: false)
                await settle(0.4)
                previewPopover.close()
                completion()
                return
            }
            let cases = [("cpu", NSPoint(x: 80, y: 120)), ("gpu", NSPoint(x: 255, y: 120)),
                         ("memory", NSPoint(x: 80, y: 270)), ("network", NSPoint(x: 255, y: 270))]
            for (name, point) in reduced ? [cases[0], cases[2]] : cases {
                await focusedDetailTrace(tag + "-" + name + "-open", reduced: reduced, panel: panel, host: host) { click(host, point) }
                check(panel.naturalContentSize.height > overview + 40, tag + " " + name + " expands to actual natural detail size")
                state(tag + "-" + name + "-expanded", panel: panel, host: host)
                await focusedDetailTrace(tag + "-" + name + "-close", reduced: reduced, panel: panel, host: host) { click(host, NSPoint(x: 326, y: 379.5)) }
                check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " close button restores exact overview size")
            }
            click(host, cases[0].1)
            await settle(0.4)
            for (_, point) in cases.dropFirst() {
                click(host, point)
                await settle(0.4)
                check(panel.naturalContentSize.height > overview + 40, tag + " metric switch keeps detail expanded")
            }
            click(host, cases[3].1)
            await settle(0.08)
            click(host, cases[0].1)
            await settle(0.08)
            click(host, cases[0].1)
            await settle(0.4)
            check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " interrupted close-open-close settles without residual height")
            if !reduced {
                click(host, cases[0].1)
                await settle(0.14)
                let insets = panel.view.safeAreaInsets
                print("MIDPOINT: window=\(host.window!.frame) viewport=\(panel.view.frame) body=\(host.frame) insets=\(insets)")
                for view in panel.view.subviews { print("MIDVIEW: \(type(of: view)) frame=\(view.frame)") }
                save(host, name: "detail-mid-native", layout: false)
                await settle(0.4)
                click(host, cases[0].1)
                await settle(0.4)
                // 下方机器信息保持原来的真实交互与状态，原生 hosting 不应随展开重建。
                for _ in 0..<6 { click(host, NSPoint(x: 175, y: 390)); await settle(0.13) }
                await settle(0.2)
                save(host, name: "detail-tail-state-native")
            }
        }
        previewPopover.close()
        let sliderOnly = CommandLine.arguments.contains("--slider-only")
        try! JSONSerialization.data(withJSONObject: ["passedAssertions": nativeChecks.count, "checks": nativeChecks,
            "geometry": geometryRecords], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(sliderOnly ? "slider-results.json" : "detail-results.json"))
        print("PASS: \(nativeChecks.count) focused \(sliderOnly ? "slider" : "detail animation") assertions; unrelated native checks skipped")
        completion()
    }
}

func runExtendedNativeChecks(completion: @escaping () -> Void) {
    Task { @MainActor in
        originalTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        probeReducedTransparency = originalTransparency
        originalMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        probeReducedMotion = originalMotion
        guard let original = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("accessibilityDisplayShouldReduceMotion")),
              let replacement = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.panelProbeReducedMotion)) else { fail("isolated Reduce Motion accessor") }
        method_exchangeImplementations(original, replacement)
        guard let originalGlass = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("accessibilityDisplayShouldReduceTransparency")),
              let replacementGlass = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.panelProbeReducedTransparency)) else { fail("isolated Reduce Transparency accessor") }
        method_exchangeImplementations(originalGlass, replacementGlass)
        defer {
            method_exchangeImplementations(original, replacement)
            method_exchangeImplementations(originalGlass, replacementGlass)
        }
        for (tag, reduced, opaque) in [("normal", false, false), ("reduced", true, false), ("opaque", true, true)] {
            probeReducedMotion = reduced
            probeReducedTransparency = opaque
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            await settle(0.10)
            let positions = RootJumpRecorder()
            let (panel, controller) = await hostPanel(reduced: reduced, positions: positions)
            let host = controller.view
            let overview = panel.naturalContentSize.height
            state(tag + "-overview", panel: panel, host: host)
            save(host, name: tag + "-overview-native")
            await verifyChromeHover(tag, reduced: reduced, panel: panel, host: host)
            await verifyHover(tag, "gear", at: NSPoint(x: 330, y: 34),
                              region: NSRect(x: 306, y: 12, width: 48, height: 46),
                              quiet: NSRect(x: 30, y: 160, width: 60, height: 34), host: host)
            await verifyHover(tag, "cpu", at: NSPoint(x: 30, y: 100),
                              region: NSRect(x: 14, y: 78, width: 162, height: 136),
                              quiet: NSRect(x: 200, y: 275, width: 60, height: 34), host: host)
            await verifyMagneticEdges(tag, reduced: reduced, panel: panel, host: host)
            await verifyHover(tag, "quit", at: NSPoint(x: 324, y: 550),
                              region: NSRect(x: 296, y: 532, width: 56, height: 36),
                              quiet: NSRect(x: 30, y: 160, width: 60, height: 34), host: host)
            let viewAX = accessibilityElements(host.window as Any).map { element in
                ["identifier": accessibilityAttribute(element, "accessibilityIdentifier") as? String ?? "",
                 "label": accessibilityAttribute(element, "accessibilityLabel") as? String ?? "",
                 "value": String(describing: accessibilityAttribute(element, "accessibilityValue") ?? "")]
            }
            try! JSONSerialization.data(withJSONObject: viewAX, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(tag + "-ax-tree.json"))

            press("打开显示与外观设置", in: host)
            await settle()
            let settingsHeight = panel.naturalContentSize.height
            check(settingsHeight < overview - 100, tag + " actual gear click switches to shorter settings")
            state(tag + "-settings", panel: panel, host: host)
            save(host, name: tag + "-settings-native")
            if opaque {
                let before = preferences.panelTransparency
                click(host, NSPoint(x: 337, y: 224))
                await settle()
                check(preferences.panelTransparency == before, "opaque native transparency slider is disabled")
            } else {
                await verifyHover(tag, "slider", at: NSPoint(x: 200, y: 224),
                                  region: NSRect(x: 10, y: 208, width: 340, height: 32),
                                  quiet: NSRect(x: 30, y: 260, width: 60, height: 30), host: host)
            }
            await verifyHover(tag, "restore", at: NSPoint(x: 36, y: 350),
                              region: NSRect(x: 14, y: 338, width: 332, height: 31),
                              quiet: NSRect(x: 30, y: 260, width: 60, height: 30), host: host)
            await verifyHover(tag, "login", at: NSPoint(x: 88, y: 313),
                              region: NSRect(x: 60, y: 296, width: 56, height: 34),
                              quiet: NSRect(x: 30, y: 260, width: 60, height: 30), host: host)
            for (x, interval) in [(57.0, 0.5), (139.0, 1.0), (222.0, 2.0), (304.0, 5.0)] {
                click(host, NSPoint(x: x, y: 91))
                await settle(0.10)
                check(preferences.refreshInterval == interval, tag + " refresh segment " + String(interval) + " binds through actual click")
            }
            for (x, layout) in [(57.0, MenuBarLayout.auto), (139.0, .full), (222.0, .compact), (304.0, .minimal)] {
                click(host, NSPoint(x: x, y: 160))
                await settle(0.10)
                check(preferences.menuBarLayout == layout, tag + " layout segment " + layout.rawValue + " binds through actual click")
            }
            let loginMock = SMAppService.mainApp
            let previousRegistrations = loginMock.registerCalls
            let previousUnregistrations = loginMock.unregisterCalls
            click(host, NSPoint(x: 88, y: 313))
            await settle(0.10)
            check(loginMock.registerCalls == previousRegistrations + 1, tag + " native login toggle invokes only mocked registration")
            click(host, NSPoint(x: 88, y: 313))
            await settle(0.10)
            check(loginMock.unregisterCalls == previousUnregistrations + 1, tag + " native login toggle invokes only mocked unregistration")
            press("恢复显示默认值", in: host)
            await settle(0.10)
            check(preferences.refreshInterval == Preferences.DisplayDefaults.refreshInterval && preferences.menuBarLayout == Preferences.DisplayDefaults.menuBarLayout,
                  tag + " isolated restore button resets native settings bindings")
            press("返回指标面板", in: host)
            await settle()
            check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " actual back click restores overview natural height")
            state(tag + "-overview-return", panel: panel, host: host)

            for (name, point) in [("cpu", NSPoint(x: 80, y: 120)), ("gpu", NSPoint(x: 255, y: 120)),
                                   ("memory", NSPoint(x: 80, y: 270)), ("network", NSPoint(x: 255, y: 270))] {
                positions.start(host: host)
                let opening = await detailFrames(tag + "-" + name + "-open", panel: panel, host: host) { click(host, point) }
                positions.stop(name: tag + "-" + name + "-open")
                verifyDetailFrames(opening, name: tag + " " + name + " detail opening", reduced: reduced)
                check(panel.naturalContentSize.height > overview + 40, tag + " " + name + " native metric click expands detail")
                state(tag + "-" + name + "-detail", panel: panel, host: host)
                save(host, name: tag + "-" + name + "-detail")
                positions.start(host: host)
                let closing = await detailFrames(tag + "-" + name + "-close", panel: panel, host: host) { click(host, point) }
                positions.stop(name: tag + "-" + name + "-close")
                verifyDetailFrames(closing, name: tag + " " + name + " detail closing", reduced: reduced)
                check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " " + name + " second click collapses detail")
            }

            click(host, NSPoint(x: 80, y: 120))
            await settle()
            for point in [NSPoint(x: 255, y: 120), NSPoint(x: 80, y: 270), NSPoint(x: 255, y: 270)] {
                let switching = await detailFrames(tag + "-detail-switch-\(Int(point.x))-\(Int(point.y))", panel: panel, host: host) { click(host, point) }
                check(switching.allSatisfy { $0["body"]! > overview + 40 }, tag + " changing metric keeps detail expanded")
            }
            let dismissing = await detailFrames(tag + "-detail-dismiss", panel: panel, host: host) { click(host, NSPoint(x: 326, y: 379.5)) }
            verifyDetailFrames(dismissing, name: tag + " detail close button", reduced: reduced)
            check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " close button restores overview height")
            click(host, NSPoint(x: 80, y: 120))
            await settle(0.08)
            click(host, NSPoint(x: 80, y: 120))
            await settle(0.06)
            click(host, NSPoint(x: 255, y: 120))
            await settle(0.36)
            check(panel.naturalContentSize.height > overview + 40, tag + " rapid reversal and metric switch settle expanded")
            click(host, NSPoint(x: 326, y: 379.5))
            await settle()
            check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " rapid reversal leaves no detail height behind")

            // 鼠标实际进入机器信息栏。指标采样停止，不用变化的读数制造图像差异。
            hover(host, NSPoint(x: -20, y: 390))
            await settle()
            let neutral = bodyBitmap(host, name: tag + "-hover-neutral")
            hover(host, NSPoint(x: 32, y: 380))
            await settle(0.5)
            save(host, name: tag + "-hover-left-native")
            let left = bodyBitmap(host, name: tag + "-hover-left")
            hover(host, NSPoint(x: 327, y: 420))
            await settle(0.5)
            save(host, name: tag + "-hover-right-native")
            let right = bodyBitmap(host, name: tag + "-hover-right")
            let cardRect = NSRect(x: 14, y: 365, width: 332, height: 73)
            let activationDiff = difference(neutral, left, rect: cardRect, size: host.bounds.size)
            let directionDiff = difference(left, right, rect: cardRect, size: host.bounds.size)
            check(darkFraction(left, rect: cardRect, size: host.bounds.size) < 0.10 &&
                  darkFraction(right, rect: cardRect, size: host.bounds.size) < 0.10,
                  tag + " device glass has no black blocks at either pointer edge")
            print("PIXELS \(tag): hover activation=\(activationDiff), direction=\(directionDiff)")
            check(activationDiff > 0.0001, tag + " actual hover produces a rendered card change")
            if reduced {
                check(directionDiff < 0.002, "reduced hover remains centered instead of following pointer")
            } else {
                check(directionDiff > 0.0001, "normal reflection or perspective follows actual pointer position")
            }
            let shadowLayers = allViews(host).compactMap(\.layer).flatMap(allLayers).filter { $0.shadowOpacity > 0.001 }
            check(shadowLayers.isEmpty, tag + " live SwiftUI hosting hierarchy has no active custom layer shadow")
            check(panel.naturalContentSize.height == overview && host.bounds.width == 360, tag + " hover keeps natural geometry fixed")
            hover(host, NSPoint(x: -20, y: 390))
            await settle()
            let idle = bodyBitmap(host, name: tag + "-egg-idle")
            for _ in 0..<6 { click(host, NSPoint(x: 175, y: 390)); await settle(0.13) }
            await settle(0.20)
            save(host, name: tag + "-egg-celebration-native")
            let celebration = bodyBitmap(host, name: tag + "-egg-celebration")
            let textRect = NSRect(x: 47, y: 404, width: 270, height: 27)
            let celebrationDiff = difference(idle, celebration, rect: textRect, size: host.bounds.size)
            print("PIXELS \(tag): celebration text=\(celebrationDiff)")
            check(celebrationDiff > 0.003, tag + " six real clicks replace rendered memory row with celebration prompt")
            check(panel.naturalContentSize.height == overview && host.bounds.width == 360, tag + " celebration does not resize panel")
            await settle(1.95)
            let restored = bodyBitmap(host, name: tag + "-egg-restored")
            save(host, name: tag + "-egg-restored-native")
            let restoreDiff = difference(idle, restored, rect: textRect, size: host.bounds.size)
            print("PIXELS \(tag): restored text=\(restoreDiff)")
            check(restoreDiff < 0.002, tag + " celebration automatically restores exact rendered memory row")

            for _ in 0..<3 { click(host, NSPoint(x: 175, y: 390)); await settle(0.10) }
            await settle(1.5)
            for _ in 0..<3 { click(host, NSPoint(x: 175, y: 390)); await settle(0.10) }
            let partial = bodyBitmap(host, name: tag + "-egg-timeout-partial")
            check(difference(idle, partial, rect: textRect, size: host.bounds.size) < 0.002,
                  tag + " abandoned combo expires and next three clicks do not celebrate")
            press("打开显示与外观设置", in: host)
            await settle(0.30)
            press("返回指标面板", in: host)
            await settle(0.30)
            for _ in 0..<3 { click(host, NSPoint(x: 175, y: 390)); await settle(0.10) }
            let afterNavigation = bodyBitmap(host, name: tag + "-egg-cancelled-navigation")
            check(difference(idle, afterNavigation, rect: textRect, size: host.bounds.size) < 0.002,
                  tag + " page disappearance cancels previous partial combo")
            for _ in 0..<3 { click(host, NSPoint(x: 175, y: 390)); await settle(0.10) }
            press("打开显示与外观设置", in: host)
            await settle(0.30)
            press("返回指标面板", in: host)
            await settle(0.30)
            click(host, NSPoint(x: 175, y: 390))
            await settle(1.05)
            for _ in 0..<5 { click(host, NSPoint(x: 175, y: 390)); await settle(0.13) }
            await settle(0.20)
            let cancelled = bodyBitmap(host, name: tag + "-egg-cancelled-celebration-new-round")
            check(difference(idle, cancelled, rect: textRect, size: host.bounds.size) > 0.003,
                  tag + " old celebration task cancelled on navigation cannot clear a new six-click round")
            await settle(1.95)
            check(difference(idle, bodyBitmap(host, name: tag + "-egg-new-round-restored"), rect: textRect, size: host.bounds.size) < 0.002,
                  tag + " new celebration after cancellation also restores memory row")
            state(tag + "-final", panel: panel, host: host)
        }
        probeReducedTransparency = originalTransparency
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        previewPopover.close()
        await controllerChecks()
        probeReducedMotion = originalMotion
        nativeNotes.append("Reduce Transparency is exercised with a process-only NSWorkspace getter replacement; opaque screenshots and disabled slider are checked without changing system preferences.")
        nativeNotes.append("Reduce Motion uses an isolated process-only NSWorkspace getter replacement plus native accessibility-change notification; SwiftUI branch is verified by centered hover output. It does not change macOS settings and is not OS-setting end-to-end validation.")
        nativeNotes.append("Screenshots with '-native' are full WindowServer crops at exact native window frame, including arrow/glass; '-body' are WindowServer crops of only the SwiftUI body. A probe-only neutral backdrop prevents underlying conversations from appearing.")
        nativeNotes.append("Pixel checks establish hover rendering changes and celebration memory-row replacement/restoration; they do not certify typography sharpness or subjective glass quality.")
        nativeNotes.append("Native menu reflection was checked with synthesized local NSEvent tracking callbacks delivered to the probe-owned production glass view. CG pointer movement alone did not trigger that receiver here, so physical menu tracking is not certified. SwiftUI card hover was exercised with actual CG pointer movement and WindowServer pixel evidence.")
        nativeNotes.append("Frame geometry observations are not a 60Hz frame-time performance certification.")
        try! JSONSerialization.data(withJSONObject: ["passedAssertions": nativeChecks.count,
            "checks": nativeChecks, "geometryStateCount": geometryRecords.count,
            "geometry": geometryRecords, "limitations": nativeNotes], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-results.json"))
        print("PASS: \(nativeChecks.count) substantive native assertions, \(geometryRecords.count) measured geometry states")
        completion()
    }
}
