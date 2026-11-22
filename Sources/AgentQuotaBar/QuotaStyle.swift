import AppKit

/// 可配置的额度颜色 / 阈值。阈值按剩余百分比解释；积分和余额用绝对阈值。
enum QuotaStyle {
    static var warningPercent: Double = 45
    static var dangerPercent: Double = 20
    static var healthyColor: NSColor = Theme.quotaHealthy
    static var warningColor: NSColor = Theme.quotaWarning
    static var dangerColor: NSColor = Theme.quotaDanger
    static private(set) var hasCustomColors = false
    static var creditThresholds: [String: Double] = [:]

    static func percent(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func apply(_ config: ConfigStore) {
        warningPercent = percent(min(99, max(2, config.double("style.warningPercent", default: 45))))
        dangerPercent = percent(min(warningPercent - 1, max(1, config.double("style.dangerPercent", default: 20))))
        hasCustomColors = false
        func configuredColor(_ key: String, legacyDefaults: [String], role: NSColor) -> NSColor {
            let hex = config.string("style." + key).uppercased()
            let explicit = config.bool("style.customColors." + key, default: false)
            guard !hex.isEmpty, explicit || !legacyDefaults.contains(hex) else { return role }
            hasCustomColors = true
            return color(hex: hex, fallback: role)
        }
        healthyColor = configuredColor("healthyColor", legacyDefaults: ["#14B8A6", "#0B6B5E", "#2DD4BF"], role: Theme.quotaHealthy)
        warningColor = configuredColor("warningColor", legacyDefaults: ["#F59E0B"], role: Theme.quotaWarning)
        dangerColor = configuredColor("dangerColor", legacyDefaults: ["#DC2626"], role: Theme.quotaDanger)
        var thresholds: [String: Double] = [:]
        let fallback: [String: Double] = ["trae": 200, "workbuddy": 500, "deepseek": 5]
        for id in ["trae", "workbuddy", "deepseek"] {
            let value = config.double("style.thresholds.\(id)", default: fallback[id] ?? 0)
            if value > 0 { thresholds[id] = value }
        }
        creditThresholds = thresholds
    }

    // The original DeepSeek setting was denominated in CNY. A foreign balance
    // still alerts at exhaustion without comparing two different currencies.
    static func threshold(for provider: ProviderStatus) -> Double? {
        if provider.id == "deepseek", provider.creditMetric?.currency?.uppercased() != "CNY" { return nil }
        return creditThresholds[provider.id]
    }

    static func creditColor(for provider: ProviderStatus) -> NSColor? {
        guard let value = remainingNumber(provider) else { return nil }
        if value <= 0 { return dangerColor }
        guard let threshold = threshold(for: provider) else { return nil }
        if value <= threshold * 0.5 { return dangerColor }
        if value <= threshold { return warningColor }
        return nil
    }

    static func remainingNumber(_ provider: ProviderStatus) -> Double? {
        if let balance = provider.balance { return balance }
        if case .number(let number) = provider.creditMetric?.value { return number }
        guard let text = provider.creditMetric?.headlineValue else { return nil }
        let number = text.replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "$¥€£ "))
            .replacingOccurrences(of: ",", with: "")
        return Double(number)
    }

    static func color(hex: String?, fallback: NSColor) -> NSColor {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return fallback }
        return Theme.hex(number)
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#0B6B5E" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
