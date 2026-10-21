import AppKit
import UserNotifications

/// 低额度通知：按配置的百分比 / 积分阈值检查，每家每天最多一次。
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    var isEnabled: Bool {
        (try? ConfigStore())?.bool("notifications.enabled", default: false) ?? false
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func check(snapshot: QuotaSnapshot, config: ConfigStore) {
        guard config.bool("notifications.enabled", default: false) else { return }
        let percentLimit = config.double("notifications.percent", default: 20)

        for provider in snapshot.providers where provider.status != "disabled" {
            var message: String?
            var key: String?

            if let remaining = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent,
               remaining <= percentLimit {
                message = "剩余 \(Int(remaining.rounded()))%，低于 \(Int(percentLimit))%"
                key = "percent"
            } else if let threshold = QuotaStyle.creditThresholds[provider.id],
                      let value = QuotaStyle.remainingNumber(provider),
                      value <= threshold {
                let unit = provider.id == "deepseek" ? "¥" : "积分"
                message = "剩余 \(unit)\(formatted(value))，低于阈值 \(unit)\(formatted(threshold))"
                key = "credit"
            }

            guard let message, let key, !hasNotified(provider.id, config: config) else { continue }
            send(title: "\(provider.name) 额度偏低", body: message)
            config.set("notifications.last.\(provider.id)", todayKey)
            config.set("notifications.lastKind.\(provider.id)", key)
            try? config.save()
        }
    }

    func sendTest() {
        send(title: "Agent 额度", body: "这是一条低额度通知测试。")
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "low-quota-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("notification add failed: \(error.localizedDescription)")
            }
        }
    }

    /// App 在前台时默认不显示横幅；手动允许，否则测试/低额度通知看起来像没发。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func hasNotified(_ provider: String, config: ConfigStore) -> Bool {
        config.string("notifications.last.\(provider)") == todayKey
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
