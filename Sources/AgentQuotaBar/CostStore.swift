import Foundation

/// OpenCode 成本读取与格式化。
///
/// 首选 collector 在 `ProviderStatus.cost` 里返回的嵌套成本（collector 已读本地库）；
/// 旧 collector 或快照里没有该字段时，可以按需回退到直接读取 OpenCode 本地 SQLite。
/// 回退遵守 `providers.opencode.costEnabled`（默认 true），不会绕过关闭开关。
final class CostStore {
    static let shared = CostStore()

    static let defaultDays = 7
    /// 与 collector 的 rolling 7 天不同，本地库回退按自然日统计，便于和历史文件对齐。
    static let openCodeProviderID = "opencode"
    static let cacheLifetime: TimeInterval = 30

    private let lock = NSLock()
    private var cache: [String: CachedSeries] = [:]

    private struct CachedSeries {
        let createdAt: Date
        let days: [DailyCost]
        let readable: Bool
        let databasePath: String?
        let error: String?
    }

    // MARK: - 快照内成本（优先）

    /// collector 返回的嵌套 `cost` 转成 `CostSummary`。
    static func summary(from cost: ProviderCost, days: Int) -> CostSummary {
        let useToday = days <= 1
        let tokens = (useToday ? cost.tokens?.today : cost.tokens?.last7Days) ?? .zero
        let amount = (useToday ? cost.today : cost.last7Days) ?? 0
        return CostSummary(
            cost: max(0, amount),
            tokens: tokens,
            sessions: 0,
            days: days,
            readable: true,
            databasePath: nil,
            updatedAt: ISO8601DateFormatter.internet.string(from: Date()),
            error: nil
        )
    }

    /// 读取某家 provider 的成本。
    ///
    /// - 有 `provider.cost`：直接使用（不访问磁盘）。
    /// - 没有时：只有显式传入 `config` 且 `providers.opencode.costEnabled != false` 才回退读本地库。
    func summary(
        for provider: ProviderStatus?,
        config: ConfigStore? = nil,
        days: Int = CostStore.defaultDays,
        now: Date = Date()
    ) -> CostSummary {
        if let cost = provider?.cost {
            return Self.summary(from: cost, days: days)
        }
        guard provider == nil || provider?.id == Self.openCodeProviderID else {
            return CostSummary(days: max(1, days))
        }
        guard let config,
              config.bool("providers.opencode.costEnabled", default: true) else {
            return CostSummary(days: max(1, days))
        }
        return databaseSummary(days: days, now: now)
    }

    /// 面板一行文案：`今日 $0.12 · 近 7 天 $0.84`；完全无可用数据时返回 nil。
    func summaryText(
        for provider: ProviderStatus?,
        config: ConfigStore? = nil,
        now: Date = Date()
    ) -> String? {
        if let cost = provider?.cost {
            guard cost.today != nil || cost.last7Days != nil || cost.tokens != nil else { return nil }
            let currency = cost.currency ?? Self.currencyFallback
            let today = Self.formatMoney(cost.today ?? 0, currency: currency)
            let week = Self.formatMoney(cost.last7Days ?? cost.today ?? 0, currency: currency)
            return "今日 \(today) · 近 7 天 \(week)"
        }

        if let config,
           !config.bool("providers.opencode.costEnabled", default: true) {
            return nil
        }
        let series = fetch(days: Self.defaultDays, now: now)
        guard series.readable, provider == nil || provider?.id == Self.openCodeProviderID else {
            return nil
        }
        let hasData = series.days.contains { $0.cost > 0 || $0.tokens.total > 0 || $0.sessions > 0 }
        guard hasData else { return nil }
        let todayCost = series.days.last?.cost ?? 0
        let weekCost = series.days.reduce(0) { $0 + $1.cost }
        return "今日 \(Self.formatMoney(todayCost, currency: Self.currencyFallback)) · 近 7 天 \(Self.formatMoney(weekCost, currency: Self.currencyFallback))"
    }

    // MARK: - 本地数据库回退

    /// 直接读 OpenCode 本地库，按自然日返回最近 N 天（从旧到新，缺失日期补 0）。
    func daily(days: Int = CostStore.defaultDays, now: Date = Date()) -> [DailyCost] {
        fetch(days: days, now: now).days
    }

    /// 直接读 OpenCode 本地库的汇总；数据库不可读时 `readable == false`。
    func databaseSummary(days: Int = CostStore.defaultDays, now: Date = Date()) -> CostSummary {
        let series = fetch(days: days, now: now)
        let total = CostSummary(
            cost: series.days.reduce(0) { $0 + $1.cost },
            tokens: series.days.reduce(TokenUsage.zero) { $0 + $1.tokens },
            sessions: series.days.reduce(0) { $0 + $1.sessions },
            days: max(1, days),            readable: series.readable,
            databasePath: series.databasePath,
            updatedAt: ISO8601DateFormatter.internet.string(from: Date()),
            error: series.error
        )
        return total
    }

    func databaseAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: Self.databaseURL.path)
    }

    /// 清空缓存（例如用户刚完成一次 OpenCode 会话）。
    func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - 路径与格式化

    /// `AGENT_QUOTA_OPENCODE_DB` > `XDG_DATA_HOME/opencode/opencode.db` > `~/.local/share/opencode/opencode.db`。
    static var databaseURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["AGENT_QUOTA_OPENCODE_DB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome: URL
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            dataHome = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else {
            dataHome = home.appendingPathComponent(".local/share", isDirectory: true)
        }
        return dataHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
    }

    static let currencyFallback = "USD"

    /// `$0.12` / `¥1.20` / `USD 0.12`；小于 1 分显示 `<$0.01`。
    static func formatMoney(_ value: Double, currency: String? = CostStore.currencyFallback) -> String {
        let amount = max(0, value)
        let symbol: String
        switch (currency ?? currencyFallback).uppercased() {
        case "USD", "$": symbol = "$"
        case "CNY", "RMB", "¥": symbol = "¥"
        case "EUR", "€": symbol = "€"
        default: symbol = "\((currency ?? currencyFallback).uppercased()) "
        }
        if amount > 0 && amount < 0.01 {
            return "<\(symbol)0.01"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        return symbol + text
    }

    // MARK: - 本地库查询

    private func fetch(days: Int, now: Date) -> CachedSeries {
        let clampedDays = max(1, days)
        let key = "\(Self.dayKey(now))-\(clampedDays)"
        lock.lock()
        if let cached = cache[key], now.timeIntervalSince(cached.createdAt) < Self.cacheLifetime {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = Self.query(days: clampedDays, now: now)
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    private static func query(days: Int, now: Date) -> CachedSeries {
        let database = Self.databaseURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: database.path),
              fileManager.isReadableFile(atPath: database.path) else {
            return CachedSeries(
                createdAt: now,
                days: emptyDays(days: days, now: now),
                readable: false,
                databasePath: database.path,
                error: "未找到 OpenCode 数据库"
            )
        }

        let tables = tableNames(at: database)
        guard !tables.isEmpty else {
            return CachedSeries(
                createdAt: now,
                days: emptyDays(days: days, now: now),
                readable: false,
                databasePath: database.path,
                error: "OpenCode 数据库不可读"
            )
        }

        let millisecondsPerUnit = millisecondsPerDatabaseUnit(at: database, tables: tables)
        let calendar = Calendar.current
        let end = now
        let start = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        let startMilliseconds = Int64(start.timeIntervalSince1970 * 1000)
        let endMilliseconds = Int64((end.timeIntervalSince1970 + 1) * 1000)
        // 数据库可能用毫秒或秒；cutoff 必须换算成数据库单位，日期换算用每秒的数据库单位数。
        let startValue = startMilliseconds / Int64(millisecondsPerUnit)
        let endValue = endMilliseconds / Int64(millisecondsPerUnit)
        let secondsDivisor = max(1, 1000 / millisecondsPerUnit)

        var rows: [DailyCost] = []
        var error: String?

        if tables.contains("session_message") {
            if let messageRows = messageDaily(
                at: database,
                start: startValue,
                end: endValue,
                secondsDivisor: secondsDivisor
            ) {
                rows = messageRows
            } else {
                error = "读取 session_message 失败"
            }
        }

        let messageHasData = rows.contains { $0.cost > 0 || $0.tokens.total > 0 || $0.sessions > 0 }
        if !messageHasData {
            let sessionTable = tables.contains("session_v2") ? "session_v2" : (tables.contains("session") ? "session" : nil)
            if let sessionTable,
               let sessionRows = sessionDaily(
                   at: database,
                   table: sessionTable,
                   start: startValue,
                   end: endValue,
                   secondsDivisor: secondsDivisor
               ) {
                if sessionRows.contains(where: { $0.cost > 0 || $0.tokens.total > 0 || $0.sessions > 0 }) {
                    rows = sessionRows
                    error = nil
                }
            }
        }

        let filled = fillMissingDays(rows, days: days, now: now)
        return CachedSeries(
            createdAt: now,
            days: filled,
            readable: true,
            databasePath: database.path,
            error: error
        )
    }

    private static func emptyDays(days: Int, now: Date) -> [DailyCost] {
        dateKeys(days: days, now: now).map { DailyCost(date: $0) }
    }

    /// 以本地自然日补齐 N 天（从旧到新）。
    private static func fillMissingDays(_ rows: [DailyCost], days: Int, now: Date) -> [DailyCost] {
        let byDate = Dictionary(rows.map { ($0.date, $0) }, uniquingKeysWith: { first, second in
            DailyCost(
                date: first.date,
                cost: first.cost + second.cost,
                tokens: first.tokens + second.tokens,
                sessions: first.sessions + second.sessions
            )
        })
        return dateKeys(days: days, now: now).map { byDate[$0] ?? DailyCost(date: $0) }
    }

    private static func dateKeys(days: Int, now: Date) -> [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dayKey(date)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func tableNames(at database: URL) -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('session_message','session_v2','session');"
        guard let rows = runSQL(sql, database: database) else { return [] }
        var names = Set<String>()
        for row in rows {
            if let name = row["name"] as? String { names.insert(name) }
        }
        return names
    }

    /// 数据库时间戳每个单位代表多少毫秒：当前 OpenCode 是毫秒（1），旧库可能是秒（1000）。
    /// 与 collector 的探测逻辑一致。
    private static func millisecondsPerDatabaseUnit(at database: URL, tables: Set<String>) -> Int {
        var parts: [String] = []
        if tables.contains("session_v2") {
            parts.append("SELECT MAX(time_created) AS t FROM session_v2")
        }
        if tables.contains("session_message") {
            parts.append("SELECT MAX(time_created) AS t FROM session_message")
        }
        guard !parts.isEmpty else { return 1000 }
        let sql = "SELECT MAX(t) AS max_time FROM (\(parts.joined(separator: " UNION ALL ")));"
        guard let rows = runSQL(sql, database: database),
              let raw = rows.first?["max_time"],
              let maxTime = numberValue(raw), maxTime > 0 else {
            return 1
        }
        return maxTime < 1e11 ? 1000 : 1
    }

    private static func messageDaily(
        at database: URL,
        start: Int64,
        end: Int64,
        secondsDivisor: Int
    ) -> [DailyCost]? {
        let sql = """
        SELECT
          date(time_created / \(max(1, secondsDivisor)), 'unixepoch', 'localtime') AS day,
          COALESCE(SUM(CAST(json_extract(data, '$.cost') AS REAL)), 0) AS cost,
          COALESCE(SUM(CAST(json_extract(data, '$.tokens.input') AS INTEGER)), 0) AS input_tokens,
          COALESCE(SUM(CAST(json_extract(data, '$.tokens.output') AS INTEGER)), 0) AS output_tokens,
          COALESCE(SUM(CAST(json_extract(data, '$.tokens.reasoning') AS INTEGER)), 0) AS reasoning_tokens,
          COALESCE(SUM(CAST(COALESCE(json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cacheRead')) AS INTEGER)), 0) AS cache_read_tokens,
          COALESCE(SUM(CAST(COALESCE(json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.tokens.cacheWrite')) AS INTEGER)), 0) AS cache_write_tokens,
          COUNT(DISTINCT session_id) AS sessions
        FROM session_message
        WHERE type = 'assistant'
          AND time_created >= \(start) AND time_created < \(end)
          AND json_valid(data)
        GROUP BY day
        ORDER BY day;
        """
        guard let rows = runSQL(sql, database: database) else { return nil }
        return rows.compactMap(dailyCost(from:))
    }

    private static func sessionDaily(
        at database: URL,
        table: String,
        start: Int64,
        end: Int64,
        secondsDivisor: Int
    ) -> [DailyCost]? {
        // 表名只来自内部常量，不拼接外部输入。
        let sql = """
        SELECT
          date(time_created / \(max(1, secondsDivisor)), 'unixepoch', 'localtime') AS day,
          COALESCE(SUM(cost), 0) AS cost,
          COALESCE(SUM(tokens_input), 0) AS input_tokens,
          COALESCE(SUM(tokens_output), 0) AS output_tokens,
          COALESCE(SUM(tokens_reasoning), 0) AS reasoning_tokens,
          COALESCE(SUM(tokens_cache_read), 0) AS cache_read_tokens,
          COALESCE(SUM(tokens_cache_write), 0) AS cache_write_tokens,
          COUNT(*) AS sessions
        FROM \(table)
        WHERE time_created >= \(start) AND time_created < \(end)
        GROUP BY day
        ORDER BY day;
        """
        guard let rows = runSQL(sql, database: database) else { return nil }
        return rows.compactMap(dailyCost(from:))
    }

    private static func dailyCost(from row: [String: Any]) -> DailyCost? {
        guard let day = row["day"] as? String, !day.isEmpty else { return nil }
        let tokens = TokenUsage(
            input: intValue(row["input_tokens"]),
            output: intValue(row["output_tokens"]),
            reasoning: intValue(row["reasoning_tokens"]),
            cacheRead: intValue(row["cache_read_tokens"]),
            cacheWrite: intValue(row["cache_write_tokens"])
        )
        return DailyCost(
            date: day,
            cost: max(0, numberValue(row["cost"]) ?? 0),
            tokens: tokens,
            sessions: intValue(row["sessions"])
        )
    }

    // MARK: - sqlite3 子进程

    /// 用 `/usr/bin/sqlite3` 只读查询；返回 nil 表示数据库不可读或 SQL 失败。
    private static func runSQL(_ sql: String, database: URL) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-json",
            "-cmd", ".timeout 2000",
            database.path, sql,
        ]
        var environment = ProcessInfo.processInfo.environment
        // 让 SQLite 的 localtime 分组和 App 的 Calendar 使用同一时区。
        environment["TZ"] = TimeZone.current.identifier
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            log("cost sqlite launch failed: \(error.localizedDescription)")
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { log("cost sqlite error: \(stderr.prefix(300))") }
            return nil
        }
        if outData.isEmpty { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: outData) else {
            log("cost sqlite decode failed")
            return nil
        }
        if let array = object as? [[String: Any]] { return array }
        if let single = object as? [String: Any] { return [single] }
        return []
    }

    private static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        Int(max(0, numberValue(value) ?? 0))
    }
}
