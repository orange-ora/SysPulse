import AppKit
import Combine
import Foundation

/// 菜单栏光效互斥；流光与光晕绘制背景，炫彩只作用于字形。
enum MenuBarEffect: String, CaseIterable {
    /// 无光效：只有指标文字，没有背景动效（零持续重画开销）
    case off
    /// 流光：规则的正弦色带横向流动（2026-09-16 的原始效果）
    case glow
    /// 光晕：多个径向光斑各自独立游走、互相叠加，无固定方向
    case diffuse
    /// 炫彩：原生玻璃上的冷色字面与增强珠光扫动
    case iridescent

    var title: String {
        switch self {
        case .off: return "无光效"
        case .glow: return "流光"
        case .diffuse: return "光晕"
        case .iridescent: return "炫彩"
        }
    }
}

/// 用户偏好设置，直接落盘到 UserDefaults。
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// 当前确认的显示与外观基准；首次启动、恢复和异常回退共用。
    enum DisplayDefaults {
        static let showNetwork = true
        static let showCPU = true
        static let showMemory = true
        static let showGPU = true
        static let refreshInterval = 2.0
        static let menuBarLayout = MenuBarLayout.auto
        static let menuBarEffect = MenuBarEffect.diffuse
        static let panelTransparency = 0.71
    }

    enum Keys {
        static let showNetwork = "showNetwork"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let showGPU = "showGPU"
        static let menuBarLayout = "menuBarLayout"
        static let refreshInterval = "refreshInterval"
        static let menuBarEffect = "menuBarEffect"
        static let panelTransparency = "panelTransparency"
        /// ⚠️ 已废弃：2026-09-30 之前的布尔开关，由 `menuBarEffect` 取代。
        /// 只用于**迁移旧值**，迁移后即删除（见 init）。不要再用它读设置。
        static let legacyMenuBarGlow = "menuBarGlow"
    }

    @Published var showNetwork: Bool { didSet { store(showNetwork, Keys.showNetwork) } }
    @Published var showCPU: Bool { didSet { store(showCPU, Keys.showCPU) } }
    @Published var showMemory: Bool { didSet { store(showMemory, Keys.showMemory) } }
    @Published var showGPU: Bool { didSet { store(showGPU, Keys.showGPU) } }
    @Published var refreshInterval: Double { didSet { store(refreshInterval, Keys.refreshInterval) } }

    /// 面板背景通透度，范围 0...1，默认 0.71；文字与读数不随该设置降低透明度。
    @Published var panelTransparency: Double {
        didSet {
            let normalized = Self.normalizedPanelTransparency(panelTransparency)
            if panelTransparency != normalized { panelTransparency = normalized }
            store(normalized, Keys.panelTransparency)
        }
    }

    /// 菜单栏光效（无光效 / 流光 / 光晕 / 炫彩）；旧 off / glow / diffuse 存值继续兼容。
    @Published var menuBarEffect: MenuBarEffect {
        didSet { store(menuBarEffect.rawValue, Keys.menuBarEffect) }
    }


    @Published var menuBarLayout: MenuBarLayout {
        didSet { store(menuBarLayout.rawValue, Keys.menuBarLayout) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.showNetwork: DisplayDefaults.showNetwork,
            Keys.showCPU: DisplayDefaults.showCPU,
            Keys.showMemory: DisplayDefaults.showMemory,
            Keys.showGPU: DisplayDefaults.showGPU,
            Keys.menuBarLayout: DisplayDefaults.menuBarLayout.rawValue,
            Keys.refreshInterval: DisplayDefaults.refreshInterval,
            Keys.menuBarEffect: DisplayDefaults.menuBarEffect.rawValue,
            Keys.panelTransparency: DisplayDefaults.panelTransparency
        ])
        showNetwork = defaults.bool(forKey: Keys.showNetwork)
        showCPU = defaults.bool(forKey: Keys.showCPU)
        showMemory = defaults.bool(forKey: Keys.showMemory)
        showGPU = defaults.bool(forKey: Keys.showGPU)
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        let storedPanelTransparency = defaults.double(forKey: Keys.panelTransparency)
        panelTransparency = Self.normalizedPanelTransparency(storedPanelTransparency)
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: Keys.menuBarLayout) ?? "") ?? DisplayDefaults.menuBarLayout

        // 迁移旧的 `menuBarGlow`（Bool）→ `menuBarEffect`（枚举）。
        //
        // ⚠️ 不能用 `register(defaults:)` 里的值来判断"用户设过没有"：注册的默认值
        // 不会被 `object(forKey:)` 当作真实存值返回（它只返回真正写过的值）。
        // 所以靠下面两个判断区分三种情况：
        //   · 旧 key 存过 → 按旧值迁移（老用户，别把他的流光弄丢）
        //   · 旧 key 没存过、新 key 存过 → 用新值（已经在新版本上设过）
        //   · 两个都没存过 → 全新用户，使用当前确认的默认光效（光晕）
        //
        // ⚠️⚠️ **`didSet` 在 `init` 里不会触发**，所以这里对 `menuBarEffect` 的赋值
        // **不会**自动落盘。凡是"要持久化的迁移结果"都必须显式调 `store(...)` ——
        // 否则会出现最坏的情况：旧 key 被删掉、新 key 又没写进去，用户的设置
        // 在升级时**静默丢失**（这个 bug 真发生过一次，见 DEVLOG-漫散射-2026-09-30）。
        if let legacyGlow = defaults.object(forKey: Keys.legacyMenuBarGlow) {
            let migrated: MenuBarEffect = (legacyGlow as? Bool ?? false) ? .glow : .off
            menuBarEffect = migrated
            store(migrated.rawValue, Keys.menuBarEffect)   // didSet 不触发，必须显式写
            defaults.removeObject(forKey: Keys.legacyMenuBarGlow)
        } else if defaults.string(forKey: Keys.menuBarEffect) == "breathe" {
            menuBarEffect = .iridescent
            store(MenuBarEffect.iridescent.rawValue, Keys.menuBarEffect)
        } else if let stored = defaults.object(forKey: Keys.menuBarEffect) as? String,
                  let effect = MenuBarEffect(rawValue: stored) {
            menuBarEffect = effect
        } else {
            menuBarEffect = DisplayDefaults.menuBarEffect
        }

        // 初始化不触发 didSet；显式修正异常存值，正常默认值无需落盘。
        if !storedPanelTransparency.isFinite || storedPanelTransparency != panelTransparency {
            store(panelTransparency, Keys.panelTransparency)
        }
    }

    /// 有限值限制到 0...1，已存的有效值保持原样；非有限值回退到默认 0.71。
    static func normalizedPanelTransparency(_ value: Double) -> Double {
        guard value.isFinite else { return DisplayDefaults.panelTransparency }
        return min(max(value, 0), 1.0)
    }

    /// 恢复显示与外观默认值，不改变系统登录项。
    func resetDisplaySettings() {
        showNetwork = DisplayDefaults.showNetwork
        showCPU = DisplayDefaults.showCPU
        showGPU = DisplayDefaults.showGPU
        showMemory = DisplayDefaults.showMemory
        refreshInterval = DisplayDefaults.refreshInterval
        menuBarLayout = DisplayDefaults.menuBarLayout
        menuBarEffect = DisplayDefaults.menuBarEffect
        panelTransparency = DisplayDefaults.panelTransparency
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
