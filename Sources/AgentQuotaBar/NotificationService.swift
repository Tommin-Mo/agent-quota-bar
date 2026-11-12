import AppKit
import UserNotifications

/// 低额度通知：按配置的百分比 / 积分阈值检查，每家每天最多一次。
///
/// 只在数据足够新时判断；并且要等系统授权通过、`add` 成功后才记录“今天已通知”，
/// 避免拿缓存快照误报，也避免投递失败后当天再也收不到。
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    /// 正在投递中的 provider，防止同一轮多次 render 重复发送。
    private var inFlight: Set<String> = []

    private override init() {
        super.init()
        center.delegate = self
    }

    var isEnabled: Bool {
        ConfigStore().bool("notifications.enabled", default: false)
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
        guard isFresh(snapshot, config: config) else { return }

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

            guard let message, let key else { continue }
            guard !hasNotified(provider.id, config: config) else { continue }
            guard !inFlight.contains(provider.id) else { continue }
            inFlight.insert(provider.id)
            deliver(
                title: "\(provider.name) 额度偏低",
                body: message,
                providerID: provider.id,
                kind: key,
                config: config
            )
        }
    }

    func sendTest() {
        send(title: "Agent 额度", body: "这是一条低额度通知测试。")
    }

    /// 快照必须是最近一次刷新得到的；加载自磁盘的旧缓存不参与判断。
    private func isFresh(_ snapshot: QuotaSnapshot, config: ConfigStore) -> Bool {
        guard let date = snapshot.updatedDate else { return false }
        let age = Date().timeIntervalSince(date)
        if age < 0 { return true } // 时钟回拨/未来时间：不做拦截
        let limit = max(600, TimeInterval(config.refreshSeconds) * 2)
        return age <= limit
    }

    private func send(title: String, body: String) {
        deliver(title: title, body: body, providerID: nil, kind: nil, config: nil)
    }

    private func deliver(
        title: String,
        body: String,
        providerID: String?,
        kind: String?,
        config: ConfigStore?
    ) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard authorized else {
                DispatchQueue.main.async {
                    if let providerID { self.inFlight.remove(providerID) }
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "low-quota-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            self.center.add(request) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let providerID else { return }
                    self.inFlight.remove(providerID)
                    guard error == nil else {
                        NSLog("notification add failed: \(error?.localizedDescription ?? "unknown")")
                        return
                    }
                    // 只有确认投递成功且已授权，才记为“今天已通知”。
                    guard let config, let kind else { return }
                    config.set("notifications.last.\(providerID)", self.todayKey)
                    config.set("notifications.lastKind.\(providerID)", kind)
                    try? config.save()
                }
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
