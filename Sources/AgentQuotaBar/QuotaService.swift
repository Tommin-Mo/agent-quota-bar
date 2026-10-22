import Foundation

enum QuotaError: LocalizedError {
    case nodeMissing
    case collectorMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .nodeMissing:
            return "未找到 Node.js，请先安装（brew install node）"
        case .collectorMissing:
            return "缺少 collector.js，请重新构建 App"
        case .failed(let message):
            return message
        }
    }
}

/// 负责调度 Node collector 并把结果交给 UI。
final class QuotaService {
    private(set) var snapshot: QuotaSnapshot?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isOffline = false

    let config = ConfigStore()
    var onChange: (() -> Void)?
    private let cacheURL: URL

    init() {
        cacheURL = config.url.deletingLastPathComponent().appendingPathComponent("last-snapshot.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(QuotaSnapshot.self, from: data),
           !cached.providers.isEmpty {
            snapshot = cached
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()

        let configPath = config.url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.runCollector(configPath: configPath) }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let incoming):
                    self.apply(incoming)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    /// 保留最后一次可用数据；网络错误不覆盖旧快照。
    private func apply(_ incoming: QuotaSnapshot) {
        let active = incoming.providers.filter { $0.status != "disabled" }
        let networkErrors = active.filter(Self.isNetworkProvider)
        let allNetwork = !active.isEmpty && networkErrors.count == active.count

        if allNetwork {
            isOffline = true
            errorMessage = nil
            // 有缓存就继续展示缓存，连时间都不改；没有缓存则保持空状态。
            return
        }

        var providers = incoming.providers
        if !networkErrors.isEmpty, let old = snapshot {
            providers = providers.map { provider in
                guard Self.isNetworkProvider(provider),
                      let previous = old.providers.first(where: { $0.id == provider.id })
                else { return provider }
                return previous
            }
        }

        let merged = QuotaSnapshot(
            schema: incoming.schema,
            updatedAt: incoming.updatedAt,
            providers: providers
        )
        snapshot = merged
        isOffline = !networkErrors.isEmpty
        errorMessage = nil
        saveCache(merged)
    }

    private func saveCache(_ snapshot: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    private static func isNetworkProvider(_ provider: ProviderStatus) -> Bool {
        guard provider.status == "error" else { return false }
        let text = (provider.error ?? "").lowercased()
        let patterns = [
            "could not resolve host", "network is unreachable", "no route to host",
            "failed to connect", "connection refused", "network request failed",
            "curl: (5)", "curl: (6)", "curl: (7)", "curl: (28)", "curl: (35)",
            "could not resolve proxy", "network is down", "timed out", "timeout",
            "ssl_error", "ssl_connect", "certificate",
        ]
        return patterns.contains { text.contains($0) }
    }

    /// 单独验证某一家（配置窗口里用）。
    func verify(provider: String, completion: @escaping (Result<ProviderStatus, Error>) -> Void) {
        let configPath = config.url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.runCollector(configPath: configPath, only: provider) }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    if let status = snapshot.providers.first {
                        completion(.success(status))
                    } else {
                        completion(.failure(QuotaError.failed("没有返回 \(provider) 的结果")))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// 执行 Trae / WorkBuddy 每日签到。
    func runCheckin(completion: @escaping (Result<CheckinReport, Error>) -> Void) {
        let configPath = config.url.path
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Self.runCheckinProcess(configPath: configPath) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 子进程

    private static func runCollector(configPath: String, only: String? = nil) throws -> QuotaSnapshot {
        let process = Process()
        let script = try findCollectorScript()
        var arguments = [script]
        if let only { arguments.append("--only=\(only)") }

        if let node = findNode() {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node"] + arguments
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["AGENT_QUOTA_CONFIG"] = configPath
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw QuotaError.failed("无法启动 collector：\(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 100, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        log("collector exit=\(process.terminationStatus) stdout=\(outData.count)B stderr=\(errData.count)B script=\(process.arguments?.first ?? "?") node=\(process.executableURL?.path ?? "?")")
        if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
            log("collector stderr: \(errText.prefix(500))")
        }
        if let outText = String(data: outData, encoding: .utf8) {
            log("collector stdout: \(outText.prefix(200))")
        }

        do {
            return try JSONDecoder().decode(QuotaSnapshot.self, from: outData)
        } catch {
            log("decode failed: \(error)")
        }
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw QuotaError.failed(stderr.isEmpty ? "collector 没有返回可解析的数据" : stderr)
    }

    private static func runCheckinProcess(configPath: String) throws -> CheckinReport {
        let process = Process()
        let script = try findCollectorScript()
        var arguments = [script, "--checkin", "--only=trae,workbuddy"]

        if let node = findNode() {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node"] + arguments
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["AGENT_QUOTA_CONFIG"] = configPath
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw QuotaError.failed("无法启动签到：\(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        log("checkin exit=\(process.terminationStatus) stdout=\(outData.count)B stderr=\(errData.count)B")
        do {
            return try JSONDecoder().decode(CheckinReport.self, from: outData)
        } catch {
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let firstLine = stderr
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            throw QuotaError.failed(firstLine.isEmpty ? "签到没有返回可解析的数据" : String(firstLine.prefix(200)))
        }
    }

    private static func findNode() -> String? {
        ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findCollectorScript() throws -> String {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let custom = ProcessInfo.processInfo.environment["AGENT_QUOTA_COLLECTOR"] {
            candidates.append(custom)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("collector.js").path {
            candidates.append(resource)
        }
        candidates.append(fileManager.currentDirectoryPath + "/collector/collector.js")

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<4 {
            candidates.append(directory.appendingPathComponent("collector/collector.js").path)
            directory = directory.deletingLastPathComponent()
        }

        if let found = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
            return found
        }
        throw QuotaError.collectorMissing
    }
}
