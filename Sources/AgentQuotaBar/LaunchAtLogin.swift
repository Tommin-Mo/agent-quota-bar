import Foundation
import ServiceManagement

/// 开机自启动：优先用 SMAppService（macOS 13+，出现在“登录项”里）。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启 · 登录后自动启动"
        case .requiresApproval:
            return "已登记 · 请在 系统设置 → 登录项 中允许"
        case .notRegistered:
            return "已关闭"
        case .notFound:
            return "请把 App 放到「应用程序」后再开启"
        @unknown default:
            return "未知状态"
        }
    }

    /// 返回错误信息；nil 表示成功。
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
