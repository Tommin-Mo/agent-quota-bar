import Foundation

/// 今日实际消费：
/// - DeepSeek：相邻两次余额的下降额累加，覆盖外部调用；充值/赠金上涨不计。
/// - Trae / WorkBuddy：累计消费计数器 - 当天 0 点基线；签到与充值不影响累计消费。
final class UsageTracker {
    static let shared = UsageTracker()

    private struct DeepSeekState: Codable {
        var lastBalance: Double
        var spent: Double
    }

    private struct ConsumedState: Codable {
        var baseline: Double
        var spent: Double
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
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-quota", isDirectory: true)
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

    func record(snapshot: QuotaSnapshot) {
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
            state = State(day: Self.dayKey, deepseek: nil, trae: nil, workbuddy: nil)
        }

        if let deepseek = snapshot.providers.first(where: { $0.id == "deepseek" }),
           let balance = deepseek.balance {
            if var current = state.deepseek {
                if balance < current.lastBalance {
                    current.spent += current.lastBalance - balance
                }
                current.lastBalance = balance
                state.deepseek = current
            } else {
                state.deepseek = DeepSeekState(lastBalance: balance, spent: 0)
            }
        }

        for id in ["trae", "workbuddy"] {
            guard let provider = snapshot.providers.first(where: { $0.id == id }),
                  let consumed = provider.consumed else { continue }
            let keyPath = id == "trae" ? \State.trae : \State.workbuddy
            if var current = state[keyPath: keyPath] {
                if consumed < current.baseline {
                    // 套餐周期重置：重新建立基线，今天的消耗从当前开始。
                    current.baseline = consumed
                    current.spent = 0
                } else {
                    current.spent = max(0, consumed - current.baseline)
                }
                state[keyPath: keyPath] = current
            } else {
                state[keyPath: keyPath] = ConsumedState(baseline: consumed, spent: 0)
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
