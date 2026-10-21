import Foundation

// MARK: - Collector 输出模型

struct QuotaSnapshot: Decodable {
    let schema: Int?
    let updatedAt: String
    let providers: [ProviderStatus]

    var updatedDate: Date? {
        ISO8601DateFormatter.flexible.date(from: updatedAt)
    }
}

struct CheckinReport: Decodable {
    let results: [CheckinResult]
}

struct CheckinResult: Decodable {
    let provider: String
    let status: String
    let message: String
    let points: Double?
    let streak: Int?
}

struct ProviderStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let metrics: [QuotaMetric]
    let headline: String?
    let detail: String?
    let error: String?
    let account: String?
    let plan: String?

    var isUsable: Bool { status == "ok" || status == "warn" }
}

struct QuotaMetric: Decodable, Identifiable {
    let label: String
    let kind: String
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetAt: Double?
    let currency: String?
    let headlineValue: String?
    let detail: String?

    var id: String { "\(label)-\(kind)-\(headlineValue ?? "")-\(usedPercent ?? 0)" }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - 展示辅助

enum QuotaPalette {
    static func color(for status: String) -> String {
        switch status {
        case "ok": return "green"
        case "warn": return "orange"
        case "error": return "red"
        default: return "gray"
        }
    }

    static func severity(remaining: Double) -> Severity {
        if remaining <= 5 { return .critical }
        if remaining <= 30 { return .tight }
        return .healthy
    }

    enum Severity {
        case critical, tight, healthy
    }
}

struct MenuBarItem {
    let providerID: String
    let value: String
    let remaining: Double?
    let severity: QuotaSeverity
    let tooltip: String
}

extension QuotaSnapshot {
    func excluding(_ ids: Set<String>) -> QuotaSnapshot {
        guard !ids.isEmpty else { return self }
        return QuotaSnapshot(
            schema: schema,
            updatedAt: updatedAt,
            providers: providers.filter { !ids.contains($0.id) }
        )
    }

    var usableCount: Int { providers.filter(\.isUsable).count }
    var enabledCount: Int { providers.filter { $0.status != "disabled" }.count }

    func provider(withID id: String) -> ProviderStatus? {
        providers.first(where: { $0.id == id })
    }

    /// 变化签名：百分比看剩余值，余额看金额字符串，纯文本看文案。
    func signature(for provider: ProviderStatus) -> String {
        if let percent = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
            return "p:\(percent)"
        }
        if let credit = provider.metrics.first(where: { $0.kind == "credit" }) {
            return "c:\(credit.headlineValue ?? "")"
        }
        if let text = provider.metrics.first(where: { $0.kind == "text" }) {
            return "t:\(text.headlineValue ?? "")"
        }
        return "s:\(provider.status)"
    }

    /// 最紧张的一家（只考虑有百分比/余额的正常数据）。
    func worstProviderID() -> String? {
        let percent = providers
            .filter(\.isUsable)
            .compactMap { provider -> (String, Double)? in
                guard let value = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent else {
                    return nil
                }
                return (provider.id, value)
            }
            .min(by: { $0.1 < $1.1 })
        if let percent { return percent.0 }
        return providers.first(where: { $0.isUsable && !$0.metrics.isEmpty })?.id
    }

    func menuBarItem(for providerID: String) -> MenuBarItem? {
        guard let provider = provider(withID: providerID) else { return nil }
        let style = ProviderStyles.style(for: provider.id)
        let tooltip = summaryTooltip()

        if let percent = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
            return MenuBarItem(
                providerID: provider.id,
                value: "\(Int(min(99, max(0, percent.rounded()))))",
                remaining: percent,
                severity: QuotaSeverity.from(remaining: percent),
                tooltip: tooltip
            )
        }
        if let credit = provider.metrics.first(where: { $0.kind == "credit" }) {
            let amount = credit.headlineValue ?? "—"
            return MenuBarItem(
                providerID: provider.id,
                value: fullCredit(credit.headlineValue ?? "", currency: credit.currency ?? ""),
                remaining: nil,
                severity: .neutral,
                tooltip: tooltip
            )
        }
        if provider.metrics.contains(where: { $0.kind == "text" }) {
            return MenuBarItem(
                providerID: provider.id,
                value: "—",
                remaining: nil,
                severity: .neutral,
                tooltip: tooltip
            )
        }
        return MenuBarItem(
            providerID: provider.id,
            value: provider.status == "error" ? "!" : "—",
            remaining: nil,
            severity: provider.status == "error" ? .critical : .neutral,
            tooltip: tooltip
        )
    }

    private func fullCredit(_ headline: String, currency: String) -> String {
        let symbol: String
        if currency == "USD" || headline.hasPrefix("$") { symbol = "$" }
        else if headline.hasPrefix("¥") || currency == "CNY" { symbol = "¥" }
        else { symbol = "" }
        let digits = headline.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return symbol.isEmpty ? "—" : symbol }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 100 ? 2 : 0
        formatter.minimumFractionDigits = 0
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        return symbol + text
    }

    private func compactCredit(_ headline: String, currency: String) -> String {
        let symbol: String
        if currency == "USD" || headline.hasPrefix("$") { symbol = "$" }
        else if headline.hasPrefix("¥") || currency == "CNY" { symbol = "¥" }
        else { symbol = "" }
        let digits = headline.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return symbol.isEmpty ? "—" : symbol }
        if value < 1000 {
            return symbol + "\(Int(value))"
        }
        if value < 10000 {
            return symbol + String(format: "%.1fk", value / 1000)
        }
        return symbol + String(format: "%.0fk", value / 1000)
    }

    func summaryTooltip() -> String {
        providers
            .filter { $0.status != "disabled" }
            .map { provider in
                let name = ProviderStyles.style(for: provider.id).shortName
                if let percent = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
                    return "\(name) \(Int(percent.rounded()))%"
                }
                if let credit = provider.metrics.first(where: { $0.kind == "credit" }) {
                    return "\(name) \(credit.headlineValue ?? "--")"
                }
                if let text = provider.metrics.first(where: { $0.kind == "text" })?.headlineValue {
                    return "\(name) \(text)"
                }
                return "\(name) \(provider.status == "error" ? "出错" : "未配置")"
            }
            .joined(separator: " · ")
    }
}
