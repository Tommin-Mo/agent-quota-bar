import Foundation

/// 本地额度/成本历史：每个 provider 每天一条快照，保留最近 35 天。
///
/// 文件：`<配置目录>/history.json`（与 config.json / usage.json 同目录，0600）。
/// 与 `scripts/quota` 的 `history/YYYY-MM-DD.json`（CLI 自己的成本记录）分开存放，互不覆盖。
/// 读取时从磁盘加载；写入用分布式锁 + 原子替换，损坏文件先备份再重建。
final class HistoryStore {
    static let shared = HistoryStore()

    static let retentionDays = 35
    static let fileName = "history.json"

    private struct Persisted: Codable {
        var schema: Int?
        var entries: [UsageHistoryEntry]
    }

    let fileURL: URL

    init(configURL: URL = ConfigStore.defaultURL) {
        fileURL = configURL.deletingLastPathComponent().appendingPathComponent(Self.fileName)
    }

    // MARK: - 记录

    /// 把一次刷新结果写入当天历史。成本优先用 `costs` 参数，其次用 collector 返回的
    /// `provider.cost.today`；两者都没有时保留当天已有成本。
    @discardableResult
    func record(
        snapshot: QuotaSnapshot,
        costs: [String: CostSummary] = [:],
        only: Set<String>? = nil,
        preferredWindows: [String: String] = [:],
        now: Date = Date()
    ) -> Bool {
        guard let fd = try? FileWriteLock.acquire(for: fileURL) else { return false }
        defer { close(fd) }

        let calendar = Calendar.current
        let today = Self.dayKey(now, calendar: calendar)
        let keep = Set(Self.dateKeys(days: Self.retentionDays, now: now, calendar: calendar))
        guard let stored = try? load(repair: true) else { return false }
        var entries = stored.filter { keep.contains($0.date) }

        for provider in snapshot.providers where provider.isUsable && provider.cached != true && (only == nil || only!.contains(provider.id)) {
            var entry = entries.first { $0.date == today && $0.provider == provider.id }
                ?? UsageHistoryEntry(date: today, provider: provider.id)

            let stamp = provider.sampledAt ?? snapshot.sampledAt ?? snapshot.updatedAt
            guard let date = FlexibleDateParser.date(from: stamp), Self.dayKey(date) == today,
                  entry.updatedAt.flatMap(FlexibleDateParser.date(from:)).map({ $0 < date }) ?? true else { continue }
            let hadSnapshot = entry.updatedAt != nil
            let sameAccount = entry.identity == provider.identity
            if !hadSnapshot && entry.openingBalances == nil && entry.dailyTotals == nil && entry.dailyDelta == nil { entry.openingBalances = [:] }
            let priorWallet = entry.walletSamples?[provider.identity]
            if !sameAccount {
                entry.windows = nil
                entry.windowEnds = nil
                entry.balance = nil
                entry.consumed = nil
                entry.remainingPercent = nil
                entry.usedPercent = nil
            }
            let currentWindows = Dictionary(provider.metrics.compactMap { metric -> (String, Double)? in
                guard metric.kind == "percent", let used = metric.usedPercent ?? metric.remainingPercent.map({ 100 - $0 }) else { return nil }
                return (metric.label, used)
            }, uniquingKeysWith: max)
            var deltas: [(String, Double)] = []
            let lastCounter = priorWallet?.consumed ?? entry.consumed
            let lastBalance = priorWallet?.balance ?? entry.balance
            let counterAdvanced = provider.consumed.flatMap { current in lastCounter.map { current >= $0 } } ?? false
            if counterAdvanced, let current = provider.consumed, let previous = lastCounter {
                deltas.append(("积分", max(0, current - previous)))
            }
            let currency = provider.creditMetric?.currency
            let balance = QuotaStyle.remainingNumber(provider)
            let balanceUnit = currency.flatMap { $0.isEmpty ? nil : $0 } ?? (provider.creditMetric == nil ? "单位未记录" : provider.pointUnit)
            if let balance, balance.isFinite {
                let unitChanged = entry.balanceUnit.map { $0 != balanceUnit } ?? false
                if unitChanged {
                    entry.openingBalances = [provider.identity: balance]
                } else {
                    if entry.openingBalances == nil { entry.openingBalances = [:] }
                    if entry.openingBalances?[provider.identity] == nil {
                        entry.openingBalances?[provider.identity] = balance
                    }
                }
                entry.balanceUnit = balanceUnit
            }
            if entry.referenceWindow == nil, !currentWindows.isEmpty {
                let preferred = preferredWindows[provider.id] ?? ""
                entry.referenceWindow = [preferred, "本周", provider.primaryMetric?.label ?? ""].first { currentWindows[$0] != nil } ?? currentWindows.keys.sorted().first
            }
            if let balance, let previous = lastBalance,
               !counterAdvanced || currency?.isEmpty == false {
                deltas.append((balanceUnit, max(0, previous - balance)))
            }
            let codex = provider.id == "codex"
            var baselines = codex ? entry.windows ?? [:] : currentWindows
            var ends = codex ? entry.windowEnds ?? [:] : [:]
            for metric in provider.metrics {
                guard let end = metric.resetAt else { continue }
                ends[metric.label] = end
            }
            for (label, used) in currentWindows.sorted(by: { $0.key < $1.key }) {
                if let previous = entry.windows?[label] {
                    let reset = entry.windowEnds?[label]
                    if codex, let reset, let end = ends[label], end < reset, end <= date.timeIntervalSince1970 * 1000 {
                        ends[label] = reset
                        continue // Delayed reading from an already closed window.
                    }
                    let rolled = reset.map { end in
                        guard let prior = FlexibleDateParser.date(from: entry.updatedAt) else { return false }
                        return (codex || prior.timeIntervalSince1970 * 1000 < end) && end <= date.timeIntervalSince1970 * 1000 &&
                            provider.metrics.contains { $0.label == label && ($0.resetAt ?? 0) > end }
                    } ?? false
                    deltas.append(("周期：" + label, max(0, rolled ? used : used - previous)))
                    // Within a Codex window, a lower reading cannot undo already counted use.
                    baselines[label] = codex && !rolled ? max(previous, used) : used
                } else {
                    baselines[label] = used
                }
            }
            if !deltas.isEmpty {
                var totals = entry.dailyTotals ?? [:]
                if totals.isEmpty, let unit = entry.deltaUnit, let legacy = entry.dailyDelta {
                    totals[unit] = legacy
                }
                for (unit, delta) in deltas { totals[unit, default: 0] += delta }
                entry.dailyTotals = totals
                if let (unit, _) = deltas.first(where: { $0.1 > 0 }) ?? deltas.first {
                    entry.deltaUnit = unit
                    entry.dailyDelta = totals[unit]
                }
                if deltas.contains(where: { $0.1 > 0 }) { entry.activeIntervals = (entry.activeIntervals ?? 0) + 1 }
            }
            entry.windowEnds = ends
            entry.windows = baselines
            entry.identity = provider.identity
            entry.costCurrency = provider.cost?.currency ?? entry.costCurrency
            let percentMetrics = provider.metrics.filter { $0.kind == "percent" }
            let remainingValues = percentMetrics.compactMap(\.remainingPercent)
            if let remaining = remainingValues.min() {
                entry.remainingPercent = remaining
                entry.usedPercent = max(0, 100 - remaining)
            }
            entry.balance = balance
            entry.consumed = provider.consumed
            if balance != nil {
                if entry.walletSamples == nil { entry.walletSamples = [:] }
                entry.walletSamples?[provider.identity] = UsageHistoryEntry.WalletSample(balance: balance, consumed: provider.consumed)
            }
            entry.status = provider.status
            entry.account = provider.account
            entry.plan = provider.plan
            entry.updatedAt = stamp

            if let explicit = costs[provider.id], explicit.readable {
                entry.costCurrency = provider.cost?.currency ?? (provider.id == "opencode" ? "USD" : nil)
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
        for (providerID, cost) in costs where cost.readable && snapshot.provider(withID: providerID) == nil {
            var entry = entries.first { $0.date == today && $0.provider == providerID }
                ?? UsageHistoryEntry(date: today, provider: providerID)
            if providerID == "opencode" { entry.costCurrency = "USD" }
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
        guard let fd = try? FileWriteLock.acquire(for: fileURL) else { return false }
        defer { close(fd) }

        let calendar = Calendar.current
        let today = Self.dayKey(now, calendar: calendar)
        let keep = Set(Self.dateKeys(days: Self.retentionDays, now: now, calendar: calendar))
        guard let stored = try? load(repair: true) else { return false }
        var entries = stored.filter { keep.contains($0.date) }
        for (providerID, cost) in costs where cost.readable {
            var entry = entries.first { $0.date == today && $0.provider == providerID }
                ?? UsageHistoryEntry(date: today, provider: providerID)
            if providerID == "opencode" { entry.costCurrency = "USD" }
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
        return ((try? load()) ?? [])
            .filter { $0.provider == provider && keep.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    func latest(provider: String) -> UsageHistoryEntry? {
        ((try? load()) ?? []).filter { $0.provider == provider }.max { $0.date < $1.date }
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

    private func load(repair: Bool = false) throws -> [UsageHistoryEntry] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            return persisted.entries
        }
        if let array = try? JSONDecoder().decode([UsageHistoryEntry].self, from: data) {
            return array
        }
        guard repair, Self.backupCorruptFile(at: fileURL) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
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
            try FileWriteLock.writeAtomically(data, to: fileURL)
            return true
        } catch {
            log("history save failed: \(error.localizedDescription)")
            return false
        }
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
