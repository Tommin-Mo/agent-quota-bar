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

        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("\(label).plist")

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

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        ) else { return }
        try? data.write(to: plist, options: .atomic)

        let uid = getuid()
        launchctl(["bootout", "gui/\(uid)/\(label)"])
        launchctl(["bootstrap", "gui/\(uid)", plist.path])
    }

    static func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
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
