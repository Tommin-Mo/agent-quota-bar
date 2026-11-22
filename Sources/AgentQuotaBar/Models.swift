import Foundation

// MARK: - Collector 输出模型

struct QuotaSnapshot: Codable {
    let schema: Int?
    let updatedAt: String
    /// 开始采集的时间；比 updatedAt 更接近各家数据的实际读取时间，用于跨进程排序。
    let sampledAt: String?
    let providers: [ProviderStatus]

    func currentAccounts(in providersConfig: [String: Any]) -> QuotaSnapshot {
        let rows = providers.filter { row in
            let config = providersConfig[row.id] as? [String: Any] ?? [:]
            let identity = ["activeAccount", "quotaRevision"].compactMap { config[$0] as? String }
                .filter { !$0.isEmpty }.joined(separator: ":")
            return (row.localAccountID ?? "") == identity &&
                (row.selectionRevision ?? "") == (config["selectionRevision"] as? String ?? "")
        }
        return QuotaSnapshot(schema: schema, updatedAt: updatedAt, sampledAt: sampledAt, providers: rows)
    }

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
    let serviceStatus: String?
    let serviceStatusDescription: String?

    var sampledAt: String? = nil
    var cached: Bool? = nil
    var localAccountID: String? = nil
    var selectionRevision: String? = nil
    var identity: String { [localAccountID ?? "", account ?? "", creditMetric?.currency ?? ""].joined(separator: "|") }
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
    enum Value: Codable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            if let number = try? scalar.decode(Double.self) { self = .number(number) }
            else { self = .text(try scalar.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var scalar = encoder.singleValueContainer()
            switch self {
            case .number(let value): try scalar.encode(value)
            case .text(let value): try scalar.encode(value)
            }
        }
    }
    var value: Value? = nil
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
    var identity: String?
    var dailyDelta: Double?
    var dailyTotals: [String: Double]?
    var deltaUnit: String?
    var costCurrency: String?
    var activeIntervals: Int?
    var windows: [String: Double]?

    struct WalletSample: Codable, Equatable {
        var balance: Double?
        var consumed: Double?
    }
    var walletSamples: [String: WalletSample]?
    var openingBalances: [String: Double]?
    var balanceUnit: String?
    var referenceWindow: String?
    var windowEnds: [String: Double]?

    var recordedDailyTotals: [String: Double] {
        if let dailyTotals, !dailyTotals.isEmpty { return dailyTotals }
        if let dailyDelta, let deltaUnit { return [deltaUnit: dailyDelta] }
        return [:]
    }

    var consumptionPercent: Double? {
        let totals = recordedDailyTotals
        if let unit = balanceUnit {
            guard let amount = totals[unit], let openings = openingBalances,
                  !openings.isEmpty, openings.values.allSatisfy({ $0 > 0 }) else { return nil }
            return amount / openings.values.reduce(0, +) * 100
        }
        guard balance == nil else { return nil }
        let periods = totals.keys.filter { $0.hasPrefix("周期：") && !$0.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted()
        let unit = referenceWindow.map { "周期：" + $0 } ?? (periods.contains("周期：本周") ? "周期：本周" : periods.first)
        guard let unit, periods.contains(unit) else { return nil }
        return totals[unit]
    }

    static func averageConsumption(_ records: [Self]) -> Double? {
        let values = records.compactMap(\.consumptionPercent)
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return (mean * 1_000_000_000).rounded() / 1_000_000_000
    }

    var hasQuotaSpend: Bool {
        (dailyTotals ?? [:]).values.contains { $0 > 0 } || (dailyDelta ?? 0) > 0 || (cost ?? 0) > 0
    }

    var hasObservation: Bool { dailyTotals?.isEmpty == false || dailyDelta != nil || cost != nil || tokens != nil }
    var observedZero: Bool {
        (dailyTotals?.isEmpty == false || dailyDelta != nil) && activity == 0 && (dailyTotals ?? [:]).values.allSatisfy { $0 == 0 } && (dailyDelta ?? 0) == 0 && (cost ?? 0) == 0 && (tokens?.total ?? 0) == 0
    }
    var activity: Int {
        max(activeIntervals ?? 0, (cost ?? 0) > 0 || (tokens?.total ?? 0) > 0 || (dailyDelta ?? 0) > 0 ? 1 : 0)
    }

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
        mostUrgent.first?.id
    }

    var mostUrgent: [ProviderStatus] {
        let eligible = providers.filter { $0.isUsable && $0.cached != true && $0.riskMetric != nil }
        guard let first = eligible.min(by: { ($0.riskTier, $0.riskScore) < ($1.riskTier, $1.riskScore) }) else { return [] }
        return eligible.filter { $0.riskTier == first.riskTier && $0.riskScore == first.riskScore }.sorted { $0.id < $1.id }
    }

    var riskSummary: String {
        let urgent = mostUrgent
        guard let first = urgent.first else { return "" }
        if first.riskTier == 3 { return "当前可判断的服务均未触发警戒" }
        if urgent.count == 1 { return "\(first.name) · \(first.riskDescription)" }
        return first.riskTier == 0 ? "\(urgent.count) 家已耗尽" : "\(urgent.count) 家并列紧张"
    }

    func menuBarItem(for providerID: String) -> MenuBarItem? {
        guard let provider = provider(withID: providerID) else { return nil }
        let metric = provider.riskMetric
        let value = metric?.remainingPercent.map(quotaPercentText)
            ?? metric.map(provider.valueText) ?? ""
        return MenuBarItem(providerID: provider.id, value: value, remaining: metric?.remainingPercent,
                           severity: provider.cached == true ? .neutral : provider.health, tooltip: summaryTooltip())
    }

    func summaryTooltip() -> String {
        providers.filter { $0.status != "disabled" }.map { provider in
            "\(provider.name) · \(provider.riskDescription)" + (provider.cached == true ? "（缓存）" : "")
        }.joined(separator: " · ")
    }
}
