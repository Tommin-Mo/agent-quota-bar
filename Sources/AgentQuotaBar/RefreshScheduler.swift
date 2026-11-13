import Foundation

/// 唯一的额度刷新调度器。
///
/// 之前 App 里同时跑“全量刷新 60s”和“DeepSeek 单独 60s”两个 Timer；
/// 它们会在同一个时间点抢 `isRefreshing`，DeepSeek 先拿到锁时全量刷新被跳过，
/// 但 DeepSeek-only 的合并快照又会被当成一次新数据写进缓存，导致 Codex 等
/// provider 看起来“有更新时间、实际值一直旧”。
///
/// 现在只有一个时序源：每个 provider 记录自己的 nextDue，由同一个串行调度器
/// 计算本轮到底该抓哪几家，再发一次 `--only=` 请求。不会重叠，也不会互相饿死。
final class RefreshScheduler {
    private let service: QuotaService
    private let providerIDs = ["codex", "deepseek", "opencode", "trae", "workbuddy"]
    private var timer: Timer?
    private var nextDue: [String: Date] = [:]
    private var forceAll = false
    private var ticking = false

    init(service: QuotaService) {
        self.service = service
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        forceAll = true
        tick()
    }

    /// 手动刷新、唤醒、打开面板、恢复网络：强制下一次 tick 抓全量。
    func refreshNow() {
        forceAll = true
        tick()
    }

    /// 设置里的刷新间隔变了：让所有 provider 立即到期，按新间隔重新排。
    func intervalsChanged() {
        nextDue.removeAll()
        forceAll = true
        tick()
    }

    private func tick() {
        guard !ticking else { return }
        // 同一个刷新只允许一个在途；手动刷新刚结束时下一 tick 会自然接上。
        guard !service.isRefreshing else { return }

        ticking = true
        defer { ticking = false }

        let now = Date()
        let interval = TimeInterval(max(30, service.config.refreshSeconds))
        // DeepSeek 是余额差值制，外部 API 调用没有本地事件；60 秒采一次是
        // 为了让“今日 -¥”尽量少丢失。其他 provider 跟随显示刷新周期。
        let deepSeekInterval = min(60, interval)

        let due: [String]
        if forceAll {
            forceAll = false
            due = providerIDs
        } else {
            due = providerIDs.filter { (nextDue[$0] ?? .distantPast) <= now }
        }
        guard !due.isEmpty else { return }

        for id in due {
            nextDue[id] = now.addingTimeInterval(id == "deepseek" ? deepSeekInterval : interval)
        }
        // 全部都到期时走全量；只有 DeepSeek 到期时走 --only=deepseek。
        service.refresh(only: due.count == providerIDs.count ? nil : due.joined(separator: ","))
    }
}
