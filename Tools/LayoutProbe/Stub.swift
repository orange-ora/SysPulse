import AppKit

/// 命令行工具链（CommandLineTools）缺少 SwiftUIMacros 插件，**整编 `StatusItemController.swift` 会失败**
/// （它在 `popover.contentViewController?.sizingOptions = ...` 那几行用到了 SwiftUI 的类型推断）。
/// 而 `MenuBarImage` 只需要它一个静态方法 `tint(for:)`，所以这里用同名类型顶掉。
///
/// ⚠️ **不要在同一个编译命令里同时带上它和 `StatusItemController.swift`**（符号重复）。
/// 完整 Xcode 环境请直接用真文件，见 `main.swift` 文件头的两个配方。
final class StatusItemController {
    /// 与 `StatusItemController.tint(for:)` 保持一致：≥80% 橙、≥92% 红
    static func tint(for fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.80: return .labelColor
        case ..<0.92: return .systemOrange
        default: return .systemRed
        }
    }
}
