import Foundation

/// 读写 ~/.config/agent-quota/config.json。
/// 菜单栏 App 与 Node collector 共用同一份配置，字段保持宽松（未知字段原样保留）。
final class ConfigStore {
    static let defaultConfig: [String: Any] = [
        "refreshSeconds": 300,
        "menuBarMode": "auto",
        "menuBarIconScale": 1.25,
        "providerOrder": ["codex", "deepseek", "opencode", "trae", "workbuddy"],
        "hiddenProviders": [],
        "appearance": "system",
        "style": [
            "warningPercent": 45,
            "dangerPercent": 20,
            "healthyColor": "#14B8A6",
            "warningColor": "#F59E0B",
            "dangerColor": "#DC2626",
            "thresholds": ["trae": 200, "workbuddy": 500, "deepseek": 5],
        ],
        "notifications": ["enabled": false, "percent": 20],
        "checkin": [
            "auto": true,
            "hour": 9,
            "lastDate": "",
            "lastSummary": "",
            "lastAttempt": "",
            "workbuddyStreak": 0,
        ],
        "proxy": "auto",
        "proxyHosts": ["chatgpt.com", "auth.openai.com"],
        "providers": [
            "codex": ["enabled": true],
            "deepseek": ["enabled": true, "apiKey": ""],
            "opencode": ["enabled": true, "apiKey": "", "cookie": "", "workspaceId": ""],
            "trae": ["enabled": true, "edition": "cn"],
            "workbuddy": ["enabled": true, "token": "", "uid": ""],
        ],
    ]

    let url: URL
    private(set) var values: [String: Any]

    init() {
        if let custom = ProcessInfo.processInfo.environment["AGENT_QUOTA_CONFIG"] {
            url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/agent-quota/config.json")
        }
        values = Self.load(from: url) ?? Self.defaultConfig
        if !FileManager.default.fileExists(atPath: url.path) {
            try? save()
        }
    }

    private static func load(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    func reload() {
        if let loaded = Self.load(from: url) {
            values = loaded
        }
    }

    func save() throws {
        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - 读取

    func string(_ path: String, default fallback: String = "") -> String {
        (read(path) as? String) ?? fallback
    }

    func int(_ path: String, default fallback: Int) -> Int {
        if let number = read(path) as? NSNumber { return number.intValue }
        if let text = read(path) as? String, let number = Int(text) { return number }
        return fallback
    }

    func double(_ path: String, default fallback: Double) -> Double {
        if let number = read(path) as? NSNumber { return number.doubleValue }
        if let text = read(path) as? String, let number = Double(text) { return number }
        return fallback
    }

    func stringArray(_ path: String) -> [String] {
        (read(path) as? [String]) ?? []
    }

    func bool(_ path: String, default fallback: Bool) -> Bool {
        (read(path) as? Bool) ?? fallback
    }

    var refreshSeconds: Int {
        max(30, int("refreshSeconds", default: 300))
    }

    // MARK: - 写入

    func set(_ path: String, _ value: Any) {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return }
        let last = parts.removeLast()
        var cursor = values
        var stack: [(String, [String: Any])] = []

        for part in parts {
            stack.append((part, cursor))
            if let next = cursor[part] as? [String: Any] {
                cursor = next
            } else {
                cursor = [:]
            }
        }
        cursor[last] = value
        // 从最内层往外写回
        var rebuilt = cursor
        for (key, parent) in stack.reversed() {
            var updated = parent
            updated[key] = rebuilt
            rebuilt = updated
        }
        values = rebuilt
    }

    private func read(_ path: String) -> Any? {
        var cursor: Any = values
        for part in path.split(separator: ".") {
            guard let dict = cursor as? [String: Any], let next = dict[String(part)] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }
}
