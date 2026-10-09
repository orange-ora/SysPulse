import AppKit
import Foundation

// 文字层缓存的受控对比：同一个真实 NSStatusBarButton，同一份采样，只切换
// 「每一拍都赋新图」与「同采样复用缓存、跳过赋值」。两种路径的绘制内容一致，
// 差别只在每拍是否重新光栅化文字、是否重排状态栏。
//
// 注意：`StatusItemController.textImage` 是私有方法，这里复现的是同一判定分支
// （键相同则复用，否则重绘），不是直接调用它。
// 运行时会短暂创建一个状态栏项并立即移除；偏好只从 UserDefaults.standard 读取显示项，不写入，不联网。
//
// 复现（在仓库根目录执行）：
//   swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/modulecache \
//     -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
//     Sources/SysPulse/{Monitors,SystemMonitor,Preferences,LaunchAtLogin,Formatting,MenuBarImage,PanelAnchorAnimation,DashboardView,DeviceInformationCard,PanelPresentationAnimation,StatusItemController}.swift \
//     Tools/TextCacheBench/main.swift -o build/TextCacheBench && ./build/TextCacheBench

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func makeSnapshot() -> MetricsSnapshot {
    var snapshot = MetricsSnapshot()
    snapshot.cpuUsage = 0.223
    snapshot.cpuUser = 0.147
    snapshot.cpuSystem = 0.075
    snapshot.cpuCores = 10
    snapshot.gpuUsage = 59.0
    snapshot.gpuMemory = 1_289_830_400
    snapshot.memoryUsed = 12_884_901_888
    snapshot.memoryTotal = 17_179_869_184
    snapshot.memoryFraction = 0.698
    snapshot.swapUsed = 269_484_032
    snapshot.downSpeed = 1_100_000
    snapshot.upSpeed = 16_000
    snapshot.uptime = 22_800
    snapshot.processCount = 733
    return snapshot
}

let snapshot = makeSnapshot()
let preferences = Preferences()
let appearance = NSApp.effectiveAppearance
let density: MenuBarDensity = .full
let frames = 2400   // ≈ 10 fps 下的 4 分钟动效帧

@inline(never)
func renderText() -> NSImage? {
    MenuBarImage.render(
        snapshot: snapshot,
        preferences: preferences,
        appearance: appearance,
        density: density,
        effect: .diffuse,
        effectElapsed: 1.234,
        includesBackground: false
    )
}

/// 模拟动效定时器的一拍。`caching` 为真时走 textImage() 的缓存判定路径。
func runFrames(caching: Bool) -> Double {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }
    let button = statusItem.button!

    var cachedKey: String?
    var cachedImage: NSImage?
    // 身份在两次数据刷新之间不变；这里用固定值代表「同一份采样」。
    let key = "sample-1"

    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<frames {
        let image: NSImage?
        if caching, key == cachedKey, let hit = cachedImage {
            image = hit
        } else {
            image = renderText()
            cachedKey = key
            cachedImage = image
        }
        // 缓存路径的实际行为：对象相同就不赋值；未缓存路径每拍都是新对象。
        if button.image !== image { button.image = image }
        _ = button.intrinsicContentSize
    }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(frames)
}

_ = renderText()
// 预热两轮，抹掉首次布局与字体缓存的影响，取第三轮。
_ = runFrames(caching: false)
_ = runFrames(caching: true)
let uncached = runFrames(caching: false)
let cached = runFrames(caching: true)

print(String(format: "未缓存（每拍重画+赋值）: %.4f ms/帧", uncached))
print(String(format: "已缓存（同采样复用）:     %.4f ms/帧", cached))
print(String(format: "每帧省下: %.4f ms（%.1f%%）", uncached - cached, (uncached - cached) / uncached * 100))
print(String(format: "%d 帧共省: %.1f ms；等效 10 fps 下每秒 %.3f ms", frames,
             (uncached - cached) * Double(frames), (uncached - cached) * 10))
