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

    typealias Submit = (String, String, @escaping (Bool) -> Void) -> Void
    private let submit: Submit

    init(submit: @escaping Submit) {
        self.submit = submit
        super.init()
    }

    private override init() {
        submit = Self.submitToSystem
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

    func presentationStatus(completion: @escaping (UNAuthorizationStatus, String) -> Void) {
        center.getNotificationSettings { settings in
            let style = Self.presentationText(alertsEnabled: settings.alertSetting == .enabled, style: settings.alertStyle)
            DispatchQueue.main.async { completion(settings.authorizationStatus, style) }
        }
    }

    static func presentationText(alertsEnabled: Bool, style: UNAlertStyle) -> String {
        guard alertsEnabled, style != .none else { return "未开启弹出提示" }
        return style == .alert ? "允许提醒窗口" : "允许横幅"
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
        ), !hasNotified(Self.dedupePath(.stale), config: config), !inFlight.contains("stale") {
            let path = Self.dedupePath(.stale)
            inFlight.insert("stale")
            deliver(
                title: stale.title,
                body: stale.body,
                inFlightKey: "stale",
                dedupeValues: [path: Self.todayKey(now)],
                config: config
            )
        }

        let percentLimit = QuotaStyle.percent(min(100, max(0, config.double("notifications.percent", default: 20))))
        let subscriptionDays = config.int("notifications.subscriptionDays", default: 3)
        let credentialDays = config.int("notifications.credentialDays", default: 60)
        let accounts = AccountStore(config: config)

        for provider in snapshot.providers where provider.status != "disabled" && provider.cached != true {
            let stamp = FlexibleDateParser.date(from: provider.sampledAt ?? snapshot.sampledAt ?? snapshot.updatedAt)
            if provider.isUsable, let stamp, now.timeIntervalSince(stamp) >= Double(max(1, config.int("notifications.staleHours", default: 12))) * 3600 { continue }
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
            }

            // 3) 低额度 / 低余额（原有行为）。
            guard let (kind, message) = Self.quotaAlert(for: provider, percentLimit: percentLimit) else { continue }
            let path = Self.quotaDedupePath(provider.id, account: provider.localAccountID ?? account?.id)
            guard !hasNotified(path, config: config) else { continue }
            let inFlightKey = path
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

    func sendTest(completion: ((Bool) -> Void)? = nil) {
        deliver(title: "Agent 额度", body: "这是一条低额度通知测试。", inFlightKey: nil, dedupeValues: [:], config: nil, completion: completion)
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

    static func quotaDedupePath(_ providerID: String, account: String? = nil) -> String {
        if let account, !account.isEmpty, account != AccountStore.legacyAccountID {
            let key = Data(account.utf8).base64EncodedString()
            return "notifications.accountQuota." + providerID + "." + key
        }
        return "notifications.last." + providerID
    }

    /// 快照超过 `staleHours` 未更新时返回提醒；未过期返回 nil。
    static func stalenessMessage(
        snapshot: QuotaSnapshot,
        staleHours: Int,
        now: Date = Date()
    ) -> (title: String, body: String)? {
        let cutoff = now.addingTimeInterval(-Double(max(1, staleHours)) * 3600)
        let stale = snapshot.providers.filter {
            guard $0.isUsable, let date = FlexibleDateParser.date(from: $0.sampledAt ?? snapshot.sampledAt ?? snapshot.updatedAt) else { return false }
            return date <= cutoff
        }
        guard !stale.isEmpty else { return nil }
        return ("额度数据已过期", stale.map(\.name).joined(separator: "、") + " 已超过 \(max(1, staleHours)) 小时没有成功更新")

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

    private func deliver(
        title: String,
        body: String,
        inFlightKey: String?,
        dedupeValues: [String: String],
        config: ConfigStore?,
        completion: ((Bool) -> Void)? = nil
    ) {
        submit(title, body) { [weak self] accepted in
            if let inFlightKey { self?.inFlight.remove(inFlightKey) }
            if accepted, let config, !dedupeValues.isEmpty {
                for (path, value) in dedupeValues { config.set(path, value) }
                try? config.save()
            }
            completion?(accepted)
        }
    }

    private static func submitToSystem(title: String, body: String, completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "low-quota-" + UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in DispatchQueue.main.async { completion(error == nil) } }
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

    static func quotaAlert(for provider: ProviderStatus, percentLimit: Double) -> (String, String)? {
        guard provider.isUsable, provider.cached != true else { return nil }
        var percent: (String, String)?
        if let window = provider.lowestWindow, let left = window.remainingPercent, left <= percentLimit {
            percent = ("percent", "\(window.label)剩 \(quotaPercentText(left))%（提醒线 \(Int(percentLimit))%）")
        }
        if let credit = provider.creditMetric, let value = QuotaStyle.remainingNumber(provider),
           percent == nil || provider.riskMetric?.kind == "credit" {
            let amount = provider.valueText(credit) + (credit.currency?.isEmpty != false ? " " + provider.pointUnit : "")
            let unit = credit.currency.flatMap { $0.isEmpty ? nil : $0 } ?? provider.pointUnit
            if value <= 0 {
                return ("credit", "剩余 \(amount)（额度已耗尽 · \(unit)）")
            }
            if let limit = QuotaStyle.threshold(for: provider), limit > 0, value <= limit {
                return ("credit", "剩余 \(amount)（提醒线 \(limit.formatted()) \(unit)）")
            }
        }
        return percent
    }
}
