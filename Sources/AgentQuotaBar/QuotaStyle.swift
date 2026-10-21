import AppKit

/// 可配置的额度颜色 / 阈值。阈值按剩余百分比解释；积分和余额用绝对阈值。
enum QuotaStyle {
    static var warningPercent: Double = 45
    static var dangerPercent: Double = 20
    static var healthyColor: NSColor = Theme.success
    static var warningColor: NSColor = Theme.warning
    static var dangerColor: NSColor = Theme.danger
    static var creditThresholds: [String: Double] = [:]

    static func apply(_ config: ConfigStore) {
        warningPercent = min(99, max(1, config.double("style.warningPercent", default: 45)))
        dangerPercent = min(warningPercent - 1, max(1, config.double("style.dangerPercent", default: 20)))
        let healthyHex = config.string("style.healthyColor").uppercased()
        if healthyHex.isEmpty || healthyHex == "#0B6B5E" || healthyHex == "#2DD4BF" {
            healthyColor = Theme.success
        } else {
            healthyColor = color(hex: healthyHex, fallback: Theme.success)
        }
        warningColor = color(hex: config.string("style.warningColor"), fallback: Theme.warning)
        dangerColor = color(hex: config.string("style.dangerColor"), fallback: Theme.danger)
        var thresholds: [String: Double] = [:]
        let fallback: [String: Double] = ["trae": 200, "workbuddy": 500, "deepseek": 5]
        for id in ["trae", "workbuddy", "deepseek"] {
            let value = config.double("style.thresholds.\(id)", default: fallback[id] ?? 0)
            if value > 0 { thresholds[id] = value }
        }
        creditThresholds = thresholds
    }

    static func creditColor(for provider: ProviderStatus) -> NSColor? {
        guard let threshold = creditThresholds[provider.id],
              let value = remainingNumber(provider) else { return nil }
        if value <= threshold * 0.5 { return dangerColor }
        if value <= threshold { return warningColor }
        return nil
    }

    static func remainingNumber(_ provider: ProviderStatus) -> Double? {
        let metric = provider.metrics.first(where: { $0.kind == "credit" })
            ?? provider.metrics.first(where: { $0.kind == "text" })
        guard let text = metric?.headlineValue else { return nil }
        let digits = text.filter { $0.isNumber || $0 == "." }
        return Double(digits)
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
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#16A34A" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
