import Foundation

/// 由 LaunchAgent 调用：App 没开着时也记录 DeepSeek 余额/积分累计消费。
enum UsageSampler {
    static let label = "com.agentquota.usage"

    static func run() {
        let config = ConfigStore()
        guard let snapshot = try? QuotaService.fetchSnapshot(configPath: config.url.path) else { return }
        UsageTracker.shared.record(snapshot: snapshot)
    }

    static func installIfNeeded() {
        guard let executable = Bundle.main.executableURL else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent(".config/agent-quota", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("usage.log").path

        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("\(label).plist")

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
