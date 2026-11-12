import AppKit
import Foundation

/// 由 LaunchAgent 调用：App 没开着时也记录余额/积分累计消费。
///
/// 只抓取真正需要“高频累计”的 provider，避免每 5 分钟跑一遍 5 家全量采集；
/// App 正在运行时跳过（App 自己的 60s 深采已经覆盖），减少重复请求与并发写入。
enum UsageSampler {
    static let label = "com.agentquota.usage"
    /// 后台采样只关心这三家的消费累计。
    static let sampledProviderIDs = ["deepseek", "trae", "workbuddy"]

    static func run() {
        guard !guiAppIsRunning() else { return }
        // 不用 ConfigStore()：它的 init 会“修复”损坏配置并写默认值，
        // 后台进程抢在 App 前面跑时会让用户看不到损坏提示。
        guard let snapshot = try? QuotaService.fetchSnapshot(
            configPath: ConfigStore.defaultURL.path,
            only: sampledProviderIDs
        ) else { return }
        UsageTracker.shared.record(snapshot: snapshot, only: Set(sampledProviderIDs))
    }

    static func installIfNeeded() {
        guard let executable = Bundle.main.executableURL else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent(".config/agent-quota", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("usage.log").path
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

        let payload: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--usage-sample"],
            "StartInterval": 300,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "ThrottleInterval": 60,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        LaunchAgentInstaller.install(label: label, payload: payload, plistURL: plistURL)
    }

    static func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        LaunchAgentInstaller.uninstall(label: label, plistURL: plistURL)
    }

    /// 菜单栏 App 正在运行（同一个 bundle id、但不是当前采样进程）就跳过采样。
    private static func guiAppIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() && $0.activationPolicy != .prohibited }
    }
}

/// LaunchAgent 的公共安装逻辑：内容没变且已加载时完全不动，避免每次启动都
/// 重写 plist + bootout/bootstrap 阻塞调用线程。
enum LaunchAgentInstaller {
    static func install(label: String, payload: [String: Any], plistURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        ) else { return }

        let unchanged = plistMatches(existing: try? Data(contentsOf: plistURL), payload: payload)
        if !unchanged {
            try? data.write(to: plistURL, options: .atomic)
        } else if isLoaded(label) {
            return
        }

        let uid = getuid()
        launchctl(["bootout", "gui/\(uid)/\(label)"])
        launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
    }

    /// 按内容比较 plist，而不是按序列化字节：Swift 字典的键顺序每个进程都可能不同，
    /// 直接比字节会导致每次启动都重写并被判定为“有变化”。
    static func plistMatches(existing data: Data?, payload: [String: Any]) -> Bool {
        guard let data,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return false
        }
        return (dictionary as NSDictionary).isEqual(payload as NSDictionary)
    }

    static func uninstall(label: String, plistURL: URL) {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func isLoaded(_ label: String) -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
