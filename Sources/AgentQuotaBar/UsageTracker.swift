import Foundation

/// 今日实际消费：
/// - DeepSeek：相邻两次余额的下降额累加，覆盖外部调用；充值/赠金上涨不计。
/// - Trae / WorkBuddy：累计消费计数器 - 当天 0 点基线；签到与充值不影响累计消费。
///
/// App 的 60s 轮询与 LaunchAgent 的 5 分钟采样会并发运行，采集结果可能乱序到达。
/// 每份 provider 状态都记录快照的 `updatedAt`，只接受比已记录更新的快照，
/// 避免旧快照把余额“倒回去”再算一次，造成重复计费。
final class UsageTracker {
    static let shared = UsageTracker()

    private struct DeepSeekState: Codable {
        var lastBalance: Double
        var spent: Double
        var identity: String?
        var updatedAt: String?
    }

    private struct ConsumedState: Codable {
        var baseline: Double
        var spent: Double
        var identity: String?
        var updatedAt: String?
    }

    private struct State: Codable {
        var day: String
        var deepseek: DeepSeekState?
        var trae: ConsumedState?
        var workbuddy: ConsumedState?
        var spentByIdentity: [String: Double]? = nil
    }

    private let fileURL: URL
    private var state: State

    private init() {
        let directory: URL
        if let custom = ProcessInfo.processInfo.environment["AGENT_QUOTA_CONFIG"] {
            // 与 ConfigStore 使用同一个目录，便于应用/LaunchAgent/测试共用同一份状态。
            directory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/agent-quota", isDirectory: true)
        }
        fileURL = directory.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(State.self, from: data),
           loaded.day == Self.dayKey {
            state = loaded
        } else {
            state = State(day: Self.dayKey, deepseek: nil, trae: nil, workbuddy: nil)
        }
    }

    func record(snapshot: QuotaSnapshot, only: Set<String>? = nil) {
        guard let fd = try? FileWriteLock.acquire(for: fileURL) else { return }
        defer { close(fd) }
        reloadState()

        if state.day != Self.dayKey {
            // 跨天：清空基线重新开始。
            state = State(day: Self.dayKey, deepseek: nil, trae: nil, workbuddy: nil)
        }

        func freshStamp(for provider: ProviderStatus, after stored: String?) -> String? {
            let stamp = provider.sampledAt ?? snapshot.sampledAt ?? snapshot.updatedAt
            guard let incoming = FlexibleDateParser.date(from: stamp), Calendar.current.isDateInToday(incoming),
                  stored.flatMap(FlexibleDateParser.date(from:)).map({ incoming > $0 }) ?? true else { return nil }
            return stamp
        }
        if (only == nil || only!.contains("deepseek")),
           let deepseek = snapshot.providers.first(where: { $0.id == "deepseek" }),
           deepseek.isUsable, deepseek.cached != true, let balance = deepseek.balance,
           let stamp = freshStamp(for: deepseek, after: state.deepseek?.updatedAt) {
            if var current = state.deepseek, current.identity == deepseek.identity {
                current.spent += max(0, current.lastBalance - balance)
                current.lastBalance = balance
                current.updatedAt = stamp
                state.deepseek = current
            } else {
                state.deepseek = DeepSeekState(lastBalance: balance, spent: state.spentByIdentity?["deepseek:" + deepseek.identity] ?? 0, identity: deepseek.identity, updatedAt: stamp)
            }
            if state.spentByIdentity == nil { state.spentByIdentity = [:] }
            let spent = state.deepseek?.spent
            state.spentByIdentity?["deepseek:" + deepseek.identity] = spent
        }

        for id in ["trae", "workbuddy"] {
            guard only == nil || only!.contains(id),
                  let provider = snapshot.providers.first(where: { $0.id == id }),
                  provider.isUsable, provider.cached != true, let consumed = provider.consumed else { continue }
            let keyPath = id == "trae" ? \State.trae : \State.workbuddy
            guard let stamp = freshStamp(for: provider, after: state[keyPath: keyPath]?.updatedAt) else { continue }
            if var current = state[keyPath: keyPath], current.identity == provider.identity {
                if consumed >= current.baseline {
                    // 套餐周期重置/过期套餐被移除时不能重算，否则今日消耗会从 200 掉到 5。
                    current.spent += max(0, consumed - current.baseline)
                }
                current.baseline = consumed
                current.updatedAt = stamp
                state[keyPath: keyPath] = current
            } else {
                state[keyPath: keyPath] = ConsumedState(baseline: consumed, spent: state.spentByIdentity?[id + ":" + provider.identity] ?? 0, identity: provider.identity, updatedAt: stamp)
            }
            if state.spentByIdentity == nil { state.spentByIdentity = [:] }
            let spent = state[keyPath: keyPath]?.spent
            state.spentByIdentity?[id + ":" + provider.identity] = spent
        }

        save()
    }

    func todaySpent(for providerID: String) -> Double? {
        reloadState()
        guard state.day == Self.dayKey else { return nil }
        switch providerID {
        case "deepseek": return state.deepseek?.spent
        case "trae": return state.trae?.spent
        case "workbuddy": return state.workbuddy?.spent
        default: return nil
        }
    }

    private func reloadState() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(State.self, from: data)
        else { return }
        if loaded.day == Self.dayKey {
            state = loaded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var dayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
