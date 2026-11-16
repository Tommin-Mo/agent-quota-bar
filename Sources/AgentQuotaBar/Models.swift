import Foundation

// MARK: - Collector 输出模型

struct QuotaSnapshot: Codable {
    let schema: Int?
    let updatedAt: String
    /// 开始采集的时间；比 updatedAt 更接近各家数据的实际读取时间，用于跨进程排序。
    let sampledAt: String?
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

struct ProviderStatus: Codable, Identifiable {
    let id: String
    let name: String
    let status: String
    let metrics: [QuotaMetric]
    let headline: String?
    let detail: String?
    let error: String?
    let account: String?
    let plan: String?
    let consumed: Double?
    let balance: Double?
    let subscriptionUntil: String?
    let subscriptionRenewsAt: String?
    let subscriptionWillRenew: Bool?
    /// OpenCode 等本地可算成本的 provider 附加的成本汇总（可选，旧 collector 不返回）。
    let cost: ProviderCost?

    var isUsable: Bool { status == "ok" || status == "warn" }
}

struct QuotaMetric: Codable, Identifiable {
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

    static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// 宽松解析：带/不带毫秒的 ISO8601、只有日期的 `yyyy-MM-dd`、以及秒/毫秒时间戳字符串。
enum FlexibleDateParser {
    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let date = ISO8601DateFormatter.flexible.date(from: text) { return date }
        if let date = ISO8601DateFormatter.internet.date(from: text) { return date }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: text) { return date }

        // 纯数字：秒级或毫秒级时间戳（OpenCode 使用毫秒）。
        if text.allSatisfy({ $0.isNumber }), let value = Double(text), value > 0 {
            return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
        }
        return nil
    }
}

// MARK: - 成本 / token

/// 一次或一段时间内的 token 用量。缓存读/写单独计数，`total` 包含它们。
///
/// 自定义 `init(from:)`：collector 未来可能省略某些字段，缺字段按 0 处理，
/// 不能让整个快照因为多/少一个 token 键就解析失败。
struct TokenUsage: Codable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var reasoning: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    static let zero = TokenUsage()

    var total: Int { input + output + reasoning + cacheRead + cacheWrite }

    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: input + other.input,
            output: output + other.output,
            reasoning: reasoning + other.reasoning,
            cacheRead: cacheRead + other.cacheRead,
            cacheWrite: cacheWrite + other.cacheWrite
        )
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage { lhs.adding(rhs) }

    private enum CodingKeys: String, CodingKey {
        case input, output, reasoning, cacheRead, cacheWrite
    }

    init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = Self.decodeCount(container, .input)
        output = Self.decodeCount(container, .output)
        reasoning = Self.decodeCount(container, .reasoning)
        cacheRead = Self.decodeCount(container, .cacheRead)
        cacheWrite = Self.decodeCount(container, .cacheWrite)
    }

    /// 容忍 Int / Double / 字符串数字，负数按 0 处理。
    private static func decodeCount(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return max(0, value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return max(0, Int(value))
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Double(text) {
            return max(0, Int(value))
        }
        return 0
    }
}

/// collector 在 provider 上附加的可选成本字段：
/// `cost: { currency, today, last7Days, tokens: { today, last7Days } }`。
/// 旧 collector 不返回该字段；解析为 nil，不能用扁平的 costToday。
struct ProviderCost: Codable, Equatable {
    let currency: String?
    let today: Double?
    let last7Days: Double?
    let tokens: ProviderCostTokens?
}

struct ProviderCostTokens: Codable, Equatable {
    let today: TokenUsage?
    let last7Days: TokenUsage?
}

/// 某个 provider 在 N 天窗口内的成本汇总。
struct CostSummary: Codable, Equatable {
    var cost: Double = 0
    var tokens: TokenUsage = .zero
    var sessions: Int = 0
    var days: Int = 1
    /// 数据源是否可读（例如 OpenCode 本地数据库存在且能查询）。
    var readable: Bool = false
    var databasePath: String?
    var updatedAt: String?
    var error: String?

    var hasData: Bool {
        readable && (cost > 0 || tokens.total > 0 || sessions > 0)
    }
}

/// 单日成本，用于历史/趋势展示。
struct DailyCost: Codable, Equatable, Identifiable {
    let date: String
    var cost: Double
    var tokens: TokenUsage
    var sessions: Int

    var id: String { date }

    init(date: String, cost: Double = 0, tokens: TokenUsage = .zero, sessions: Int = 0) {
        self.date = date
        self.cost = cost
        self.tokens = tokens
        self.sessions = sessions
    }
}

// MARK: - 本地历史

/// 每个 provider 每天的额度/余额快照。HistoryStore 持久化到 `history.json`。
struct UsageHistoryEntry: Codable, Equatable, Identifiable {
    let date: String
    let provider: String
    var usedPercent: Double?
    var remainingPercent: Double?
    var balance: Double?
    var consumed: Double?
    var cost: Double?
    var tokens: TokenUsage?
    var status: String?
    var account: String?
    var plan: String?
    var updatedAt: String?

    var id: String { "\(date)::\(provider)" }

    init(
        date: String,
        provider: String,
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        balance: Double? = nil,
        consumed: Double? = nil,
        cost: Double? = nil,
        tokens: TokenUsage? = nil,
        status: String? = nil,
        account: String? = nil,
        plan: String? = nil,
        updatedAt: String? = nil
    ) {
        self.date = date
        self.provider = provider
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.balance = balance
        self.consumed = consumed
        self.cost = cost
        self.tokens = tokens
        self.status = status
        self.account = account
        self.plan = plan
        self.updatedAt = updatedAt
    }
}

// MARK: - 多账号

/// 一个 provider 下的单个账号。`credentials` 里是 provider 相关的密钥/字段，
/// 例如 opencode 的 `apiKey / cookie / workspaceId`、workbuddy 的 `token / uid`。
///
/// `isLegacy` 表示这是从旧的单账号扁平字段（`providers.<id>.apiKey` 等）临时合成的，
/// 不会写回配置；只有真正写入 `accounts` 数组的账号才是持久账号。
struct ProviderAccount: Codable, Equatable, Identifiable {
    let id: String
    var label: String
    var account: String?
    var credentials: [String: String]
    var createdAt: String?
    var updatedAt: String?
    var lastUsedAt: String?
    var isLegacy: Bool

    init(
        id: String,
        label: String,
        account: String? = nil,
        credentials: [String: String] = [:],
        createdAt: String? = nil,
        updatedAt: String? = nil,
        lastUsedAt: String? = nil,
        isLegacy: Bool = false
    ) {
        self.id = id
        self.label = label
        self.account = account
        self.credentials = credentials
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.isLegacy = isLegacy
    }

    var updatedDate: Date? { FlexibleDateParser.date(from: updatedAt ?? createdAt) }
    var lastUsedDate: Date? { FlexibleDateParser.date(from: lastUsedAt) }
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
            sampledAt: sampledAt,
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
        // Trae / WorkBuddy 的余额会因签到 +100 变化，但 consumed 不会；
        // 用累计消费判断“最近使用”，避免签到把菜单栏抢过去。
        if provider.id == "trae" || provider.id == "workbuddy",
           let consumed = provider.consumed {
            return "u:\(consumed)"
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
