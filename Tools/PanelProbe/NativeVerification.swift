import AppKit
import SwiftUI
import QuartzCore
import ObjectiveC
import ServiceManagement

// 本文件只编译进隔离 probe。系统偏好不会改变；该替换只影响当前进程的读取。
private var probeReducedMotion = false
extension NSWorkspace {
    @objc func panelProbeReducedMotion() -> Bool { probeReducedMotion }
}

private var nativeChecks: [String] = []
private var nativeNotes: [String] = []
private var geometryRecords: [[String: Any]] = []
private var originalMotion: Bool = false

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
private func hostPanel(reduced: Bool) async -> (PanelContentController, NSHostingController<AnyView>) {
    previewPopover.close()
    previewPopover.contentViewController = nil
    let measurement = PanelContentMeasurement()
    preferences.resetDisplaySettings()
    let dashboard = DashboardView(monitor: monitor, preferences: preferences, usesWindowSurface: true,
                                  naturalSizeDidChange: { measurement.receive($0) })
    let host = NSHostingController(rootView: AnyView(dashboard))
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

func runExtendedNativeChecks(completion: @escaping () -> Void) {
    Task { @MainActor in
        originalMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        probeReducedMotion = originalMotion
        guard let original = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("accessibilityDisplayShouldReduceMotion")),
              let replacement = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.panelProbeReducedMotion)) else { fail("isolated Reduce Motion accessor") }
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        for reduced in [false, true] {
            probeReducedMotion = reduced
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            await settle(0.10)
            let tag = reduced ? "reduced" : "normal"
            let (panel, controller) = await hostPanel(reduced: reduced)
            let host = controller.view
            let overview = panel.naturalContentSize.height
            state(tag + "-overview", panel: panel, host: host)
            save(host, name: tag + "-overview-native")
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
                click(host, point)
                await settle()
                check(panel.naturalContentSize.height > overview + 40, tag + " " + name + " native metric click expands detail")
                state(tag + "-" + name + "-detail", panel: panel, host: host)
                save(host, name: tag + "-" + name + "-detail")
                click(host, point)
                await settle()
                check(abs(panel.naturalContentSize.height - overview) < 0.5, tag + " " + name + " second click collapses detail")
            }

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
        previewPopover.close()
        await controllerChecks()
        probeReducedMotion = originalMotion
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
