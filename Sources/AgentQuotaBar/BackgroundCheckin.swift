import Foundation

/// 用 LaunchAgent 把签到放到真正的后台：App 没开着也会每小时检查一次，
/// 到设定的签到时间且当天没签时才真正发请求。
enum BackgroundCheckin {
    static let label = "com.agentquota.checkin"

    static func installIfNeeded() {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("checkin-background.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent(".config/agent-quota", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("checkin.log").path
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

        let payload: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/zsh", script.path],
            "StartCalendarInterval": ["Minute": 0],
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
}
