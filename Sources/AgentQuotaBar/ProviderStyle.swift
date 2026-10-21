import AppKit

/// 每家 provider 的视觉身份：头像字母、品牌色、菜单栏短名。
struct ProviderStyle {
    let letter: String
    let shortName: String
    let color: NSColor
}

enum ProviderStyles {
    static func style(for id: String) -> ProviderStyle {
        switch id {
        case "codex":
            return ProviderStyle(letter: "C", shortName: "Codex",
                                 color: NSColor(calibratedRed: 0.25, green: 0.26, blue: 0.30, alpha: 1))
        case "deepseek":
            return ProviderStyle(letter: "D", shortName: "DeepSeek",
                                 color: NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.95, alpha: 1))
        case "opencode":
            return ProviderStyle(letter: "O", shortName: "OpenCode",
                                 color: NSColor(calibratedRed: 0.93, green: 0.46, blue: 0.16, alpha: 1))
        case "trae":
            return ProviderStyle(letter: "T", shortName: "Trae",
                                 color: NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.90, alpha: 1))
        case "workbuddy":
            return ProviderStyle(letter: "W", shortName: "WorkBuddy",
                                 color: NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.58, alpha: 1))
        default:
            return ProviderStyle(letter: "?", shortName: id, color: Theme.secondary)
        }
    }
}

/// 额度严重程度，统一驱动文字、进度条、菜单栏图标。
enum QuotaSeverity {
    case critical
    case tight
    case healthy
    case neutral

    static func from(remaining: Double?) -> QuotaSeverity {
        guard let remaining else { return .neutral }
        if remaining <= QuotaStyle.dangerPercent { return .critical }
        if remaining <= QuotaStyle.warningPercent { return .tight }
        return .healthy
    }

    var color: NSColor {
        switch self {
        case .critical: return QuotaStyle.dangerColor
        case .tight: return QuotaStyle.warningColor
        case .healthy: return QuotaStyle.healthyColor
        case .neutral: return Theme.secondary
        }
    }
}
