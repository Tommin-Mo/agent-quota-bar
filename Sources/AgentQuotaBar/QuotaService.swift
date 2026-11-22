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
    private var latestSnapshot: QuotaSnapshot?
    var snapshot: QuotaSnapshot? { latestSnapshot.map(currentAccounts) }

    private func currentAccounts(_ source: QuotaSnapshot) -> QuotaSnapshot {
        source.currentAccounts(in: config.dictionary("providers") ?? [:])
    }
    private var readingDoubao = false
    /// 外层 optional 表示“是否还有一次待处理请求”，内层保留原始 only。
    private var pendingOnly: String??
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isOffline = false

    let config = ConfigStore()
    var onChange: (() -> Void)?
    private let cacheURL: URL

    private let publishWidgets: Bool

    init(publishWidgets: Bool = true) {
        self.publishWidgets = publishWidgets
        cacheURL = config.url.deletingLastPathComponent().appendingPathComponent("last-snapshot.json")
        ensureMenuBarScaleModel()
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(QuotaSnapshot.self, from: data),
           !cached.providers.isEmpty {
            latestSnapshot = QuotaSnapshot(schema: cached.schema, updatedAt: cached.updatedAt, sampledAt: cached.sampledAt, providers: cached.providers.map { provider in
                var item = provider
                item.cached = true
                item.sampledAt = item.sampledAt ?? cached.sampledAt ?? cached.updatedAt
                return item
            })
            ProviderRegistry.update(from: cached.providers)
            publishWidgetSnapshot()
        }
    }

    /// 菜单栏图标大小以“用户当前的大小”为 1.00× 基准，
    /// 配置里只存相对系数，避免界面被绝对值 1.43/143% 这种数字绑死。
    var menuBarIconScaleFactor: Double {
        min(1.5, max(0.5, config.double("menuBarIconScaleFactor", default: 1.0)))
    }

    var effectiveMenuBarIconScale: CGFloat {
        let baseline = config.double("menuBarIconScaleBaseline", default: 1.43)
        return CGFloat(max(0.3, baseline * menuBarIconScaleFactor))
    }

    private func ensureMenuBarScaleModel() {
        guard config.double("menuBarIconScaleBaseline", default: 0) <= 0 else { return }
        let current = config.double("menuBarIconScale", default: 1.43)
        config.set("menuBarIconScaleBaseline", current > 0 ? current : 1.43)
        config.set("menuBarIconScaleFactor", 1.0)
        try? config.save()
    }

    func refresh() {
        refresh(only: nil)
    }

    /// `only` 可以是逗号分隔的 provider 列表（如 "deepseek" 或 "deepseek,trae"）。
    /// 定向刷新只合并对应 provider，不覆盖其他数据。
    func refresh(only: String?) {
        guard !isRefreshing else { pendingOnly = .some(only); onChange?(); publishWidgetSnapshot(); return }
        let configPath = config.url.path
        let requested = Self.providerIDs(from: only)
        // First-time system OCR model preparation can take much longer than a network poll.
        let separateReader = ProcessInfo.processInfo.environment["AGENT_QUOTA_COLLECTOR"] == nil
        if separateReader && (requested?.contains("doubao") ?? true) {
            refreshDoubao(configPath: configPath)
            if requested?.allSatisfy({ $0 == "doubao" }) == true { return }
        }
        let onlyIDs = separateReader ? requested?.filter { $0 != "doubao" } : requested
        isRefreshing = true
        onChange?()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.runCollector(configPath: configPath, only: onlyIDs, skipDoubao: separateReader) }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let incoming):
                    self.apply(incoming, only: onlyIDs, preserveDoubao: separateReader)
                case .failure(let error):
                    if let old = self.snapshot {
                        let rows = old.providers.map { source -> ProviderStatus in
                            guard (!separateReader || source.id != "doubao"), onlyIDs?.contains(source.id) ?? true else { return source }
                            var item = source
                            item.cached = true
                            item.sampledAt = item.sampledAt ?? old.sampledAt ?? old.updatedAt
                            return item
                        }
                        let cached = QuotaSnapshot(schema: old.schema, updatedAt: old.updatedAt, sampledAt: old.sampledAt, providers: rows)
                        self.latestSnapshot = cached
                        self.saveCache(cached)
                    }
                    self.errorMessage = error.localizedDescription
                }
                self.onChange?()
                if let pending = self.pendingOnly {
                    self.pendingOnly = nil
                    self.refresh(only: pending)
                }
            }
        }
    }

    private func refreshDoubao(configPath: String) {
        guard !readingDoubao else { return }
        readingDoubao = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = try? Self.runCollector(configPath: configPath, only: ["doubao"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingDoubao = false
                guard let result else { return }
                self.apply(result, only: ["doubao"])
                self.onChange?()
            }
        }
    }

    /// 保留最后一次可用数据；网络错误不覆盖旧快照。
    ///
    /// 离线（`isOffline`）只在“所有启用的 provider 都因网络错误失败”时成立；
    /// 部分失败时保留成功 provider 的新数据，并给失败的 provider 留 error 行。
    func apply(_ source: QuotaSnapshot, only: [String]? = nil, preserveDoubao: Bool = false) {
        let incoming = currentAccounts(source)
        guard !incoming.providers.isEmpty || source.providers.isEmpty else { return }
        // 未配置的 provider 不参与“是否整体离线”的判断；否则新装用户只配了
        // DeepSeek 时，离线会被 4 个 unconfigured 行稀释成“在线”。
        let incomingRelevant = incoming.providers.filter {
            $0.status != "disabled" && $0.status != "unconfigured"
        }
        let allIncomingNetworkFailed = !incomingRelevant.isEmpty
            && incomingRelevant.allSatisfy { $0.status == "error" && Self.isNetworkProvider($0) }

        let rejectedIDs = Set(source.providers.map(\.id)).subtracting(incoming.providers.map(\.id))
        var providers = snapshot?.providers.filter { only != nil || (preserveDoubao && $0.id == "doubao") || rejectedIDs.contains($0.id) } ?? []
        let previous = snapshot
        for var provider in incoming.providers {
            if Self.isNetworkProvider(provider) || (provider.status == "error" && ProviderRegistry.usesLocalQuota(provider.id)), var old = previous?.provider(withID: provider.id),
               old.isUsable, old.localAccountID == provider.localAccountID {
                old.cached = true
                old.sampledAt = old.sampledAt ?? previous?.sampledAt ?? previous?.updatedAt
                provider = old
            } else {
                provider.sampledAt = provider.sampledAt ?? incoming.sampledAt ?? incoming.updatedAt
            }
            if let index = providers.firstIndex(where: { $0.id == provider.id }) {
                providers[index] = provider
            } else { providers.append(provider) }
        }
        let failed = incoming.providers.filter(Self.isNetworkProvider)
        if only != ["doubao"] {
            isOffline = allIncomingNetworkFailed && providers.filter(\.isUsable).allSatisfy { $0.cached == true }
            errorMessage = failed.isEmpty || isOffline ? nil : failed.map(\.name).joined(separator: "、") + " 刷新失败"
        }
        let merged = QuotaSnapshot(schema: incoming.schema, updatedAt: incoming.updatedAt,
                                   sampledAt: incoming.sampledAt, providers: providers)
        ProviderRegistry.update(from: providers)
        latestSnapshot = merged
        UsageTracker.shared.record(snapshot: incoming, only: only.map(Set.init))
        HistoryStore.shared.record(snapshot: incoming, only: only.map(Set.init), preferredWindows: config.dictionary("panelWindow") as? [String: String] ?? [:])
        saveCache(merged)
    }

    private func saveCache(_ snapshot: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        publishWidgetSnapshot()
    }

    /// WidgetKit extension 是 sandboxed 的，只共享 App Group 容器里的快照。
    func publishWidgetSnapshot() {
        guard publishWidgets, LaunchAgentInstaller.ownsBackgroundTasks, let snapshot else { return }
        let visible = snapshot.excluding(Set(config.stringArray("hiddenProviders")))
        let rows = visible.providers.filter { $0.status != "disabled" }.map { p in
            ["id": p.id, "name": p.name, "value": p.riskDescription, "sampledAt": p.sampledAt ?? "", "cached": p.cached == true] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["providers": rows]) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/AgentQuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("widget-values.json")
        try? data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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
    func verify(provider: String, candidate: [String: Any]? = nil, completion: @escaping (Result<ProviderStatus, Error>) -> Void) {
        let configPath = config.url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.runCollector(configPath: configPath, only: [provider], candidate: candidate) }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    if let status = snapshot.provider(withID: provider) {
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

    private static func runCollector(configPath: String, only: [String]? = nil, candidate: [String: Any]? = nil, skipDoubao: Bool = false) throws -> QuotaSnapshot {
        let process = Process()
        let script = try findCollectorScript()
        var arguments = [script]
        if skipDoubao { arguments.append("--skip-doubao") }
        if let only, !only.isEmpty {
            arguments.append("--only=\(only.joined(separator: ","))")
        }

        let input = Pipe()
        let candidateData = try candidate.map { try JSONSerialization.data(withJSONObject: $0) }
        if candidateData != nil {
            arguments.append("--verify-stdin")
            process.standardInput = input
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
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            nodePathLock.withLock { cachedNodePath = nil }
            throw QuotaError.failed("无法启动 collector：\(error.localizedDescription)")
        }

        if let candidateData {
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: candidateData)
                try? input.fileHandleForWriting.close()
            }
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (only == ["doubao"] ? 160 : 100), execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        log("collector exit=\(process.terminationStatus) bytes=\(outData.count)")
        do {
            return try JSONDecoder().decode(QuotaSnapshot.self, from: outData)
        } catch {
            log("collector JSON decode failed")
        }
        throw QuotaError.failed("采集结果无法读取（退出码 \(process.terminationStatus)）")
    }

    private static func runCheckinProcess(configPath: String) throws -> CheckinReport {
        let process = Process()
        let script = try findCollectorScript()
        let arguments = [script, "--checkin", "--only=trae,workbuddy,doubao"]

        let node = try findNode()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = arguments

        var environment = makeEnvironment(configPath: configPath)
        let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

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
        process.waitUntilExit()
        watchdog.cancel()

        log("checkin exit=\(process.terminationStatus) bytes=\(outData.count)")
        do {
            return try JSONDecoder().decode(CheckinReport.self, from: outData)
        } catch {
            throw QuotaError.failed("签到结果无法读取（退出码 \(process.terminationStatus)）")
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
        try nodePathLock.withLock {
            if let cached = cachedNodePath { return cached }
            guard let executable = locateNode() else { throw QuotaError.nodeMissing }
            cachedNodePath = executable
            return executable
        }
    }

    private static let nodePathLock = NSLock()
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
