import Combine
import Foundation
import ServiceManagement

/// 开机自启（macOS 13+ 的 SMAppService）。
/// 未签名 / 未放到「应用程序」目录时可能注册失败，这里把错误暴露给界面。
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 返回 nil 表示成功，否则返回错误描述。
    @discardableResult
    func set(_ enabled: Bool) -> String? {
        var failure: String?
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            errorMessage = nil
        } catch {
            failure = error.localizedDescription
            errorMessage = "开机启动设置失败：\(error.localizedDescription)"
        }
        isEnabled = SMAppService.mainApp.status == .enabled
        return failure
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
