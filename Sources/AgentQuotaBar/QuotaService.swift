import Foundation

enum QuotaError: LocalizedError {
    case nodeMissing
    case collectorMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .nodeMissing:
            return "未找到 Node.js，请先安装（brew install node / nvm install --lts）"
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
        refresh(only: nil)
    }

    /// `only` 可以是逗号分隔的 provider 列表（如 "deepseek" 或 "deepseek,trae"）。
    /// 定向刷新只合并对应 provider，不覆盖其他数据。
    func refresh(only: String?) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()

        let configPath = config.url.path
        let onlyIDs = Self.providerIDs(from: only)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.runCollector(configPath: configPath, only: onlyIDs) }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let incoming):
                    self.apply(incoming, only: onlyIDs)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    /// 保留最后一次可用数据；网络错误不覆盖旧快照。
    ///
    /// 离线（`isOffline`）只在“所有启用的 provider 都因网络错误失败”时成立；
    /// 部分失败时保留成功 provider 的新数据，并给失败的 provider 留 error 行。
    private func apply(_ incoming: QuotaSnapshot, only: [String]? = nil) {
        // 未配置的 provider 不参与“是否整体离线”的判断；否则新装用户只配了
        // DeepSeek 时，离线会被 4 个 unconfigured 行稀释成“在线”。
        let incomingRelevant = incoming.providers.filter {
            $0.status != "disabled" && $0.status != "unconfigured"
        }
        let allIncomingNetworkFailed = !incomingRelevant.isEmpty
            && incomingRelevant.allSatisfy { $0.status == "error" && Self.isNetworkProvider($0) }

        if only != nil {
            // 定向刷新：网络掉线不能凭单个 provider 判定全局离线，
            // 也不要用错误行盖掉缓存里的可用数据。
            if allIncomingNetworkFailed {
                isOffline = true
                errorMessage = nil
                return
            }

            var providers = incoming.providers
            if let old = snapshot {
                // 定向刷新：替换目标 provider，其余保持原样（不会因子集响应丢掉其他家数据）。
                var mergedProviders = old.providers
                for provider in incoming.providers {
                    if let index = mergedProviders.firstIndex(where: { $0.id == provider.id }) {
                        mergedProviders[index] = provider
                    } else {
                        mergedProviders.append(provider)
                    }
                }
                providers = mergedProviders
            }

            let merged = QuotaSnapshot(
                schema: incoming.schema,
                updatedAt: incoming.updatedAt,
                sampledAt: incoming.sampledAt,
                providers: providers
            )
            snapshot = merged
            // 定向采集成功说明网络可用，不再处于“全部 provider 网络失败”的离线状态。
            isOffline = false
            errorMessage = nil
            UsageTracker.shared.record(snapshot: merged, only: Set(only ?? []))
            saveCache(merged)
            return
        }

        if allIncomingNetworkFailed {
            // 整体离线：保留上次数据、连时间都不改。
            isOffline = true
            errorMessage = nil
            return
        }

        isOffline = false
        errorMessage = nil
        let merged = QuotaSnapshot(
            schema: incoming.schema,
            updatedAt: incoming.updatedAt,
            sampledAt: incoming.sampledAt,
            providers: incoming.providers
        )
        snapshot = merged
        UsageTracker.shared.record(snapshot: merged)
        saveCache(merged)
    }

    private func saveCache(_ snapshot: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    private static func providerIDs(from only: String?) -> [String]? {
        guard let only else { return nil }
        let ids = only
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ids.isEmpty ? nil : ids
    }

    private static func isNetworkProvider(_ provider: ProviderStatus) -> Bool {
        guard provider.status == "error" else { return false }
        let text = (provider.error ?? "").lowercased()
        let patterns = [
            "could not resolve host", "network is unreachable", "no route to host",
            "failed to connect", "connection refused", "network request failed",
            "curl: (5)", "curl: (6)", "curl: (7)", "curl: (28)", "curl: (35)",
            "could not resolve proxy", "network is down", "timed out", "timeout",
            "etimedout", "econnreset", "enotfound", "eai_again",
            "ssl_error", "ssl_connect", "certificate",
        ]
        return patterns.contains { text.contains($0) }
    }

    /// 单独验证某一家（配置窗口里用）。
    func verify(provider: String, completion: @escaping (Result<ProviderStatus, Error>) -> Void) {
        let configPath = config.url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.runCollector(configPath: configPath, only: [provider]) }
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

    /// 只抓取指定 provider（`only` 为空时抓全部）。
    static func fetchSnapshot(configPath: String, only: [String]? = nil) throws -> QuotaSnapshot {
        try runCollector(configPath: configPath, only: only)
    }

    private static func runCollector(configPath: String, only: [String]? = nil) throws -> QuotaSnapshot {
        let process = Process()
        let script = try findCollectorScript()
        var arguments = [script]
        if let only, !only.isEmpty {
            arguments.append("--only=\(only.joined(separator: ","))")
        }

        let node = try findNode()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = arguments

        var environment = makeEnvironment(configPath: configPath)
        // 把 node 所在目录放到 PATH 最前，collector 里若有子进程也能找到同一套 Node。
        let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            cachedNodePath = nil
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
        let arguments = [script, "--checkin", "--only=trae,workbuddy"]

        let node = try findNode()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = arguments

        var environment = makeEnvironment(configPath: configPath)
        let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "")
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

    private static func makeEnvironment(configPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["AGENT_QUOTA_CONFIG"] = configPath
        return environment
    }

    // MARK: - Node 发现

    /// 依次查找 Homebrew / 系统 / nvm / volta / asdf / fnm / 本地目录里的 node。
    /// 找不到时抛 `nodeMissing`，不再回退到 `/usr/bin/env node` 让 stderr 变成看不懂的原始错误。
    private static func findNode() throws -> String {
        if let cached = cachedNodePath { return cached }
        let executable = locateNode()
        guard let executable else { throw QuotaError.nodeMissing }
        cachedNodePath = executable
        return executable
    }

    private static var cachedNodePath: String?

    private static func locateNode() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        var candidates: [String] = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "/opt/local/bin/node",
        ]

        // 环境变量里的 NODE_BINARY / NVM_BIN（从终端启动 App 时常见）。
        if let binary = ProcessInfo.processInfo.environment["NODE_BINARY"], !binary.isEmpty {
            candidates.insert(binary, at: 0)
        }
        if let nvmBin = ProcessInfo.processInfo.environment["NVM_BIN"], !nvmBin.isEmpty {
            candidates.insert(nvmBin + "/node", at: 0)
        }

        // PATH 里已有的 node（覆盖 volta/asdf shim、用户自定义 PATH）。
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(String(directory) + "/node")
            }
        }

        // nvm: ~/.nvm/versions/node/vX.Y.Z/bin/node，取版本号最大的。
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        candidates.append(contentsOf: versionedNodePaths(root: nvmRoot, suffix: "bin/node"))

        // fnm
        candidates.append(contentsOf: versionedNodePaths(
            root: home.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true),
            suffix: "installation/bin/node"
        ))
        candidates.append(contentsOf: versionedNodePaths(
            root: home.appendingPathComponent("Library/Application Support/fnm/node-versions", isDirectory: true),
            suffix: "installation/bin/node"
        ))

        // asdf
        candidates.append(home.appendingPathComponent(".asdf/shims/node").path)
        candidates.append(contentsOf: versionedNodePaths(
            root: home.appendingPathComponent(".asdf/installs/nodejs", isDirectory: true),
            suffix: "bin/node"
        ))

        // volta / 用户本地安装
        candidates.append(home.appendingPathComponent(".volta/bin/node").path)
        candidates.append(home.appendingPathComponent("n/bin/node").path)
        candidates.append(home.appendingPathComponent("bin/node").path)

        // 最后才用系统 PATH 查找（GUI 启动时 PATH 很短，但可能仍命中）。
        if let found = whichNode() {
            candidates.append(found)
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// 列出 root 下所有版本目录，按版本号从大到小拼接 `<version>/<suffix>`。
    private static func versionedNodePaths(root: URL, suffix: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let sorted = entries.sorted { lhs, rhs in
            lhs.lastPathComponent.compare(
                rhs.lastPathComponent,
                options: [.numeric, .caseInsensitive]
            ) == .orderedDescending
        }
        return sorted.map { $0.appendingPathComponent(suffix).path }
    }

    private static func whichNode() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["node"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
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
