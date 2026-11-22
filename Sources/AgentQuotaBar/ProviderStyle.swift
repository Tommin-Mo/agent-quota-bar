import AppKit

/// 每家 provider 的视觉身份：头像字母、菜单栏短名。
struct ProviderStyle {
    let letter: String
    let shortName: String
}

enum ProviderStyles {
    static func style(for id: String) -> ProviderStyle {
        let name = ProviderRegistry.provider(withID: id)?.shortName ?? id
        return ProviderStyle(letter: String(name.prefix(1)).uppercased(), shortName: name)
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
