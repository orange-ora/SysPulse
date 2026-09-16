import AppKit
import Combine
import Foundation

/// 用户偏好设置，直接落盘到 UserDefaults。
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Keys {
        static let showNetwork = "showNetwork"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let showGPU = "showGPU"
        static let menuBarLayout = "menuBarLayout"
        static let refreshInterval = "refreshInterval"
        static let menuBarGlow = "menuBarGlow"
        static let panelAnimates = "panelAnimates"
    }

    @Published var showNetwork: Bool { didSet { store(showNetwork, Keys.showNetwork) } }
    @Published var showCPU: Bool { didSet { store(showCPU, Keys.showCPU) } }
    @Published var showMemory: Bool { didSet { store(showMemory, Keys.showMemory) } }
    @Published var showGPU: Bool { didSet { store(showGPU, Keys.showGPU) } }
    @Published var refreshInterval: Double { didSet { store(refreshInterval, Keys.refreshInterval) } }

    /// 菜单栏图标背景的"流光"效果（流动渐变）
    @Published var menuBarGlow: Bool { didSet { store(menuBarGlow, Keys.menuBarGlow) } }

    /// 面板开合是否走系统动画（2026-09-17 加）。
    ///
    /// 开着：整个面板（框 + 箭头 + 内容）淡入/放大，观感完整，但系统动画**固定约 600ms**
    /// （`NSAnimationContext` 改不动，实测过），而且开合期间状态栏项会先后被系统画两次
    /// "高亮底"（按下时一次、面板打开后一次），有人会觉得那圈白色边框"闪两下"。
    /// 关掉：开合瞬时（约 110ms）、跟手，两次高亮紧挨着、看起来只亮一下。
    /// 连点（间隔 <0.45s）无论这个开关如何都是瞬时。
    @Published var panelAnimates: Bool { didSet { store(panelAnimates, Keys.panelAnimates) } }


    @Published var menuBarLayout: MenuBarLayout {
        didSet { store(menuBarLayout.rawValue, Keys.menuBarLayout) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.showNetwork: true,
            Keys.showCPU: true,
            Keys.showMemory: true,
            Keys.showGPU: true,
            Keys.menuBarLayout: MenuBarLayout.auto.rawValue,
            Keys.refreshInterval: 1.0,
            Keys.menuBarGlow: false,
            Keys.panelAnimates: true
        ])
        showNetwork = defaults.bool(forKey: Keys.showNetwork)
        showCPU = defaults.bool(forKey: Keys.showCPU)
        showMemory = defaults.bool(forKey: Keys.showMemory)
        showGPU = defaults.bool(forKey: Keys.showGPU)
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        menuBarGlow = defaults.bool(forKey: Keys.menuBarGlow)
        panelAnimates = defaults.object(forKey: Keys.panelAnimates) as? Bool ?? true
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: Keys.menuBarLayout) ?? "") ?? .auto
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
