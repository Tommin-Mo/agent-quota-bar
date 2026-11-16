import Foundation

/// 本地额度/成本历史：每个 provider 每天一条快照，保留最近 7 天。
///
/// 文件：`<配置目录>/history.json`（与 config.json / usage.json 同目录，0600）。
/// 与 `scripts/quota` 的 `history/YYYY-MM-DD.json`（CLI 自己的成本记录）分开存放，互不覆盖。
/// 读取时从磁盘加载；写入用分布式锁 + 原子替换，损坏文件先备份再重建。
final class HistoryStore {
    static let shared = HistoryStore()

    static let retentionDays = 7
    static let fileName = "history.json"

    private struct Persisted: Codable {
        var schema: Int?
        var entries: [UsageHistoryEntry]
    }

    let fileURL: URL
    private let lock: NSDistributedLock?

    init(configURL: URL = ConfigStore.defaultURL) {
        fileURL = configURL.deletingLastPathComponent().appendingPathComponent(Self.fileName)
        lock = NSDistributedLock(path: fileURL.path + ".lock")
    }

    // MARK: - 记录

    /// 把一次刷新结果写入当天历史。成本优先用 `costs` 参数，其次用 collector 返回的
    /// `provider.cost.today`；两者都没有时保留当天已有成本。
    @discardableResult
    func record(
        snapshot: QuotaSnapshot,
        costs: [String: CostSummary] = [:],
        only: Set<String>? = nil,
        now: Date = Date()
    ) -> Bool {
        guard acquireLock() else { return false }
        defer { lock?.unlock() }

        let calendar = Calendar.current
        let today = Self.dayKey(now, calendar: calendar)
        let keep = Set(Self.dateKeys(days: Self.retentionDays, now: now, calendar: calendar))
        var entries = load().filter { keep.contains($0.date) }

        for provider in snapshot.providers where provider.status != "disabled" && (only == nil || only!.contains(provider.id)) {
            var entry = entries.first { $0.date == today && $0.provider == provider.id }
                ?? UsageHistoryEntry(date: today, provider: provider.id)

            if let metric = provider.metrics.first(where: { $0.kind == "percent" }) {
                if let used = metric.usedPercent { entry.usedPercent = used }
                if let remaining = metric.remainingPercent { entry.remainingPercent = remaining }
            }
            if let balance = provider.balance { entry.balance = balance }
            if let consumed = provider.consumed { entry.consumed = consumed }
            entry.status = provider.status
            entry.account = provider.account
            entry.plan = provider.plan
            entry.updatedAt = snapshot.updatedAt

            if let explicit = costs[provider.id] {
                entry.cost = explicit.cost
                entry.tokens = explicit.tokens
            } else if let cost = provider.cost {
                if let todayCost = cost.today {
                    entry.cost = max(0, todayCost)
                }
                if let tokens = cost.tokens?.today {
                    entry.tokens = tokens
                }
            }
            upsert(&entries, entry)
        }

        // 快照里没有、但显式传入成本的 provider（例如关闭了采集但仍在统计成本）。
        for (providerID, cost) in costs where snapshot.provider(withID: providerID) == nil {
            var entry = entries.first { $0.date == today && $0.provider == providerID }
                ?? UsageHistoryEntry(date: today, provider: providerID)
            entry.cost = cost.cost
            entry.tokens = cost.tokens
            upsert(&entries, entry)
        }

        return save(entries)
    }

    /// 只更新成本（例如拿到 OpenCode 的 today/last7Days 但没有新快照）。
    @discardableResult
    func recordCosts(_ costs: [String: CostSummary], now: Date = Date()) -> Bool {
        guard !costs.isEmpty else { return true }
        guard acquireLock() else { return false }
        defer { lock?.unlock() }

        let calendar = Calendar.current
        let today = Self.dayKey(now, calendar: calendar)
        let keep = Set(Self.dateKeys(days: Self.retentionDays, now: now, calendar: calendar))
        var entries = load().filter { keep.contains($0.date) }
        for (providerID, cost) in costs {
            var entry = entries.first { $0.date == today && $0.provider == providerID }
                ?? UsageHistoryEntry(date: today, provider: providerID)
            entry.cost = cost.cost
            entry.tokens = cost.tokens
            upsert(&entries, entry)
        }
        return save(entries)
    }

    // MARK: - 查询

    /// 最近 N 天中某家的记录，从旧到新，缺失日期不补。
    func entries(provider: String, days: Int = HistoryStore.retentionDays, now: Date = Date()) -> [UsageHistoryEntry] {
        let keep = Set(Self.dateKeys(days: days, now: now))
        return load()
            .filter { $0.provider == provider && keep.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    func latest(provider: String) -> UsageHistoryEntry? {
        load().filter { $0.provider == provider }.max { $0.date < $1.date }
    }

    /// 供给面板 sparkline：从旧到新共 N 个值，缺失或当天没有百分比时为 nil。
    func remainingValues(provider: String, days: Int = HistoryStore.retentionDays, now: Date = Date()) -> [Double?] {
        let map = Dictionary(
            entries(provider: provider, days: days, now: now).map { ($0.date, $0.remainingPercent) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.dateKeys(days: days, now: now).map { map[$0].flatMap { $0 } }
    }

    func usedValues(provider: String, days: Int = HistoryStore.retentionDays, now: Date = Date()) -> [Double?] {
        let map = Dictionary(
            entries(provider: provider, days: days, now: now).map { ($0.date, $0.usedPercent) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.dateKeys(days: days, now: now).map { map[$0].flatMap { $0 } }
    }

    /// 某家最近 N 天的成本汇总（仅来自已记录的历史）。
    func costSummary(provider: String, days: Int = HistoryStore.retentionDays, now: Date = Date()) -> CostSummary {
        let entries = entries(provider: provider, days: days, now: now)
        let withCost = entries.compactMap { entry -> (Double, TokenUsage)? in
            guard let cost = entry.cost else { return nil }
            return (cost, entry.tokens ?? .zero)
        }
        return CostSummary(
            cost: withCost.reduce(0) { $0 + $1.0 },
            tokens: withCost.reduce(.zero) { $0 + $1.1 },
            sessions: 0,
            days: max(1, days),
            readable: !entries.isEmpty,
            databasePath: fileURL.path,
            updatedAt: entries.last?.updatedAt,
            error: nil
        )
    }

    // MARK: - 持久化

    private func load() -> [UsageHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            return persisted.entries
        }
        if let array = try? JSONDecoder().decode([UsageHistoryEntry].self, from: data) {
            return array
        }
        // 损坏：备份现场后从空历史开始，绝不覆盖前静默。
        let backup = Self.backupCorruptFile(at: fileURL)
        log("history.json 损坏\(backup.map { "，已备份到 \($0.path)" } ?? "，备份失败")")
        return []
    }

    private func save(_ entries: [UsageHistoryEntry]) -> Bool {
        let sorted = entries.sorted {
            $0.date == $1.date ? $0.provider < $1.provider : $0.date < $1.date
        }
        let persisted = Persisted(schema: 1, entries: sorted)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            log("history save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func acquireLock() -> Bool {
        guard let lock else { return true }
        for _ in 0..<100 {
            if lock.try() { return true }
            usleep(20_000)
        }
        log("history lock timeout")
        return false
    }

    private func upsert(_ entries: inout [UsageHistoryEntry], _ entry: UsageHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.date == entry.date && $0.provider == entry.provider }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private static func backupCorruptFile(at url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var destination = url.appendingPathExtension("corrupt-\(stamp)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = url.appendingPathExtension("corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - 日期

    private static func dateKeys(days: Int, now: Date, calendar: Calendar = .current) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dayKey(date, calendar: calendar)
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
