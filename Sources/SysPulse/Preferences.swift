import AppKit
import Combine
import Foundation

/// 菜单栏背景的动效。**一次只开一种**，所以做成单值而不是多个独立开关 ——
/// 两个动效叠在一起会互相干扰、观感更乱，而且没有实际意义。
enum MenuBarEffect: String, CaseIterable {
    /// 关闭：只有指标文字，没有背景动效（零持续重画开销）
    case off
    /// 流光：规则的正弦色带横向流动（2026-09-16 的原始效果）
    case glow
    /// 漫散射：多个径向光斑各自独立游走、互相叠加，无固定方向
    case diffuse

    var title: String {
        switch self {
        case .off: return "关闭"
        case .glow: return "流光"
        case .diffuse: return "漫散射"
        }
    }
}

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
        static let menuBarEffect = "menuBarEffect"
        /// ⚠️ 已废弃：2026-09-30 之前的布尔开关，由 `menuBarEffect` 取代。
        /// 只用于**迁移旧值**，迁移后即删除（见 init）。不要再用它读设置。
        static let legacyMenuBarGlow = "menuBarGlow"
    }

    @Published var showNetwork: Bool { didSet { store(showNetwork, Keys.showNetwork) } }
    @Published var showCPU: Bool { didSet { store(showCPU, Keys.showCPU) } }
    @Published var showMemory: Bool { didSet { store(showMemory, Keys.showMemory) } }
    @Published var showGPU: Bool { didSet { store(showGPU, Keys.showGPU) } }
    @Published var refreshInterval: Double { didSet { store(refreshInterval, Keys.refreshInterval) } }

    /// 菜单栏背景动效（关闭 / 流光 / 漫散射）
    @Published var menuBarEffect: MenuBarEffect {
        didSet { store(menuBarEffect.rawValue, Keys.menuBarEffect) }
    }


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
            Keys.menuBarEffect: MenuBarEffect.off.rawValue
        ])
        showNetwork = defaults.bool(forKey: Keys.showNetwork)
        showCPU = defaults.bool(forKey: Keys.showCPU)
        showMemory = defaults.bool(forKey: Keys.showMemory)
        showGPU = defaults.bool(forKey: Keys.showGPU)
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: Keys.menuBarLayout) ?? "") ?? .auto

        // 迁移旧的 `menuBarGlow`（Bool）→ `menuBarEffect`（枚举）。
        //
        // ⚠️ 不能用 `register(defaults:)` 里的值来判断"用户设过没有"：注册的默认值
        // 不会被 `object(forKey:)` 当作真实存值返回（它只返回真正写过的值）。
        // 所以靠下面两个判断区分三种情况：
        //   · 旧 key 存过 → 按旧值迁移（老用户，别把他的流光弄丢）
        //   · 旧 key 没存过、新 key 存过 → 用新值（已经在新版本上设过）
        //   · 两个都没存过 → 全新用户，默认关闭（与旧版本默认一致）
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
        } else if let stored = defaults.object(forKey: Keys.menuBarEffect) as? String,
                  let effect = MenuBarEffect(rawValue: stored) {
            menuBarEffect = effect
        } else {
            menuBarEffect = .off
        }
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
