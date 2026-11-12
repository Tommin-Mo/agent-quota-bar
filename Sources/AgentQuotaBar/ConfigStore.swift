import Foundation

/// 读写 ~/.config/agent-quota/config.json。
/// 菜单栏 App 与 Node collector 共用同一份配置，字段保持宽松（未知字段原样保留）。
///
/// 写入策略：保存时重新读取磁盘上的最新配置，只覆盖本进程 `set()` 过的键。
/// 这样不会用启动时的旧字典把 collector / 后台签到写入的状态（checkin.lastDate 等）抹掉。
/// 配置文件损坏时先备份再重建，绝不静默用默认值覆盖。
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

    static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AGENT_QUOTA_CONFIG"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-quota/config.json")
    }

    let url: URL
    private(set) var values: [String: Any]
    /// 本进程修改过、尚未落盘的键（点分路径）。
    private var dirtyKeys: Set<String> = []
    /// 读取配置失败的原因（例如文件损坏），供 UI 提示一次。
    private(set) var loadError: String?
    /// 最近一次保存失败的原因。
    private(set) var lastSaveError: String?
    /// 损坏的配置文件被备份到的位置。
    private(set) var corruptBackupURL: URL?

    init() {
        url = Self.defaultURL

        let fileExists = FileManager.default.fileExists(atPath: url.path)
        if let loaded = Self.readJSON(at: url) {
            values = loaded
        } else if fileExists {
            // 文件存在却无法解析：先备份，再以默认值重建，避免静默覆盖用户数据。
            values = Self.defaultConfig
            if let backup = Self.backupCorruptFile(at: url) {
                corruptBackupURL = backup
                loadError = "配置文件格式损坏，已备份到 \(backup.path) 并重建默认配置。"
            } else {
                loadError = "配置文件格式损坏且无法备份；为避免覆盖，本次不会写回默认值。"
            }
        } else {
            values = Self.defaultConfig
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try save()
            } catch {
                lastSaveError = error.localizedDescription
            }
        }
    }

    // MARK: - 文件读写

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// 把无法解析的配置文件移走（保留现场），返回备份路径；失败返回 nil。
    private static func backupCorruptFile(at url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        var destination = url.appendingPathExtension("corrupt-\(stamp)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = url.appendingPathExtension("corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// 重新读取磁盘配置；失败时保留内存中的值并记录错误。
    /// 尚未保存的本地修改会覆盖到新读入的内容上，不会被丢掉。
    @discardableResult
    func reload() -> Bool {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        guard fileExists else { return false }
        guard var loaded = Self.readJSON(at: url) else {
            loadError = "配置文件格式损坏，保留内存中的配置。"
            return false
        }
        for path in dirtyKeys {
            if let value = Self.readValue(at: path, in: values) {
                Self.setValue(value, at: path, in: &loaded)
            }
        }
        values = loaded
        loadError = nil
        return true
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var onDisk: [String: Any]?
        if FileManager.default.fileExists(atPath: url.path) {
            if let parsed = Self.readJSON(at: url) {
                onDisk = parsed
            } else if let backup = Self.backupCorruptFile(at: url) {
                corruptBackupURL = backup
                loadError = "配置文件格式损坏，已备份到 \(backup.path)。"
            } else {
                let message = "配置文件格式损坏且无法备份，为避免覆盖已停止写入。"
                lastSaveError = message
                throw ConfigStoreError.corruptFileNotBackedUp
            }
        }

        // 磁盘上有可用配置时只合并改动过的键；首次创建则整份写入。
        var merged: [String: Any]
        if let onDisk {
            merged = onDisk
            for path in dirtyKeys {
                guard let value = Self.readValue(at: path, in: values) else { continue }
                Self.setValue(value, at: path, in: &merged)
            }
        } else {
            merged = values
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            lastSaveError = error.localizedDescription
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        values = merged
        dirtyKeys.removeAll()
        lastSaveError = nil
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
        guard !path.isEmpty else { return }
        Self.setValue(value, at: path, in: &values)
        dirtyKeys.insert(path)
    }

    private func read(_ path: String) -> Any? {
        Self.readValue(at: path, in: values)
    }

    // MARK: - 点分路径工具

    private static func setValue(_ value: Any, at path: String, in dictionary: inout [String: Any]) {
        let parts = path.split(separator: ".").map(String.init)
        setValue(value, at: parts, in: &dictionary)
    }

    private static func setValue(_ value: Any, at parts: [String], in dictionary: inout [String: Any]) {
        guard let head = parts.first else { return }
        if parts.count == 1 {
            dictionary[head] = value
            return
        }
        var child = dictionary[head] as? [String: Any] ?? [:]
        setValue(value, at: Array(parts.dropFirst()), in: &child)
        dictionary[head] = child
    }

    private static func readValue(at path: String, in dictionary: [String: Any]) -> Any? {
        var cursor: Any = dictionary
        for part in path.split(separator: ".") {
            guard let dict = cursor as? [String: Any], let next = dict[String(part)] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }
}

enum ConfigStoreError: LocalizedError {
    case corruptFileNotBackedUp

    var errorDescription: String? {
        switch self {
        case .corruptFileNotBackedUp:
            return "配置文件格式损坏且无法备份，为避免覆盖已停止写入。"
        }
    }
}
