import Foundation

/// 每日自动签到：Trae + WorkBuddy + 豆包（豆包需要 Cookie）。
/// 由 App 启动时和每 15 分钟的定时器触发；同一天成功后不再重复。
final class CheckinService {
    private let service: QuotaService
    private var running = false
    var onUpdate: (() -> Void)?
    var onRequestRefresh: (() -> Void)?

    init(service: QuotaService) {
        self.service = service
    }

    private var config: ConfigStore { service.config }

    var isAutoEnabled: Bool {
        config.bool("checkin.auto", default: true)
    }

    var scheduledHour: Int {
        min(23, max(0, config.int("checkin.hour", default: 9)))
    }

    var hasCheckedInToday: Bool {
        guard config.string("checkin.lastDate") == Self.todayKey else { return false }
        // 同一天可能先成功、后手动重试失败；失败摘要不能算“已完成”。
        guard !config.string("checkin.lastSummary").contains("失败") else { return false }
        // 豆包是后接入的：如果今天先签了 Trae/WorkBuddy，再配置 Cookie，
        // 不能因为 lastDate 已存在就永远跳过豆包。必须看豆包自己的结果。
        if config.bool("providers.doubao.enabled", default: true),
           !config.string("providers.doubao.cookie").isEmpty {
            let result = config.string("checkin.results.doubao")
            guard result == "ok" || result == "already" || result == "inactive" else { return false }
        }
        return true
    }

    static func result(for id: String, in config: ConfigStore) -> String {
        guard config.string("checkin.resultDate") == todayKey else { return "待签到" }
        switch config.string("checkin.results.\(id)") {
        case "ok", "already": return "已签到"
        case "inactive": return "未开放"
        case "failed": return "签到失败"
        default: return "待签到"
        }
    }

    var isRunning: Bool { running }

    var statusText: String {
        if running { return "签到中…" }
        let rawSummary = config.string("checkin.lastSummary")
        let summary = rawSummary.contains("\n") || rawSummary.count > 180
            ? "签到失败，请重试"
            : rawSummary
        if config.bool("providers.doubao.enabled", default: true),
           config.string("providers.doubao.cookie").isEmpty {
            if hasCheckedInToday {
                return (summary.isEmpty ? "Trae / WorkBuddy 已签" : summary) + " · 豆包未配置 Cookie"
            }
            return "今日待签到 · 豆包未配置 Cookie"
        }
        if hasCheckedInToday {
            return summary.isEmpty ? "未返回签到结果" : summary
        }
        if summary.contains("失败") {
            return summary
        }
        return "今日待签到"
    }

    var detailText: String {
        guard isAutoEnabled else { return "自动签到已关闭" }
        if hasCheckedInToday { return "明天自动继续" }
        return "每日 \(String(format: "%02d:00", scheduledHour)) 自动签到"
    }

    /// 后台 LaunchAgent 也会签到并写配置；定时判断前先把磁盘状态读回来。
    func refreshFromDisk() {
        config.reload()
    }

    func runIfNeeded() {
        guard LaunchAgentInstaller.ownsBackgroundTasks else { return }
        config.reload()
        guard isAutoEnabled, !running, !hasCheckedInToday else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= scheduledHour else { return }
        if let last = Self.iso.date(from: config.string("checkin.lastAttempt")),
           Date().timeIntervalSince(last) < 30 * 60 {
            return
        }
        runNow(manual: false)
    }

    func runNow(manual: Bool, completion: ((CheckinReport) -> Void)? = nil) {
        guard !running else { return }
        running = true
        onUpdate?()
        config.set("checkin.lastAttempt", Self.iso.string(from: Date()))
        try? config.save()

        service.runCheckin { [weak self] result in
            guard let self else { return }
            self.running = false
            switch result {
            case .success(let report):
                var parts = report.results.map { item -> String in
                    let name = item.provider == "trae" ? "Trae"
                        : (item.provider == "workbuddy" ? "WorkBuddy" : "豆包")
                    switch item.status {
                    case "ok":
                        let points = item.points.map { " +\(Int($0))" } ?? ""
                        return "\(name)\(points)"
                    case "already":
                        return "\(name) 已签"
                    case "inactive":
                        return "\(name) 未开放"
                    default:
                        return "\(name) 失败"
                    }
                }
                if self.config.bool("providers.doubao.enabled", default: true),
                   self.config.string("providers.doubao.cookie").isEmpty {
                    parts.append("豆包未配置 Cookie")
                }
                let summary = parts.joined(separator: " · ")

                if let workbuddy = report.results.first(where: { $0.provider == "workbuddy" }),
                   let streak = workbuddy.streak {
                    self.config.set("checkin.workbuddyStreak", streak)
                }
                let results = Dictionary(report.results.map { ($0.provider, $0.status) }, uniquingKeysWith: { _, new in new })
                self.config.set("checkin.results", results)
                self.config.set("checkin.resultDate", Self.todayKey)
                let incomplete = report.results.isEmpty || report.results.contains { !["ok", "already", "inactive"].contains($0.status) }
                if !incomplete {
                    self.config.set("checkin.lastDate", Self.todayKey)
                }
                self.config.set("checkin.lastSummary", summary.isEmpty ? "未返回签到结果" : summary)
                try? self.config.save()
                self.onUpdate?()
                if !incomplete || manual {
                    if let onRequestRefresh = self.onRequestRefresh {
                        onRequestRefresh()
                    } else {
                        self.service.refresh()
                    }
                }
                completion?(report)
            case .failure(let error):
                let firstLine = error.localizedDescription
                    .split(separator: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map(String.init) ?? "未知错误"
                let message = String(firstLine.prefix(160))
                self.config.set("checkin.lastSummary", "签到失败：\(message)")
                try? self.config.save()
                self.onUpdate?()
                completion?(CheckinReport(results: []))
            }
        }
    }

    private static var todayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
