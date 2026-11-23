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
        case .unconfigured: return Theme.warning
        case .offline: return Theme.danger
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

func quotaPercentText(_ value: Double) -> String {
    if value > 0 && value < 0.5 { return "<1" }
    if value >= 99.5 && value < 100 { return ">99" }
    return String(Int(value.rounded()))
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

    var creditMetric: QuotaMetric? { metrics.first { $0.kind == "credit" } }
    var lowestWindow: QuotaMetric? {
        metrics.filter { $0.kind == "percent" && $0.remainingPercent != nil }
            .min { ($0.remainingPercent!, $0.label) < ($1.remainingPercent!, $1.label) }
    }

    var primaryMetric: QuotaMetric? {
        if id == "trae", let creditMetric { return creditMetric }
        if id == "codex", let week = metrics.first(where: { $0.label == "本周" && $0.remainingPercent != nil }) { return week }
        return lowestWindow ?? creditMetric
    }

    // 不比较不同单位的裸数值。按剩余与各自警戒线的比值排序，耗尽排首位。
    private func score(_ metric: QuotaMetric) -> Double {
        if let p = metric.remainingPercent { return max(0, p) / max(1, QuotaStyle.warningPercent) }
        guard let v = QuotaStyle.remainingNumber(self) else { return .infinity }
        if v <= 0 { return 0 }
        guard let t = QuotaStyle.threshold(for: self), t > 0 else { return .greatestFiniteMagnitude }
        return v / t
    }

    private func urgency(_ metric: QuotaMetric) -> Int {
        if score(metric) == 0 { return 0 }
        if let p = metric.remainingPercent { return p <= QuotaStyle.dangerPercent ? 1 : p <= QuotaStyle.warningPercent ? 2 : 3 }
        return score(metric) <= 0.5 ? 1 : score(metric) <= 1 ? 2 : 3
    }

    var riskTier: Int { riskMetric.map(urgency) ?? 4 }

    var riskMetric: QuotaMetric? {
        [lowestWindow, creditMetric].compactMap { $0 }.filter { score($0).isFinite }.min { (urgency($0), score($0)) < (urgency($1), score($1)) }
    }
    var riskScore: Double { riskMetric.map(score) ?? .infinity }
    func valueText(_ metric: QuotaMetric) -> String {
        if let p = metric.remainingPercent { return "\(quotaPercentText(p))%" }
        guard let raw = metric.headlineValue else { return "" }
        guard let currency = metric.currency, !currency.isEmpty else { return formattedNumber(raw) }
        if Double(raw) != nil { return currencySymbol + raw }
        return raw
    }

    var riskDescription: String {
        guard let m = riskMetric else { return isUsable ? "额度未知" : connection.title }
        if let p = m.remainingPercent { return "\(m.label)剩 \(quotaPercentText(p))%" }
        return "\(m.label) \(valueText(m))"
    }

    var pointUnit: String { id == "doubao" ? "额度" : "积分" }

    var category: String {
        switch unit {
        case .percent: return "订阅额度"
        case .points: return pointUnit
        case .currency: return "现金余额"
        case .none: return "其他"
        }
    }

    var unit: ProviderUnit {
        guard let m = primaryMetric else { return .none }
        if m.kind == "percent" { return .percent }
        if let c = m.currency, !c.isEmpty { return .currency(c) }
        return .points
    }

    var unitSuffix: String? {
        switch unit {
        case .percent, .currency, .none: return nil
        case .points: return pointUnit
        }
    }

    var hasExpandableWindows: Bool {
        (["opencode", "codex"].contains(id) || !ProviderRegistry.builtins.contains { $0.id == id }) && metrics.filter { $0.kind == "percent" && $0.remainingPercent != nil }.count > 1
    }

    var displayPrimaryValue: String {
        if let primaryMetric { return valueText(primaryMetric) }
        if isUsable { return "额度未知" }
        return ""
    }

    var displaySubtitle: String {
        cacheDescription ?? quotaSubtitle
    }

    var cacheDescription: String? {
        guard cached == true else { return nil }
        let time = FlexibleDateParser.date(from: sampledAt).map {
            DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
        }
        return "缓存 · " + (time ?? "上次成功读取")
    }

    var quotaSubtitle: String {
        if let raw = subscriptionUntil,
           let date = ISO8601DateFormatter.flexible.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M/d"
            // 面板行宽有限，显示完整日期即可；自动续费保留在 tooltip/详情里，
            // 避免出现 "订阅 · 12/23 到期 · 自..." 这种被截断的文案。
            return "订阅 · \(formatter.string(from: date)) 到期"
        }
        if case .currency = unit { return "API 余额（按量计费）" }
        if id == "doubao", let detail, !detail.isEmpty { return detail }
        if case .points = unit { return "" }
        if let detail, !detail.isEmpty { return detail.replacingOccurrences(of: " 订阅额度", with: "") }
        return connection.title
    }

    var displayPlan: String? {
        guard let plan, !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "免费"
        default: return plan
        }
    }

    /// 额度健康只看剩余/余额阈值；连接状态单独由 connection 表达。
    var health: QuotaSeverity {
        guard let metric = riskMetric else { return .neutral }
        if let p = metric.remainingPercent { return QuotaSeverity.from(remaining: p) }
        if riskScore <= 0.5 { return .critical }
        return riskScore <= 1 ? .tight : .healthy
    }

    var currencySymbol: String {
        switch (metrics.first(where: { $0.kind == "currency" })?.currency
                ?? metrics.first(where: { $0.kind == "credit" })?.currency ?? "CNY").uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        case "CNY": return "¥"
        default: return (creditMetric?.currency ?? "") + " "
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
