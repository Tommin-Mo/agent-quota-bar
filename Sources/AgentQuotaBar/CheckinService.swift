import Foundation

/// 每日自动签到：Trae + WorkBuddy。
/// 由 App 启动时和每 15 分钟的定时器触发；同一天成功后不再重复。
final class CheckinService {
    private let service: QuotaService
    private var running = false
    var onUpdate: (() -> Void)?

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
        return !config.string("checkin.lastSummary").contains("失败")
    }

    var isRunning: Bool { running }

    var statusText: String {
        if running { return "签到中…" }
        let rawSummary = config.string("checkin.lastSummary")
        let summary = rawSummary.contains("\n") || rawSummary.count > 180
            ? "签到失败，请重试"
            : rawSummary
        if hasCheckedInToday {
            return summary.isEmpty ? "今日已签到" : summary
        }
        if summary.contains("失败") {
            return summary
        }
        return "今日待签到"
    }

    var detailText: String {
        if hasCheckedInToday { return "明天自动继续" }
        return "每日 \(String(format: "%02d:00", scheduledHour)) 自动签到"
    }

    func runIfNeeded() {
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
                let summary = report.results.map { item -> String in
                    let name = item.provider == "trae" ? "Trae" : "WorkBuddy"
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
                }.joined(separator: " · ")

                if let workbuddy = report.results.first(where: { $0.provider == "workbuddy" }),
                   let streak = workbuddy.streak {
                    self.config.set("checkin.workbuddyStreak", streak)
                }
                let incomplete = report.results.contains { $0.status == "failed" }
                if !incomplete {
                    self.config.set("checkin.lastDate", Self.todayKey)
                }
                self.config.set("checkin.lastSummary", summary.isEmpty ? "今日已签到" : summary)
                try? self.config.save()
                self.onUpdate?()
                if !incomplete || manual {
                    self.service.refresh()
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
