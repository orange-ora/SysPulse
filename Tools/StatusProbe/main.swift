import AppKit
import SwiftUI

// 验证工具：把状态栏项与下拉面板都真实渲染到屏幕上，便于截图检查。
// 无参数：显示状态栏项；带 window 参数：额外打开一个真实窗口展示面板。

let probeVersion = "PROBE-V3-TOGGLEFRAMES"   // 用来确认跑的是不是最新编译的产物

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let monitor = SystemMonitor()
for _ in 0..<40 {
    monitor.sampleOnce()
    Thread.sleep(forTimeInterval: 0.06)
}
let preferences = Preferences.shared

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let image = MenuBarImage.render(
    snapshot: monitor.snapshot,
    preferences: preferences,
    appearance: NSApp.effectiveAppearance,
    density: .full
)
item.button?.image = image
item.button?.toolTip = MenuBarImage.tooltip(snapshot: monitor.snapshot)

DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
    let frame = item.button?.window?.frame ?? .zero
    let text = """
    布局=\(preferences.menuBarLayout.rawValue)
    图片尺寸=\(Int(image?.size.width ?? 0))x\(Int(image?.size.height ?? 0))
    窗口 frame.x=\(Int(frame.minX))..\(Int(frame.maxX)) 宽\(Int(frame.width))
    """
    try? text.write(to: URL(fileURLWithPath: "/Users/orange/Documents/DeepSeek/SysPulse/build/probe.txt"), atomically: true, encoding: .utf8)
}

if true {
    let view = DashboardView(monitor: monitor, preferences: preferences)
    let hosting = NSHostingView(rootView: view)
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "SysPulse 面板预览"
    window.contentView = hosting
    window.level = .floating
    window.setFrameTopLeftPoint(NSPoint(x: 900, y: 1000))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // 交互自检：把收到的鼠标事件计入标题，用来判断 Tools/Clicker 合成的点击
    // 有没有送进 App。注意：普通窗口收得到，但真实 popover 里的控件经常收不到，
    // 所以控件交互不能只靠合成点击验证（详见 README「开发流程」）。
    var clicks = 0
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
        clicks += 1
        window.title = "SysPulse 面板预览 点击=\(clicks) \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))"
        return event
    }

    // 把四个开关按钮的真实位置写出来：SwiftUI 的布局算不准，
    // 而合成点击必须落在这上面才能验证交互，所以直接从视图树里量。
    func dumpToggleFrames() -> String {
        var lines: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton {
                let rect = button.convert(button.bounds, to: hosting)
                lines.append("NSButton \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
            }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return lines.joined(separator: "\n")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let frameLines = dumpToggleFrames()
        let info = "\(probeVersion)\nwindow visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame)) size=\(Int(size.width))x\(Int(size.height))\n"
            + "contentHeight=\(Int(hosting.frame.height))\n" + frameLines + "\n"
        let url = URL(fileURLWithPath: "/Users/orange/Documents/DeepSeek/SysPulse/build/probe.txt")
        try? info.write(to: url, atomically: true, encoding: .utf8)
    }
}

app.run()
