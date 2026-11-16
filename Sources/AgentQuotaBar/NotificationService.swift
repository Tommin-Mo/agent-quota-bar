import AppKit
import UserNotifications

/// 额度通知：
/// - 低额度 / 低余额（原有行为，每家每天一次）；
/// - 订阅即将到期或已到期（`subscriptionUntil`，默认提前 3 天）；
/// - 凭据疑似失效（provider 报错命中登录/密钥失效文案）；
/// - 数据过期（快照超过默认 12 小时未更新），此时不再基于旧数据判断额度。
///
/// 不清洗旧缓存：数据过期只提醒，不误报低额度。每条通知按“类型 + provider + 日期”去重，
/// 并且等系统授权通过、`add` 成功后才记录“今天已通知”。
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    /// 正在投递中的通知键，防止同一轮多次 render 重复发送。
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

    // MARK: - 检查

    func check(snapshot: QuotaSnapshot, config: ConfigStore) {
        guard config.bool("notifications.enabled", default: false) else { return }
        let now = Date()

        // 数据过期：只提醒一次，不再用旧快照判断额度/订阅。
        if let stale = Self.stalenessMessage(
            snapshot: snapshot,
            staleHours: config.int("notifications.staleHours", default: 12),
            now: now
        ) {
            let path = Self.dedupePath(.stale)
            guard !hasNotified(path, config: config), !inFlight.contains("stale") else { return }
            inFlight.insert("stale")
            deliver(
                title: stale.title,
                body: stale.body,
                inFlightKey: "stale",
                dedupeValues: [path: Self.todayKey(now)],
                config: config
            )
            return
        }

        let percentLimit = config.double("notifications.percent", default: 20)
        let subscriptionDays = config.int("notifications.subscriptionDays", default: 3)
        let credentialDays = config.int("notifications.credentialDays", default: 60)
        let accounts = AccountStore(config: config)

        for provider in snapshot.providers where provider.status != "disabled" {
            let account = accounts.activeAccount(for: provider.id)

            // 1) 凭据失效优先：额度取不到时，先让用户重新登录。
            if let message = Self.credentialMessage(
                for: provider,
                account: account,
                credentialDays: credentialDays,
                now: now
            ) {
                sendIfNeeded(
                    kind: .credential,
                    providerID: provider.id,
                    title: "\(provider.name) 登录凭据可能已失效",
                    body: message,
                    config: config,
                    now: now
                )
                continue
            }

            // 2) 订阅到期。
            if let message = Self.subscriptionMessage(
                for: provider,
                thresholdDays: subscriptionDays,
                now: now
            ) {
                sendIfNeeded(
                    kind: .subscription,
                    providerID: provider.id,
                    title: "\(provider.name) 订阅提醒",
                    body: message,
                    config: config,
                    now: now
                )
                continue
            }

            // 3) 低额度 / 低余额（原有行为）。
            var message: String?
            var kind: String?
            if let remaining = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent,
               remaining <= percentLimit {
                message = "剩余 \(Int(remaining.rounded()))%，低于 \(Int(percentLimit))%"
                kind = "percent"
            } else if let threshold = QuotaStyle.creditThresholds[provider.id],
                      let value = QuotaStyle.remainingNumber(provider),
                      value <= threshold {
                let unit = provider.id == "deepseek" ? "¥" : "积分"
                message = "剩余 \(unit)\(formatted(value))，低于阈值 \(unit)\(formatted(threshold))"
                kind = "credit"
            }
            guard let message, let kind else { continue }
            let path = Self.quotaDedupePath(provider.id)
            guard !hasNotified(path, config: config) else { continue }
            let inFlightKey = "quota.\(provider.id)"
            guard !inFlight.contains(inFlightKey) else { continue }
            inFlight.insert(inFlightKey)
            deliver(
                title: "\(provider.name) 额度偏低",
                body: message,
                inFlightKey: inFlightKey,
                dedupeValues: [
                    path: Self.todayKey(now),
                    "notifications.lastKind.\(provider.id)": kind,
                ],
                config: config
            )
        }
    }

    func sendTest() {
        send(title: "Agent 额度", body: "这是一条低额度通知测试。")
    }

    // MARK: - 判定（static 便于单测）

    enum Kind: String {
        case quota
        case subscription
        case credential
        case stale
    }

    static func dedupePath(_ kind: Kind, providerID: String? = nil) -> String {
        switch kind {
        case .quota:
            return providerID.map { quotaDedupePath($0) } ?? "notifications.last.quota"
        case .subscription:
            return "notifications.last.subscription.\(providerID ?? "all")"
        case .credential:
            return "notifications.last.credential.\(providerID ?? "all")"
        case .stale:
            return "notifications.last.stale"
        }
    }

    static func quotaDedupePath(_ providerID: String) -> String {
        "notifications.last.\(providerID)"
    }

    /// 快照超过 `staleHours` 未更新时返回提醒；未过期返回 nil。
    static func stalenessMessage(
        snapshot: QuotaSnapshot,
        staleHours: Int,
        now: Date = Date()
    ) -> (title: String, body: String)? {
        guard let updated = snapshot.updatedDate else { return nil }
        let age = now.timeIntervalSince(updated)
        guard age > 0 else { return nil }
        let threshold = TimeInterval(max(1, staleHours)) * 3600
        guard age >= threshold else { return nil }
        let days = Int(age / 86_400)
        let hours = max(1, Int(age / 3600))
        let ageText = days >= 2 ? "\(days) 天" : "\(hours) 小时"
        return (
            title: "额度数据已过期",
            body: "数据已 \(ageText)未更新，请检查网络或手动刷新；过期数据不再用于低额度判断。"
        )
    }

    /// 订阅到期提醒。自动续费且未到期时跳过；已到期或未开启自动续费时提醒。
    static func subscriptionMessage(
        for provider: ProviderStatus,
        thresholdDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let raw = provider.subscriptionUntil,
              let expiry = FlexibleDateParser.date(from: raw) else {
            return nil
        }
        let willRenew = provider.subscriptionWillRenew == true
        if willRenew && expiry > now { return nil }

        let today = calendar.startOfDay(for: now)
        let expiryDay = calendar.startOfDay(for: expiry)
        let days = calendar.dateComponents([.day], from: today, to: expiryDay).day ?? 0

        if expiry < now {
            return "订阅已于 \(dateText(expiry, calendar: calendar)) 到期，请及时续费。"
        }
        if days == 0 {
            return "订阅今天到期（\(dateText(expiry, calendar: calendar))）。"
        }
        if days <= max(1, thresholdDays) {
            return "订阅将在 \(days) 天后到期（\(dateText(expiry, calendar: calendar))）。"
        }
        return nil
    }

    /// 凭据/登录态疑似失效时返回提示。只有 provider 报错且文案命中登录/密钥类错误才提醒，
    /// 网络/SSL/超时不在此列（那由“数据过期”提醒覆盖）。
    static func credentialMessage(
        for provider: ProviderStatus,
        account: ProviderAccount? = nil,
        credentialDays: Int = 60,
        now: Date = Date()
    ) -> String? {
        guard provider.status == "error" else { return nil }
        let errorText = [provider.error, provider.detail, provider.headline]
            .compactMap { $0 }
            .joined(separator: " ")
        guard isAuthenticationError(errorText) else { return nil }

        var message = "登录态/密钥可能已失效，请重新登录或更新凭据。"
        if let account {
            let name = (account.account?.isEmpty == false ? account.account! : account.label)
            if !name.isEmpty, !account.isLegacy {
                message += "当前账号：\(name)。"
            }
            if let updated = account.updatedDate {
                let days = Int(now.timeIntervalSince(updated) / 86_400)
                if days >= max(1, credentialDays) {
                    message += "凭据已 \(days) 天未更新。"
                }
            }
        }
        return message
    }

    static func isAuthenticationError(_ raw: String) -> Bool {
        let text = raw.lowercased()
        guard !text.isEmpty else { return false }
        let patterns = [
            "api key 无效", "api key 已过期", "apikey 无效", "密钥无效", "密钥已过期",
            "invalid api key", "invalid_api_key", "incorrect api key", "api key invalid",
            "unauthorized", "unauthenticated", "authentication failed", "auth failed",
            "cookie 已失效", "cookie 失效", "cookie expired", "cookie 无效", "invalid cookie",
            "登录态", "登录已失效", "登录失效", "请重新登录", "重新登录", "未登录",
            "重新授权", "授权已过期", "未授权",
            "token 已过期", "token expired", "invalid token", "invalid_grant",
            "credential", "凭据",
            "http 401", "http 403", "401 unauthorized", "403 forbidden",
        ]
        return patterns.contains { text.contains($0) }
    }

    static func todayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func dateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 投递

    private func sendIfNeeded(
        kind: Kind,
        providerID: String,
        title: String,
        body: String,
        config: ConfigStore,
        now: Date
    ) {
        let path = Self.dedupePath(kind, providerID: providerID)
        guard !hasNotified(path, config: config) else { return }
        let inFlightKey = "\(kind.rawValue).\(providerID)"
        guard !inFlight.contains(inFlightKey) else { return }
        inFlight.insert(inFlightKey)
        deliver(
            title: title,
            body: body,
            inFlightKey: inFlightKey,
            dedupeValues: [path: Self.todayKey(now)],
            config: config
        )
    }

    private func send(title: String, body: String) {
        deliver(title: title, body: body, inFlightKey: nil, dedupeValues: [:], config: nil)
    }

    private func deliver(
        title: String,
        body: String,
        inFlightKey: String?,
        dedupeValues: [String: String],
        config: ConfigStore?
    ) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard authorized else {
                DispatchQueue.main.async {
                    if let inFlightKey { self.inFlight.remove(inFlightKey) }
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
                    if let inFlightKey { self.inFlight.remove(inFlightKey) }
                    guard error == nil else {
                        NSLog("notification add failed: \(error?.localizedDescription ?? "unknown")")
                        return
                    }
                    // 只有确认投递成功且已授权，才记为“今天已通知”。
                    guard let config, !dedupeValues.isEmpty else { return }
                    for (path, value) in dedupeValues {
                        config.set(path, value)
                    }
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

    private func hasNotified(_ path: String, config: ConfigStore) -> Bool {
        config.string(path) == Self.todayKey()
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }
}
