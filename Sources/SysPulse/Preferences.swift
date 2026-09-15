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
    }

    @Published var showNetwork: Bool { didSet { store(showNetwork, Keys.showNetwork) } }
    @Published var showCPU: Bool { didSet { store(showCPU, Keys.showCPU) } }
    @Published var showMemory: Bool { didSet { store(showMemory, Keys.showMemory) } }
    @Published var showGPU: Bool { didSet { store(showGPU, Keys.showGPU) } }
    @Published var refreshInterval: Double { didSet { store(refreshInterval, Keys.refreshInterval) } }

    /// 菜单栏图标背景的"流光"效果（流动渐变）
    @Published var menuBarGlow: Bool { didSet { store(menuBarGlow, Keys.menuBarGlow) } }


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
            Keys.menuBarGlow: false
        ])
        showNetwork = defaults.bool(forKey: Keys.showNetwork)
        showCPU = defaults.bool(forKey: Keys.showCPU)
        showMemory = defaults.bool(forKey: Keys.showMemory)
        showGPU = defaults.bool(forKey: Keys.showGPU)
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        menuBarGlow = defaults.bool(forKey: Keys.menuBarGlow)
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: Keys.menuBarLayout) ?? "") ?? .auto
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
