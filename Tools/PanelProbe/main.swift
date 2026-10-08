import AppKit
import Combine
import SwiftUI

// 原生视图渲染探针：使用隔离偏好与登录项 mock，不安装应用或修改正式偏好。
// 与 Tools/Regression 生成的 ServiceManagement mock 一起编译。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let interactiveMode = CommandLine.arguments.contains("--interactive")
let outputArgument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
let output = URL(fileURLWithPath: outputArgument ?? "build/panel-preview")
if !interactiveMode {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
}
let suite = "SysPulse.PanelProbe.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
if interactiveMode, let installed = UserDefaults.standard.persistentDomain(forName: "com.local.syspulse") {
    let displayKeys = [Preferences.Keys.showNetwork, Preferences.Keys.showCPU,
                       Preferences.Keys.showGPU, Preferences.Keys.showMemory,
                       Preferences.Keys.refreshInterval, Preferences.Keys.menuBarLayout,
                       Preferences.Keys.menuBarEffect, Preferences.Keys.panelTransparency]
    for key in displayKeys {
        if let value = installed[key] { defaults.set(value, forKey: key) }
    }
}
let preferences = Preferences(defaults: defaults)
let monitor = SystemMonitor()
if !interactiveMode {
    for _ in 0..<12 { monitor.sampleOnce() }
}

struct PreviewState {
    let name: String
    let appearance: NSAppearance.Name
    let page: DashboardPage
    let detail: DashboardDetail?
    let transparency: Double
}
let states = [
    PreviewState(name: "dark", appearance: .darkAqua, page: .overview, detail: nil, transparency: 0.30),
    PreviewState(name: "light", appearance: .aqua, page: .overview, detail: nil, transparency: 0.30),
    PreviewState(name: "settings", appearance: .aqua, page: .settings, detail: nil, transparency: 0.30),
    PreviewState(name: "settings-dark", appearance: .darkAqua, page: .settings, detail: nil, transparency: 1),
    PreviewState(name: "memory-detail", appearance: .darkAqua, page: .overview, detail: .memory, transparency: 0),
    PreviewState(name: "network-detail", appearance: .aqua, page: .overview, detail: .network, transparency: 1),
    PreviewState(name: "frosted", appearance: .aqua, page: .overview, detail: nil, transparency: 0),
    PreviewState(name: "clear", appearance: .aqua, page: .overview, detail: nil, transparency: 1),
    PreviewState(name: "frosted-dark", appearance: .darkAqua, page: .overview, detail: nil, transparency: 0),
    PreviewState(name: "clear-dark", appearance: .darkAqua, page: .overview, detail: nil, transparency: 1)
]
final class PanelPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let popoverMode = interactiveMode || CommandLine.arguments.contains("--popover")
let previewPopover = NSPopover()
previewPopover.behavior = .applicationDefined
previewPopover.animates = false
previewPopover.hasFullSizeContent = true
let previewItem: NSStatusItem? = popoverMode ? NSStatusBar.system.statusItem(withLength: interactiveMode ? NSStatusItem.variableLength : NSStatusItem.squareLength) : nil
previewItem?.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "SysPulse 验证")
if interactiveMode {
    previewItem?.button?.title = "测试"
    previewItem?.button?.imagePosition = .imageLeft
    previewItem?.button?.setAccessibilityLabel("SysPulse 测试")
}
var currentWindow: NSWindow?
var reports: [String] = []
var rendered: [String: NSImage] = [:]

func fail(_ message: String) -> Never {
    defaults.removePersistentDomain(forName: suite)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func save(_ hosting: NSView, name: String) {
    hosting.layoutSubtreeIfNeeded()
    if CGPreflightScreenCaptureAccess(), let window = hosting.window {
        let destination = output.appendingPathComponent("\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let frame = window.frame
        let screenTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let region = "\(Int(frame.minX)),\(Int(screenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        capture.arguments = ["-x", "-R", region, destination.path]
        do { try capture.run(); capture.waitUntilExit() }
        catch { fail("window capture \(error)") }
        guard capture.terminationStatus == 0, let image = NSImage(contentsOf: destination) else { fail("window capture \(name)") }
        image.size = frame.size
        rendered[name] = image
        let report = "\(name): \(Int(hosting.bounds.width)) × \(Int(hosting.bounds.height)) pt (WindowServer capture)"
        print(report)
        reports.append(report)
        return
    }
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("bitmap \(name)") }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fail("PNG \(name)") }
    do { try data.write(to: output.appendingPathComponent("\(name).png")) }
    catch { fail("save \(name): \(error)") }
    let image = NSImage(size: hosting.bounds.size)
    image.addRepresentation(bitmap)
    rendered[name] = image
    let report = "\(name): \(Int(hosting.bounds.width)) × \(Int(hosting.bounds.height)) pt"
    print(report)
    reports.append(report)
}

func accessibilityAttribute(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
}

func accessibilityElements(_ object: Any, depth: Int = 0) -> [NSObject] {
    guard depth < 30, let element = object as? NSObject else { return [] }
    let children = accessibilityAttribute(element, "accessibilityChildren") as? [Any] ?? []
    return [element] + children.flatMap { accessibilityElements($0, depth: depth + 1) }
}

func press(_ label: String, in hosting: NSView) {
    let elements = accessibilityElements(hosting)
    if let object = elements.first(where: {
        accessibilityAttribute($0, "accessibilityLabel") as? String == label
    }), let element = object as? NSAccessibilityProtocol, element.accessibilityPerformPress() {
        print("PASS: native accessibility press \(label)")
        return
    }
    let point: NSPoint
    switch label {
    case "菜单栏显示网速": point = NSPoint(x: 88, y: hosting.bounds.height - 117)
    case "打开显示与外观设置": point = NSPoint(x: 333, y: 26)
    case "刷新频率，2 秒": point = NSPoint(x: 222, y: 91)
    case "菜单栏排版，双行": point = NSPoint(x: 222, y: 160)
    case "菜单栏光效，光晕": point = NSPoint(x: 236, y: hosting.bounds.height - 70)
    case "菜单栏光效，炫彩": point = NSPoint(x: 311, y: hosting.bounds.height - 70)
    case "玻璃通透": point = NSPoint(x: 337, y: 224)
    case "恢复显示默认值": point = NSPoint(x: 180, y: hosting.bounds.height - 29)
    case "返回指标面板": point = NSPoint(x: 25, y: 26)
    default: fail("unknown native control \(label)")
    }
    guard let window = hosting.window else { fail("control has no window") }
    let local = hosting.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
            fail("mouse event \(label)")
        }
        app.sendEvent(event)
    }
    print("Native mouse click: \(label) at \(point)")
}

func interactionCheck(_ hosting: NSView, completion: @escaping () -> Void) {
    let original = preferences.showNetwork
    let overviewHeight = hosting.fittingSize.height
    press("菜单栏显示网速", in: hosting)
    guard preferences.showNetwork != original else { fail("network toggle did not update preference") }
    press("菜单栏显示网速", in: hosting)
    press("菜单栏光效，光晕", in: hosting)
    guard preferences.menuBarEffect == .diffuse else { fail("overview effect choice") }
    press("菜单栏光效，炫彩", in: hosting)
    guard preferences.menuBarEffect == .iridescent else { fail("overview iridescent effect choice") }
    press("打开显示与外观设置", in: hosting)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        press("刷新频率，2 秒", in: hosting)
        guard preferences.refreshInterval == 2 else { fail("refresh segmented choice") }
        press("菜单栏排版，双行", in: hosting)
        guard preferences.menuBarLayout == .compact else { fail("layout segmented choice") }
        press("玻璃通透", in: hosting)
        guard preferences.panelTransparency > 0.90, preferences.panelTransparency <= 1 else { fail("full-range transparency slider binding") }
        press("恢复显示默认值", in: hosting)
        guard preferences.refreshInterval == 2, preferences.menuBarLayout == .auto,
              preferences.menuBarEffect == .diffuse, preferences.panelTransparency == 0.71,
              preferences.showNetwork, preferences.showCPU, preferences.showGPU,
              preferences.showMemory else { fail("reset button binding") }
        press("返回指标面板", in: hosting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard hosting.fittingSize.height == overviewHeight else {
                fail("navigation did not return to metrics")
            }
            preferences.resetDisplaySettings()
            print("PASS: native settings navigation and preference bindings")
            completion()
        }
    }
}

func makeBoard(names: [String] = ["dark", "light", "settings"],
               captions: [String] = ["深色", "浅色", "显示与外观"],
               heading: String = "SysPulse · 原生 SwiftUI 面板预览",
               filename: String = "panel-board") {
    let board = NSImage(size: NSSize(width: 1400, height: 760))
    board.lockFocus()
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1400, height: 760).fill()
    let title = NSAttributedString(string: heading, attributes: [
        .font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)
    ])
    title.draw(at: NSPoint(x: 32, y: 676))
    let captureNote = CGPreflightScreenCaptureAccess() ? "真实窗口捕获 · 玻璃材质随桌面背景变化" : "真实视图离屏渲染 · 玻璃背景以实际窗口为准"
    let note = NSAttributedString(string: captureNote, attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray
    ])
    note.draw(at: NSPoint(x: 32, y: 652))
    for (index, name) in names.enumerated() {
        guard let image = rendered[name] else { fail("board missing \(name)") }
        let x = CGFloat(40 + index * 450)
        image.draw(in: NSRect(x: x, y: 640 - image.size.height, width: image.size.width, height: image.size.height))
        let caption = captions[index]
        NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.darkGray])
            .draw(at: NSPoint(x: x, y: 26))
    }
    board.unlockFocus()
    guard let tiff = board.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fail("board PNG") }
    do { try png.write(to: output.appendingPathComponent("\(filename).png")) }
    catch { fail("board save \(error)") }
}

func render(_ index: Int) {
    if popoverMode {
        previewPopover.close()
        previewPopover.contentViewController = nil
    } else {
        currentWindow?.orderOut(nil)
    }
    currentWindow = nil
    if index == states.count {
        makeBoard()
        makeBoard(names: ["frosted", "clear", "settings"],
                  captions: ["厚磨砂 · 0%", "清透玻璃 · 100%", "玻璃通透 · 完整尺度"],
                  heading: "SysPulse · 玻璃材质实际调节效果", filename: "material-board")
        runExtendedNativeChecks {
            try? reports.joined(separator: "\n").write(to: output.appendingPathComponent("layout.txt"), atomically: true, encoding: .utf8)
            defaults.removePersistentDomain(forName: suite)
            print("PASS: rendered \(states.count) original native panel states plus extended interaction coverage; isolated preferences cleaned up")
            app.terminate(nil)
        }
        return
    }
    let state = states[index]
    let appearance = NSAppearance(named: state.appearance)!
    app.appearance = appearance
    preferences.panelTransparency = state.transparency
    let measurement = PanelContentMeasurement()
    let root = DashboardView(monitor: monitor, preferences: preferences, initialPage: state.page,
                             initialDetail: state.detail, usesWindowSurface: popoverMode,
                             naturalSizeDidChange: { measurement.receive($0) })
    let controller = NSHostingController(rootView: AnyView(root))
    controller.sizingOptions = .preferredContentSize
    controller.safeAreaRegions = []
    let hosting = controller.view
    let size = controller.sizeThatFits(in: NSSize(width: 360, height: 1200))
    controller.preferredContentSize = size
    guard let panel = PanelContentController(hosting: controller, preferences: preferences) else { fail("production panel container initialization") }
    measurement.attach(panel)
    panel.didChangePresentationSize = { previewPopover.contentSize = $0 }
    guard size.width == 360, size.height > 300, size.height < 800 else { fail("unexpected layout \(state.name): \(size)") }
    app.activate(ignoringOtherApps: true)
    if popoverMode {
        guard let button = previewItem?.button else { fail("status button missing") }
        previewPopover.appearance = NSAppearance(named: .aqua)
        previewPopover.contentViewController = panel
        previewPopover.contentSize = panel.preferredContentSize
        previewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.prepareFullSizeLayout()
    } else {
        let window = PanelPreviewWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentViewController = controller
        window.setFrameOrigin(NSPoint(x: 40, y: 100))
        currentWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if popoverMode {
            guard let window = hosting.window else {
                fail("popover window missing; shown=\(previewPopover.isShown), anchorWindow=\(previewItem?.button?.window != nil)")
            }
            window.appearance = appearance
            window.makeKey()
            currentWindow = window
        }
        save(hosting, name: state.name)
        if index == 0 {
            interactionCheck(hosting) { render(index + 1) }
        } else {
            render(index + 1)
        }
    }
}
final class InteractivePreview: NSObject, NSApplicationDelegate {
    private var sampler: Timer?
    private var effectTimer: Timer?
    private var preferenceChanges: AnyCancellable?
    private var refreshInterval: Double?
    private var effect: MenuBarEffect?
    private let effectStarted = ProcessInfo.processInfo.systemUptime

    func start() {
        let measurement = PanelContentMeasurement()
        let root = DashboardView(monitor: monitor, preferences: preferences, usesWindowSurface: true,
                                 naturalSizeDidChange: { measurement.receive($0) })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .preferredContentSize
        controller.safeAreaRegions = []
        controller.preferredContentSize = controller.sizeThatFits(in: NSSize(width: 360, height: 1200))
        guard let panel = PanelContentController(hosting: controller, preferences: preferences) else { fail("interactive full-window panel") }
        panel.didChangePresentationSize = { previewPopover.contentSize = $0 }
        measurement.attach(panel)
        previewPopover.contentViewController = panel
        previewPopover.contentSize = panel.preferredContentSize
        previewItem?.button?.target = self
        previewItem?.button?.action = #selector(togglePopover)
        preferenceChanges = preferences.objectWillChange.sink { [weak self] _ in
            // @Published announces before assignment; read the new values on the next main-loop turn.
            DispatchQueue.main.async { [weak self] in self?.updateTimersAndStatusItem() }
        }
        monitor.sampleOnce()
        updateTimersAndStatusItem()
        showPopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard previewPopover.isShown, let window = controller.view.window else {
                fail("interactive popover did not open")
            }
            window.title = "SysPulse 测试"
            window.makeKey()
            print("READY: SysPulse 测试交互预览；显示偏好仅写入隔离套件 \(suite)")
            fflush(stdout)
        }
    }

    @objc private func togglePopover() {
        if previewPopover.isShown {
            previewPopover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = previewItem?.button else { fail("interactive status button missing") }
        app.activate(ignoringOtherApps: true)
        previewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        (previewPopover.contentViewController as? PanelContentController)?.prepareFullSizeLayout()
        DispatchQueue.main.async {
            previewPopover.contentViewController?.view.window?.title = "SysPulse 测试"
            previewPopover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateTimersAndStatusItem() {
        let requested = preferences.refreshInterval
        let interval = requested.isFinite ? max(requested, 0.25) : 1
        if refreshInterval != interval {
            refreshInterval = interval
            sampler?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                monitor.sampleOnce()
                self?.drawStatusItem()
            }
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            sampler = timer
        }
        if effect != preferences.menuBarEffect {
            effect = preferences.menuBarEffect
            effectTimer?.invalidate()
            effectTimer = nil
            if preferences.menuBarEffect != .off {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.drawStatusItem()
                }
                timer.tolerance = 0.01
                RunLoop.main.add(timer, forMode: .common)
                effectTimer = timer
            }
        }
        drawStatusItem()
    }

    private func drawStatusItem() {
        guard let button = previewItem?.button else { return }
        let density: MenuBarDensity
        switch preferences.menuBarLayout {
        case .auto, .full: density = .full
        case .compact: density = .compact
        case .minimal: density = .minimal
        }
        button.image = MenuBarImage.render(snapshot: monitor.snapshot, preferences: preferences,
            appearance: button.effectiveAppearance, density: density, effect: preferences.menuBarEffect,
            effectElapsed: ProcessInfo.processInfo.systemUptime - effectStarted)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampler?.invalidate()
        effectTimer?.invalidate()
        preferenceChanges?.cancel()
        defaults.removePersistentDomain(forName: suite)
    }
}

let nativeBackdrop: NSWindow? = !interactiveMode ? {
    guard let screen = NSScreen.main else { return nil }
    let window = PanelPreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)
    window.level = .normal
    window.orderFrontRegardless()
    return window
}() : nil

let interactivePreview = interactiveMode ? InteractivePreview() : nil
if let interactivePreview {
    app.delegate = interactivePreview
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { interactivePreview.start() }
} else {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { render(0) }
}
app.run()
