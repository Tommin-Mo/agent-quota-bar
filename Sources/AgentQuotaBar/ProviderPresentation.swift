import AppKit

/// UI 只消费这个模型，不再在 popover 里按 provider id 拼文案。
/// 数据仍来自 collector，但「主指标 / 单位 / 类别 / 状态」在这里一次性确定。
enum ProviderConnection {
    case online
    case unconfigured
    case offline
    case disabled

    var title: String {
        switch self {
        case .online: return "已连接"
        case .unconfigured: return "需要配置"
        case .offline: return "连接失败"
        case .disabled: return "已停用"
        }
    }

    var color: NSColor {
        switch self {
        case .online: return QuotaStyle.healthyColor
        case .unconfigured: return .systemOrange
        case .offline: return .systemRed
        case .disabled: return Theme.tertiary
        }
    }
}

enum ProviderUnit {
    case percent
    case currency(String)
    case points
    case none
}

extension ProviderStatus {
    var connection: ProviderConnection {
        switch status {
        case "ok", "warn": return .online
        case "unconfigured": return .unconfigured
        case "error": return .offline
        default: return .disabled
        }
    }

    var category: String {
        if metrics.contains(where: { $0.kind == "percent" }) { return "订阅额度" }
        if balance != nil || metrics.contains(where: { $0.kind == "currency" }) { return "现金余额" }
        if metrics.contains(where: { $0.kind == "credit" }) { return "积分" }
        return "其他"
    }

    var unit: ProviderUnit {
        if metrics.contains(where: { $0.kind == "percent" }) { return .percent }
        if let credit = metrics.first(where: { $0.kind == "credit" }) {
            if let currency = credit.currency, !currency.isEmpty {
                return .currency(currency)
            }
            return .points
        }
        if let currency = metrics.first(where: { $0.kind == "currency" })?.currency {
            return .currency(currency)
        }
        if balance != nil { return .currency("CNY") }
        return .none
    }

    var unitSuffix: String? {
        switch unit {
        case .percent, .currency, .none: return nil
        case .points: return "积分"
        }
    }

    var displayPrimaryValue: String {
        if let percent = metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
            return "\(Int(percent.rounded()))%"
        }
        if let credit = metrics.first(where: { $0.kind == "credit" }), let text = credit.headlineValue {
            if let currency = credit.currency, !currency.isEmpty {
                return text.hasPrefix("¥") || text.hasPrefix("$") ? text : "\(currencySymbol)\(text)"
            }
            return formattedNumber(text)
        }
        if let balance {
            let symbol = currencySymbol
            return "\(symbol)\(String(format: balance >= 100 ? "%.0f" : "%.2f", balance))"
        }
        if let headline, !headline.isEmpty { return headline }
        return ""
    }

    var displaySubtitle: String {
        if let raw = subscriptionUntil,
           let date = ISO8601DateFormatter.flexible.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M/d"
            let renew = subscriptionWillRenew == true ? " · 自动续费" : ""
            return "订阅 · \(formatter.string(from: date)) 到期\(renew)"
        }
        if case .currency = unit { return "API 余额（按量计费）" }
        if case .points = unit { return "" }
        if let detail, !detail.isEmpty { return detail.replacingOccurrences(of: " 订阅额度", with: "") }
        return connection.title
    }

    var displayPlan: String? {
        guard let plan, !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "free": return "免费"
        default: return plan
        }
    }

    /// 额度健康只看剩余/余额阈值；连接状态单独由 connection 表达。
    var health: QuotaSeverity {
        if let remaining = metrics.filter({ $0.kind == "percent" }).compactMap(\.remainingPercent).min() {
            return QuotaSeverity.from(remaining: remaining)
        }
        return .healthy
    }

    private var currencySymbol: String {
        switch (metrics.first(where: { $0.kind == "currency" })?.currency
                ?? metrics.first(where: { $0.kind == "credit" })?.currency ?? "CNY").uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        default: return "¥"
        }
    }

    private func formattedNumber(_ text: String) -> String {
        guard let number = Int(text.replacingOccurrences(of: ",", with: "")) else { return text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: number)) ?? text
    }
}
