import Foundation

enum AccountStoreError: LocalizedError {
    case accountNotFound(String)
    case invalidProvider(String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound(let id):
            return "找不到账号 \(id)"
        case .invalidProvider(let provider):
            return "未知 provider：\(provider)"
        }
    }
}

/// 多账号配置。
///
/// schema（每个 provider 内）：
/// ```json
/// "providers": {
///   "opencode": {
///     "enabled": true,
///     "activeAccount": "work",
///     "accounts": [
///       { "id": "work", "label": "Work", "account": "me@x.com",
///         "credentials": { "apiKey": "…", "cookie": "…", "workspaceId": "…" },
///         "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "…", "lastUsedAt": "…" }
///     ]
///   }
/// }
/// ```
///
/// 向后兼容：没有 `accounts` 数组时，把旧的扁平字段（`providers.<id>.apiKey`、
/// `.cookie`、`.token`…）当成一个隐式“默认账号”（`isLegacy == true`）。读取不写配置；
/// 只有显式调用写方法时才会创建 `accounts` 数组。`activate` 会把选中账号的凭据镜像回
/// 扁平字段，让尚未支持多账号的 collector 继续工作。
final class AccountStore {
    static let legacyAccountID = "default"
    static let legacyAccountLabel = "默认账号"

    /// 每家 provider 的凭据字段；`edition` 这类账号相关但非密钥的字段也一并保存。
    static let credentialKeysByProvider: [String: [String]] = [
        "codex": ["authPath", "codexHome"],
        "deepseek": ["apiKey"],
        "opencode": ["apiKey", "cookie", "workspaceId"],
        "trae": ["edition"],
        "workbuddy": ["token", "uid"],
    ]

    private let config: ConfigStore

    init(config: ConfigStore = ConfigStore()) {
        self.config = config
    }

    // MARK: - 读取

    func supportsMultipleAccounts(for provider: String) -> Bool {
        ProviderRegistry.provider(withID: provider)?.supportsMultipleAccounts ?? false
    }

    /// 已配置账号；没有持久账号时返回从旧扁平字段合成的默认账号（可能为空数组）。
    func accounts(for provider: String) -> [ProviderAccount] {
        let stored = storedAccounts(for: provider)
        if !stored.isEmpty { return stored.map { parse($0, provider: provider) } }
        return legacyAccount(for: provider).map { [$0] } ?? []
    }

    func accountsByProvider() -> [String: [ProviderAccount]] {
        let ids = Set(ProviderRegistry.ids + storedProviderIDs())
        var result: [String: [ProviderAccount]] = [:]
        for id in ids {
            let list = accounts(for: id)
            if !list.isEmpty { result[id] = list }
        }
        return result
    }

    func activeAccountID(for provider: String) -> String? {
        activeAccount(for: provider)?.id
    }

    func activeAccount(for provider: String) -> ProviderAccount? {
        let all = accounts(for: provider)
        guard !all.isEmpty else { return nil }
        let storedID = config.string("providers.\(provider).activeAccount")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedID.isEmpty, let matched = all.first(where: { $0.id == storedID }) {
            return matched
        }
        return all.first
    }

    /// 活动账号的凭据；持久账号缺少某个键时返回 nil（不会偷偷混用旧账号的密钥）。
    func credential(_ key: String, for provider: String) -> String? {
        guard let active = activeAccount(for: provider) else { return nil }
        if let value = active.credentials[key], !value.isEmpty {
            return value
        }
        if active.isLegacy {
            let value = config.string("providers.\(provider).\(key)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    func credentials(for provider: String) -> [String: String] {
        activeAccount(for: provider)?.credentials ?? [:]
    }

    /// 从旧扁平字段合成的账号；没有任何账号字段时返回 nil。
    func legacyAccount(for provider: String) -> ProviderAccount? {
        let prefix = "providers.\(provider)"
        var credentials: [String: String] = [:]
        for key in Self.credentialKeys(for: provider) {
            let value = config.string("\(prefix).\(key)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { credentials[key] = value }
        }
        let rawAccount = config.string("\(prefix).account")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credentials.isEmpty || !rawAccount.isEmpty else { return nil }
        return ProviderAccount(
            id: Self.legacyAccountID,
            label: Self.legacyAccountLabel,
            account: rawAccount.isEmpty ? nil : rawAccount,
            credentials: credentials,
            isLegacy: true
        )
    }

    /// 所有 provider 下、凭据更新时间早于 N 天的持久账号（供提醒/UI 使用）。
    func staleAccounts(olderThan days: Int, now: Date = Date()) -> [ProviderAccount] {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, days)) * 24 * 60 * 60)
        var result: [ProviderAccount] = []
        for (_, list) in accountsByProvider() {
            for account in list where !account.isLegacy {
                guard let updated = account.updatedDate else { continue }
                if updated < cutoff { result.append(account) }
            }
        }
        return result
    }

    // MARK: - 写入

    @discardableResult
    func setActiveAccount(_ id: String, for provider: String) throws -> ProviderAccount {
        let all = accounts(for: provider)
        guard let account = all.first(where: { $0.id == id }) else {
            throw AccountStoreError.accountNotFound(id)
        }
        guard !account.isLegacy else { return account }
        config.set("providers.\(provider).activeAccount", id)
        try config.save()
        return account
    }

    /// 选中账号，并把凭据镜像到扁平字段，兼容只读扁平配置的 collector。
    @discardableResult
    func activate(_ id: String, for provider: String, mirrorToLegacy: Bool = true) throws -> ProviderAccount {
        var account = try setActiveAccount(id, for: provider)
        guard !account.isLegacy else { return account }
        if mirrorToLegacy {
            mirror(account.credentials, for: provider)
        }
        touchLastUsed(account, for: provider)
        account.lastUsedAt = Self.timestamp()
        try config.save()
        return account
    }

    @discardableResult
    func addAccount(
        for provider: String,
        label: String,
        account: String? = nil,
        credentials: [String: String] = [:],
        id: String? = nil,
        makeActive: Bool = true
    ) throws -> ProviderAccount {
        guard ProviderRegistry.provider(withID: provider) != nil else {
            throw AccountStoreError.invalidProvider(provider)
        }
        var stored = storedAccounts(for: provider)
        var existingIDs = Set(stored.compactMap { $0["id"] as? String })

        // 首次创建账号数组时保留旧配置：把扁平字段落成一个 "default" 账号，避免丢失。
        if stored.isEmpty, let legacy = legacyAccount(for: provider) {
            stored.append(dict(from: legacy, provider: provider))
            existingIDs.insert(legacy.id)
        }

        let now = Self.timestamp()
        let accountID = Self.uniqueID(
            preferred: id ?? Self.makeID(label: label, account: account),
            existing: existingIDs
        )
        let normalizedCredentials = Self.normalized(credentials, provider: provider)
        let dict: [String: Any] = [
            "id": accountID,
            "label": label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? accountID : label,
            "account": account ?? "",
            "credentials": normalizedCredentials,
            "createdAt": now,
            "updatedAt": now,
        ]
        stored.append(dict)
        config.set("providers.\(provider).accounts", stored)
        if makeActive {
            config.set("providers.\(provider).activeAccount", accountID)
        }
        try config.save()
        if makeActive {
            mirror(normalizedCredentials, for: provider)
            try? config.save()
        }
        return parse(dict, provider: provider)
    }

    func updateAccount(_ account: ProviderAccount, for provider: String) throws {
        var stored = storedAccounts(for: provider)
        guard let index = stored.firstIndex(where: { ($0["id"] as? String) == account.id }) else {
            throw AccountStoreError.accountNotFound(account.id)
        }
        var dict = stored[index]
        // 只改已知字段，保留未来 collector 写入的未知键。
        dict["label"] = account.label
        dict["account"] = account.account ?? ""
        dict["credentials"] = Self.normalized(account.credentials, provider: provider)
        dict["updatedAt"] = Self.timestamp()
        stored[index] = dict
        config.set("providers.\(provider).accounts", stored)
        try config.save()
        if activeAccountID(for: provider) == account.id {
            mirror(account.credentials, for: provider)
            try? config.save()
        }
    }

    func removeAccount(withID id: String, for provider: String) throws {
        var stored = storedAccounts(for: provider)
        guard let index = stored.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw AccountStoreError.accountNotFound(id)
        }
        let wasActive = activeAccountID(for: provider) == id
        stored.remove(at: index)
        config.set("providers.\(provider).accounts", stored)

        if stored.isEmpty {
            // 删掉最后一个账号：清掉活动账号和扁平凭据，避免旧账号被重新合成回来。
            config.set("providers.\(provider).activeAccount", "")
            for key in Self.credentialKeys(for: provider) {
                config.set("providers.\(provider).\(key)", "")
            }
        } else if wasActive {
            let next = parse(stored[0], provider: provider)
            config.set("providers.\(provider).activeAccount", next.id)
            mirror(next.credentials, for: provider)
        }
        try config.save()
    }

    // MARK: - 解析 / 工具

    private func storedAccounts(for provider: String) -> [[String: Any]] {
        config.dictionaries("providers.\(provider).accounts")
    }

    private func storedProviderIDs() -> [String] {
        guard let providers = config.dictionary("providers") else { return [] }
        return Array(providers.keys)
    }

    private func parse(_ dict: [String: Any], provider: String) -> ProviderAccount {
        let label = (dict["label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = (id?.isEmpty == false ? id! : Self.makeID(label: label, account: dict["account"] as? String))

        var credentials: [String: String] = [:]
        if let nested = dict["credentials"] as? [String: Any] {
            for (key, value) in nested {
                credentials[key] = Self.stringValue(value)
            }
        }
        // 兼容把凭据直接平铺在账号对象里的写法。
        for key in Self.credentialKeys(for: provider) where credentials[key] == nil {
            if let value = dict[key] {
                credentials[key] = Self.stringValue(value)
            }
        }
        return ProviderAccount(
            id: resolvedID,
            label: label.isEmpty ? resolvedID : label,
            account: (dict["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            credentials: credentials,
            createdAt: dict["createdAt"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            lastUsedAt: dict["lastUsedAt"] as? String,
            isLegacy: false
        )
    }

    private func dict(from account: ProviderAccount, provider: String) -> [String: Any] {
        [
            "id": account.id,
            "label": account.label,
            "account": account.account ?? "",
            "credentials": Self.normalized(account.credentials, provider: provider),
            "createdAt": account.createdAt ?? Self.timestamp(),
            "updatedAt": account.updatedAt ?? Self.timestamp(),
        ]
    }

    /// 把选中账号凭据写回扁平字段（collector 兼容层）。
    private func mirror(_ credentials: [String: String], for provider: String) {
        for key in Self.credentialKeys(for: provider) {
            // edition 是 provider selector，不是账号密钥；账号没填时保留当前选择。
            if key == "edition", credentials[key] == nil { continue }
            config.set("providers.\(provider).\(key)", credentials[key] ?? "")
        }
    }

    private func touchLastUsed(_ account: ProviderAccount, for provider: String) {
        var stored = storedAccounts(for: provider)
        guard let index = stored.firstIndex(where: { ($0["id"] as? String) == account.id }) else { return }
        var dict = stored[index]
        dict["lastUsedAt"] = Self.timestamp()
        stored[index] = dict
        config.set("providers.\(provider).accounts", stored)
    }

    static func credentialKeys(for provider: String) -> [String] {
        credentialKeysByProvider[provider] ?? []
    }

    private static func normalized(_ credentials: [String: String], provider: String) -> [String: String] {
        let allowed = Set(credentialKeys(for: provider))
        var result: [String: String] = [:]
        for (key, value) in credentials {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 只保留已知字段，但也不丢弃其他字符串字段，方便未来扩展。
            if allowed.contains(key) || !key.isEmpty { result[key] = trimmed }
        }
        return result
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let bool as Bool: return bool ? "true" : "false"
        default: return ""
        }
    }

    private static func makeID(label: String, account: String?) -> String {
        let raw = "\(label)-\(account ?? "")"
        let slug = raw
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "account" : String(slug.prefix(48))
    }

    private static func uniqueID(preferred: String, existing: Set<String>) -> String {
        let base = preferred.isEmpty ? "account" : preferred
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter.internet.string(from: Date())
    }
}
