import AppKit
import Foundation

/// 最近使用的来源之一：前台 App。
/// CodexBar 这类工具就是用 `NSWorkspace.frontmostApplication` 做 provider 切换，
/// 比单纯看额度变化可靠得多。
final class FrontmostProviderMonitor {
    static var bundleMap: [String: String] {
        Dictionary(uniqueKeysWithValues: ProviderRegistry.all.flatMap { provider in
            provider.nativeAppBundleIDs.map { ($0, provider.id) }
        })
    }

    private var observers: [NSObjectProtocol] = []
    private(set) var currentProvider: String?
    var onChange: ((String?) -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    func refresh() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let provider = bundleID.flatMap { Self.bundleMap[$0] }
        guard provider != currentProvider else { return }
        currentProvider = provider
        onChange?(provider)
    }
}

/// 读取 OpenCode 本地的真实会话时间。
/// 不用 db mtime：OpenCode 后台服务、模型目录同步都会持续写文件；
/// `session_v2.time_updated` / `session_message.time_created` 才是真正的会话活动。
enum OpenCodeActivity {
    static func latestSessionDate() -> Date? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let database = dataHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }

        let sql = """
        SELECT COALESCE(MAX(ts), 0) FROM (
          SELECT MAX(time_updated) AS ts FROM session_v2
          UNION ALL
          SELECT MAX(time_created) FROM session_message
        );
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Double(raw), value > 0 else { return nil }
            // OpenCode 当前使用毫秒时间戳；兼容未来/旧版本的秒级值。
            let seconds = value > 1_000_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        } catch {
            return nil
        }
    }
}
