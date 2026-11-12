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
        var updatedAt: String?
    }

    private struct ConsumedState: Codable {
        var baseline: Double
        var spent: Double
        var updatedAt: String?
    }

    private struct State: Codable {
        var day: String
        var deepseek: DeepSeekState?
        var trae: ConsumedState?
        var workbuddy: ConsumedState?
    }

    private let fileURL: URL
    private let lock: NSDistributedLock?
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
        lock = NSDistributedLock(path: fileURL.path + ".lock")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(State.self, from: data),
           loaded.day == Self.dayKey {
            state = loaded
        } else {
            state = State(day: Self.dayKey, deepseek: nil, trae: nil, workbuddy: nil)
        }
    }

    func record(snapshot: QuotaSnapshot, only: Set<String>? = nil) {
        guard let lock else { return }
        var acquired = false
        for _ in 0..<100 {
            if lock.try() { acquired = true; break }
            usleep(20_000)
        }
        guard acquired else { return }
        defer { lock.unlock() }
        reloadState()

        if state.day != Self.dayKey {
            // 跨天：清空基线重新开始。
            state = State(day: Self.dayKey, deepseek: nil, trae: nil, workbuddy: nil)
        }

        let stamp = snapshot.sampledAt ?? snapshot.updatedAt

        if (only == nil || only!.contains("deepseek")),
           let deepseek = snapshot.providers.first(where: { $0.id == "deepseek" }),
           let balance = deepseek.balance {
            if var current = state.deepseek {
                if Self.isNewer(stamp, than: current.updatedAt) {
                    if balance < current.lastBalance {
                        current.spent += current.lastBalance - balance
                    }
                    current.lastBalance = balance
                    current.updatedAt = stamp
                    state.deepseek = current
                }
            } else {
                state.deepseek = DeepSeekState(lastBalance: balance, spent: 0, updatedAt: stamp)
            }
        }

        for id in ["trae", "workbuddy"] {
            guard only == nil || only!.contains(id),
                  let provider = snapshot.providers.first(where: { $0.id == id }),
                  let consumed = provider.consumed else { continue }
            let keyPath = id == "trae" ? \State.trae : \State.workbuddy
            if var current = state[keyPath: keyPath] {
                guard Self.isNewer(stamp, than: current.updatedAt) else { continue }
                if consumed < current.baseline {
                    // 套餐周期重置/过期套餐被移除：只重建基线，保留今天已经记录的消耗。
                    current.baseline = consumed
                } else {
                    current.spent = max(0, consumed - current.baseline)
                }
                current.updatedAt = stamp
                state[keyPath: keyPath] = current
            } else {
                state[keyPath: keyPath] = ConsumedState(baseline: consumed, spent: 0, updatedAt: stamp)
            }
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

    // MARK: - 快照顺序判断

    /// 新快照的 `updatedAt` 是否严格晚于已记录的时间。
    /// 两个时间都能解析时按时间比较；否则退化为 ISO8601 字符串的字典序（同格式下等价）。
    private static func isNewer(_ incoming: String, than stored: String?) -> Bool {
        guard let stored else { return true }
        if let new = ISO8601DateFormatter.flexible.date(from: incoming),
           let old = ISO8601DateFormatter.flexible.date(from: stored) {
            return new > old
        }
        return incoming > stored
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
