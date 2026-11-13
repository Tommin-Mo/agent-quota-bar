import AppKit

extension Notification.Name {
    static let quotaUpdated = Notification.Name("AgentQuota.quotaUpdated")
    static let quotaSettingsChanged = Notification.Name("AgentQuota.settingsChanged")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let service = QuotaService()
    private lazy var checkin = CheckinService(service: service)
    private var scheduler: RefreshScheduler!
    private var checkinTimer: Timer?
    private var offlineTimer: Timer?
    private var appearanceTimer: Timer?
    private var lastStatusAppearanceName: String?
    private var lastCodexActivity: Date?
    private lazy var networkMonitor = NetworkMonitor()
    private var popoverController: QuotaPopoverViewController!
    private var settingsController: SettingsWindowController?
    private var setupControllers: [String: SetupWindowController] = [:]
    private var activeProviderID: String?
    private var lastUsage: [String: ProviderUsageSnapshot] = [:]
    private var lastSwitchAt = Date.distantPast
    private var lastMenuBarMode: String?
    private let switchCooldown: TimeInterval = 10
    private var didPopoverSnapshot = false
    private var didStatusSnapshot = false
    private var didIconPreview = false
    private var loginPreview: WebLoginWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        QuotaStyle.apply(service.config)
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        } else if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
            NSApp.applicationIconImage = icon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }

        popoverController = QuotaPopoverViewController(service: service)
        popoverController.onConfigure = { [weak self] provider in
            self?.closePopover()
            self?.openSetup(provider: provider)
        }
        popoverController.onOpenSettings = { [weak self] in
            self?.closePopover()
            self?.openSettings()
        }
        popoverController.onRefresh = { [weak self] in
            self?.scheduler.refreshNow()
        }
        popoverController.onCheckin = { [weak self] in
            self?.checkin.runNow(manual: true)
        }
        popoverController.onToggleAppearance = { [weak self] in
            self?.toggleAppearance()
        }
        popoverController.onReorder = { [weak self] order in
            guard let self else { return }
            self.service.config.set("providerOrder", order)
            do {
                try self.service.config.save()
            } catch {
                log("save order failed: \(error)")
            }
        }
        popoverController.onPreferredContentSizeChange = { [weak self] size in
            guard let self, self.popover.isShown else { return }
            self.popover.contentSize = size
        }
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        networkMonitor.onChange = { [weak self] online in
            guard let self else { return }
            if online && self.service.isOffline {
                self.scheduler.refreshNow()
            }
        }

        service.onChange = { [weak self] in
            DispatchQueue.main.async { self?.render() }
        }

        checkin.onUpdate = { [weak self] in
            self?.refreshCheckinUI()
        }
        checkin.onRequestRefresh = { [weak self] in
            self?.scheduler.refreshNow()
        }
        checkinTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.checkin.runIfNeeded()
        }
        if let checkinTimer { RunLoop.main.add(checkinTimer, forMode: .common) }

        scheduler = RefreshScheduler(service: service)
        render()
        refreshCheckinUI()
        scheduler.start()
        // 状态栏按钮刚挂上时 effectiveAppearance 还是 VibrantLight，
        // 系统菜单栏稍后才切换成 VibrantDark；补两次重绘，避免首屏黑图标。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.render() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.render() }
        let appearanceTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            let name = button.effectiveAppearance.name.rawValue
            guard name != self.lastStatusAppearanceName else { return }
            self.lastStatusAppearanceName = name
            self.render()
        }
        RunLoop.main.add(appearanceTimer, forMode: .common)
        self.appearanceTimer = appearanceTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkin.runIfNeeded()
        }
        installDebugHooks()
        NotificationCenter.default.addObserver(
            forName: .quotaSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.render()
        }

        // 系统睡眠期间 Timer 不会触发；唤醒后立即补一次，避免菜单栏长期停在旧值。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspaceCenter.addObserver(
                self,
                selector: #selector(handleSystemWake(_:)),
                name: name,
                object: nil
            )
        }
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshThemeSurfaces()
            self?.render()
        }

        // 状态栏已经创建，再把 launchctl / 磁盘写入放到后台，避免启动被阻塞。
        scheduleLaunchAgents()
        surfaceConfigProblemIfNeeded()
    }

    /// LaunchAgent 的安装/更新涉及磁盘写入和 `launchctl`，全部异步执行。
    private func scheduleLaunchAgents() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            BackgroundCheckin.installIfNeeded()
            UsageSampler.installIfNeeded()
        }
    }

    /// 配置文件损坏时提示一次；ConfigStore 已经把坏文件备份走了。
    private func surfaceConfigProblemIfNeeded() {
        guard let message = service.config.loadError else { return }
        log("config problem: \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "配置文件需要处理"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: 开发调试（AQB_* 环境变量，不影响正常使用）

    private func toggleAppearance() {
        let dark = Theme.currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        service.config.set("appearance", dark ? "light" : "dark")
        try? service.config.save()
        applyAppearance()
        refreshThemeSurfaces()
    }

    /// 外观切换后立刻刷新一次，再在 AppKit 真正消化外观后补两次。
    private func refreshThemeSurfaces() {
        popoverController?.refreshAppearance()
        settingsController?.reloadForAppearance()
        for delay in [0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.popoverController?.refreshAppearance()
                self?.settingsController?.reloadForAppearance()
            }
        }
    }

    private func applyAppearance() {
        switch service.config.string("appearance", default: "system") {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
        for window in NSApp.windows {
            window.appearance = NSApp.appearance
        }
    }

    private func refreshCheckinUI() {
        // 后台签到会直接写配置；先同步一次再展示状态。
        checkin.refreshFromDisk()
        popoverController?.updateCheckin(
            status: checkin.statusText,
            detail: checkin.detailText,
            done: checkin.hasCheckedInToday,
            running: checkin.isRunning
        )
        settingsController?.updateCheckinStatus()
    }

    private func menuBarInk() -> NSColor {
        .white
    }

    private func installDebugHooks() {
        let env = ProcessInfo.processInfo.environment

        if env["AQB_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettings()
                if let path = env["AQB_SETTINGS_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard let view = self?.settingsController?.window?.contentView else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if let provider = env["AQB_OPEN_SETUP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSetup(provider: provider)
                if let path = env["AQB_SETUP_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard let view = self?.setupControllers[provider]?.window?.contentView else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if env["AQB_TEST_NOTIFICATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NotificationService.shared.sendTest()
            }
        }

        if env["AQB_FORCE_CHECKIN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.checkin.runNow(manual: true)
            }
        }

        if env["AQB_TOGGLE_APPEARANCE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.toggleAppearance()
                if let path = env["AQB_TOGGLE_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        guard let view = self?.popoverController.view else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if let appearance = env["AQB_TEST_APPEARANCE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.service.config.set("appearance", appearance)
                try? self.service.config.save()
                self.applyAppearance()
                self.refreshThemeSurfaces()
                if let path = env["AQB_TEST_APPEARANCE_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        guard let view = self.settingsController?.window?.contentView else { return }
                        self.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if let path = env["AQB_ICON_PREVIEW"], let snapshot = service.snapshot {
            let preview = NSImage(size: NSSize(width: 250, height: 46))
            preview.lockFocus()
            NSColor(white: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 250, height: 46).fill()
            for (index, id) in ["codex", "deepseek", "opencode", "trae", "workbuddy"].enumerated() {
                guard let item = snapshot.menuBarItem(for: id) else { continue }
                let icon = MenuBarIcon.make(
                    provider: id,
                    value: item.value,
                    remaining: item.remaining,
                    severity: item.severity,
                    scale: CGFloat(service.config.double("menuBarIconScale", default: 1.25)),
                    ink: .white
                )
                icon.draw(in: NSRect(x: 10 + index * 47, y: 14, width: 28, height: 18))
            }
            preview.unlockFocus()
            if let tiff = preview.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }

        if let kindString = env["AQB_OPEN_LOGIN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let kind: WebLoginWindowController.Kind = kindString == "opencode" ? .opencode : .workbuddy
                let controller = WebLoginWindowController(kind: kind, service: self.service) { _, _ in }
                self.loginPreview = controller
                controller.showWindow(nil)
                if let path = env["AQB_LOGIN_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        guard let view = controller.window?.contentView else { return }
                        self.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if env["AQB_ENABLE_LOGIN"] == "1" {
            log("login register error=\(LaunchAtLogin.set(true) ?? "nil") status=\(LaunchAtLogin.statusText)")
        }
        if env["AQB_DISABLE_LOGIN"] == "1" {
            log("login unregister error=\(LaunchAtLogin.set(false) ?? "nil") status=\(LaunchAtLogin.statusText)")
        }
    }

    private func writeSnapshot(of view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        var data = rep.representation(using: .png, properties: [:])
        if ProcessInfo.processInfo.environment["AQB_SNAPSHOT_BG"] == "1" {
            let base = NSImage(size: view.bounds.size)
            base.lockFocus()
            NSColor(white: 0.97, alpha: 1).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            if let data, let image = NSImage(data: data) {
                image.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            }
            base.unlockFocus()
            if let tiff = base.tiffRepresentation, let composed = NSBitmapImageRep(data: tiff) {
                data = composed.representation(using: .png, properties: [:])
            }
        }
        if let data {
            try? data.write(to: URL(fileURLWithPath: path))
            log("snapshot \(view.bounds) -> \(path)")
        }
    }

    // MARK: 状态栏

    private func updateOfflineRetry() {
        if service.isOffline {
            guard offlineTimer == nil else { return }
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.scheduler.refreshNow()
            }
            RunLoop.main.add(timer, forMode: .common)
            offlineTimer = timer
        } else {
            offlineTimer?.invalidate()
            offlineTimer = nil
        }
    }

    private func render() {
        QuotaStyle.apply(service.config)
        log("render providers=\(service.snapshot?.providers.count ?? -1) refreshing=\(service.isRefreshing) err=\(service.errorMessage ?? "nil")")
        if let saveError = service.config.lastSaveError {
            log("config save error: \(saveError)")
        }
        guard let button = statusItem.button else { return }

        let mode = service.config.string("menuBarMode", default: "auto")
        let hidden = Set(service.config.stringArray("hiddenProviders"))
        let visibleSnapshot = service.snapshot?.excluding(hidden)
        if let snapshot = visibleSnapshot {
            updateActiveProvider(snapshot: snapshot, mode: mode)
        }

        if let snapshot = visibleSnapshot {
            let configured = service.config.string("menuBarProvider", default: "auto")
            let providerID = activeProviderID
                ?? (configured == "auto" ? nil : configured)
                ?? snapshot.worstProviderID()
                ?? snapshot.providers.first?.id
            if let id = providerID, let item = snapshot.menuBarItem(for: id) {
                let scale = CGFloat(service.config.double("menuBarIconScale", default: 1.25))
                button.image = MenuBarIcon.make(
                    provider: id,
                    value: item.value,
                    remaining: item.remaining,
                    severity: item.severity,
                    scale: scale,
                    ink: menuBarInk(),
                    appearance: button.effectiveAppearance
                )
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
                let name = ProviderStyles.style(for: id).shortName
                button.toolTip = "\(name)\n\(item.tooltip)" + (service.isOffline ? "\n网络未连接，显示上次数据" : "")
            } else {
                button.image = MenuBarIcon.make(
                    provider: "codex",
                    value: "—",
                    remaining: nil,
                    severity: .neutral,
                    scale: CGFloat(service.config.double("menuBarIconScale", default: 1.25)),
                    ink: menuBarInk()
                )
                button.attributedTitle = NSAttributedString(string: "")
                button.toolTip = "没有可显示的 Agent"
            }
        } else {
            button.image = MenuBarIcon.make(
                provider: "codex",
                value: service.isRefreshing ? "…" : "—",
                remaining: nil,
                severity: .neutral,
                scale: CGFloat(service.config.double("menuBarIconScale", default: 1.25)),
                ink: menuBarInk()
            )
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = service.isOffline
                ? "网络未连接，等待恢复"
                : (service.errorMessage ?? "点击打开面板")
        }

        popoverController.update(
            snapshot: visibleSnapshot,
            error: service.errorMessage,
            isRefreshing: service.isRefreshing,
            isOffline: service.isOffline
        )
        updateOfflineRetry()
        if popover.isShown {
            popover.contentSize = popoverController.preferredContentSize
        }
        settingsController?.updateProviderStatuses(service.snapshot)
        NotificationCenter.default.post(name: .quotaUpdated, object: service.snapshot)
        if let snapshot = service.snapshot {
            NotificationService.shared.check(snapshot: snapshot, config: service.config)
        }
        refreshCheckinUI()

        let env = ProcessInfo.processInfo.environment
        if let path = env["AQB_ICON_PREVIEW"], !didIconPreview, let snapshot = visibleSnapshot {
            didIconPreview = true
            renderIconPreview(snapshot: snapshot, path: path)
        }
        if let snapshot = service.snapshot {
            if let path = env["AQB_STATUS_SNAPSHOT"], !didStatusSnapshot, let button = statusItem.button {
                didStatusSnapshot = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.writeSnapshot(of: button, to: path)
                }
            }
            if env["AQB_SHOW_POPOVER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.showPopover()
                }
            }
            if let path = env["AQB_SNAPSHOT"], !didPopoverSnapshot {
                didPopoverSnapshot = true
                let delay = Double(env["AQB_SNAPSHOT_DELAY"] ?? "") ?? 0.8
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let view = self?.popoverController.view else { return }
                    self?.writeSnapshot(of: view, to: path)
                }
            }
            _ = snapshot
        }
    }

    private func renderIconPreview(snapshot: QuotaSnapshot, path: String) {
        let preview = NSImage(size: NSSize(width: 250, height: 46))
        preview.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 250, height: 46).fill()
        for (index, id) in ["codex", "deepseek", "opencode", "trae", "workbuddy"].enumerated() {
            guard let item = snapshot.menuBarItem(for: id) else { continue }
            let icon = MenuBarIcon.make(
                provider: id,
                value: item.value,
                remaining: item.remaining,
                severity: item.severity
            )
            icon.draw(in: NSRect(x: 10 + index * 47, y: 14, width: 28, height: 18))
        }
        preview.unlockFocus()
        if let tiff = preview.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 自动模式：谁的额度数值刚变化，就切到谁；10 秒冷却避免闪烁。
    private struct ProviderUsageSnapshot {
        var percents: [String: Double] = [:]
        var consumed: Double?
        var balance: Double?
        /// 最近一次检测到真实使用的快照时间；冷却期间也不会丢，冷却结束后补切。
        var lastUsedAt: Date?
    }

    /// 最近使用只看“真的消耗”：used 上升、consumed 增加、余额下降。
    /// 窗口重置、签到 +100、充值上涨都不算使用。
    @discardableResult
    private func detectUsage(_ provider: ProviderStatus, at timestamp: Date) -> Bool {
        var current = ProviderUsageSnapshot()
        var occurrences: [String: Int] = [:]
        for metric in provider.metrics where metric.kind == "percent" {
            guard let used = metric.usedPercent else { continue }
            // 同一 provider 可能出现同 label 的多条指标；用出现序号区分，
            // 不能再用 Dictionary(uniqueKeysWithValues:)（重复 key 会直接崩溃）。
            let base = "\(metric.kind)|\(metric.label)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let key = occurrence == 0 ? base : "\(base)#\(occurrence + 1)"
            current.percents[key] = used
        }
        current.consumed = provider.consumed
        current.balance = provider.balance
        current.lastUsedAt = lastUsage[provider.id]?.lastUsedAt

        var used = false
        if let previous = lastUsage[provider.id] {
            for (label, value) in current.percents {
                if let old = previous.percents[label], value > old + 0.0001 {
                    used = true
                    break
                }
            }
            if !used, let consumed = current.consumed, let old = previous.consumed,
               consumed > old + 0.0001 {
                used = true
            }
            if !used, let balance = current.balance, let old = previous.balance,
               balance < old - 0.0001 {
                used = true
            }
        }
        if used {
            current.lastUsedAt = timestamp
        }
        lastUsage[provider.id] = current
        return used
    }

    /// Codex 的额度百分比只按整数变化，短时间内使用不一定跨 1%；
    /// 这里用本地 ~/.codex 日志的 mtime 作为“最近确实在用 Codex”的补充信号。
    private func codexLocalActivityDate() -> Date? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            ".codex/logs_2.sqlite",
            ".codex/logs_2.sqlite-wal",
            ".codex/thread_history_1.sqlite",
            ".codex/thread_history_1.sqlite-wal",
        ]
        return paths.compactMap { relative -> Date? in
            let url = home.appendingPathComponent(relative)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return attrs[.modificationDate] as? Date
        }.max()
    }

    private func updateActiveProvider(snapshot: QuotaSnapshot, mode: String) {
        let candidates = snapshot.providers.filter { $0.status != "disabled" }

        if lastMenuBarMode != mode {
            lastMenuBarMode = mode
            if mode == "auto" {
                activeProviderID = nil
                lastUsage.removeAll()
                lastSwitchAt = .distantPast
            }
        }

        if mode == "fixed" {
            let fixed = service.config.string("menuBarProvider", default: "auto")
            if fixed != "auto", snapshot.provider(withID: fixed) != nil {
                // 固定模式就是固定：即使这家报错也保持，图标显示 "!"，不偷偷换别家。
                activeProviderID = fixed
                return
            }
        }

        let now = Date()
        let usageTimestamp = snapshot.updatedDate ?? now
        for provider in candidates where provider.isUsable {
            detectUsage(provider, at: usageTimestamp)
        }

        if let activity = codexLocalActivityDate(),
           lastCodexActivity == nil || activity > lastCodexActivity! {
            lastCodexActivity = activity
            if var current = lastUsage["codex"] {
                current.lastUsedAt = now
                lastUsage["codex"] = current
            }
        }

        if mode == "auto" {
            // 选“最近一次真实使用”的那家；冷却期间只是不切，记录不会丢。
            var latestUsed: (id: String, at: Date)?
            for provider in candidates {
                // 不能要求 usedAt > lastSwitchAt：活动可能发生在冷却/上一次切换之前，
                // 到达时已经“过期”，会被永久吞掉，菜单栏就卡在上一家。
                guard let usedAt = lastUsage[provider.id]?.lastUsedAt else { continue }
                if latestUsed == nil || usedAt > latestUsed!.at {
                    latestUsed = (provider.id, usedAt)
                }
            }
            if let latestUsed, now.timeIntervalSince(lastSwitchAt) >= switchCooldown {
                activeProviderID = latestUsed.id
                lastSwitchAt = now
            }
        }

        if activeProviderID == nil || snapshot.provider(withID: activeProviderID!) == nil {
            let configured = service.config.string("menuBarProvider", default: "auto")
            if configured != "auto", snapshot.provider(withID: configured) != nil {
                activeProviderID = configured
            } else {
                activeProviderID = snapshot.worstProviderID()
            }
        }
        // 自动模式才在出错时兜底；固定模式上面已经 return。
        if mode != "fixed",
           let id = activeProviderID,
           let provider = snapshot.provider(withID: id),
           provider.status == "error" || provider.status == "unconfigured" {
            activeProviderID = snapshot.worstProviderID()
        }
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        log("system wake / session active; refreshing")
        scheduler.refreshNow()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // 打开面板时如果数据已经超过一个刷新周期，补一次；避免只能手动点“立即刷新”。
            if service.snapshot == nil
                || (service.snapshot?.updatedDate.map {
                    Date().timeIntervalSince($0) > TimeInterval(service.config.refreshSeconds)
                } ?? true) {
                scheduler.refreshNow()
            }
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func showContextMenu() {
        checkin.refreshFromDisk()
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if !checkin.hasCheckedInToday {
            let checkinItem = NSMenuItem(
                title: "一键签到 Trae + WorkBuddy",
                action: #selector(checkinNowMenu),
                keyEquivalent: ""
            )
            checkinItem.target = self
            menu.addItem(checkinItem)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc func checkinNowMenu() {
        checkin.runNow(manual: true)
    }

    @objc func refreshNow() {
        scheduler.refreshNow()
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !LaunchAtLogin.isEnabled
        if let error = LaunchAtLogin.set(enable) {
            let alert = NSAlert()
            alert.messageText = "无法修改开机启动"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.runModal()
        }
        settingsController?.refreshLoginState()
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                service: service,
                checkin: checkin,
                onSaved: { [weak self] in
                    self?.scheduler.intervalsChanged()
                },
                onOpenSetup: { [weak self] provider in
                    self?.openSetup(provider: provider)
                },
                onAppearanceChanged: { [weak self] in
                    guard let self else { return }
                    self.applyAppearance()
                    self.refreshThemeSurfaces()
                },
                onCheckin: { [weak self] in
                    self?.checkin.runNow(manual: true)
                }
            )
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSetup(provider: String) {
        if let existing = setupControllers[provider] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SetupWindowController(provider: provider, service: service) { [weak self] in
            self?.scheduler.refreshNow()
        }
        controller.onClose = { [weak self] in
            self?.setupControllers[provider] = nil
        }
        setupControllers[provider] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - 基础组件

/// 闭包版按钮：target 是 weak，直接用闭包避免额外对象被释放。
final class ClosureButton: NSButton {
    private let onTap: () -> Void

    init(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.font = .systemFont(ofSize: 10.5, weight: .semibold)
        self.contentTintColor = .systemBlue
        self.target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { onTap() }
}

final class AvatarView: NSView {
    init(letter: String, color: NSColor, size: CGFloat, provider: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        if let provider, let logo = ProviderLogo.image(for: provider, size: size * 0.92, color: Theme.text) {
            let view = NSImageView(image: logo)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }

        let label = NSTextField(labelWithString: letter)
        label.font = .systemFont(ofSize: size * 0.46, weight: .bold)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PillView: NSView {
    init(text: String, color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 文本辅助

/// 跟随所在视图的实际外观重算颜色；避免窗口/视图从浅色切到深色后，
/// NSTextField 仍缓存创建时的黑色。
final class ThemedLabel: NSTextField {
    var roleColor: NSColor = .labelColor

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textColor = roleColor.resolvedForAppearance()
        needsDisplay = true
    }

    func applyRole(_ color: NSColor) {
        roleColor = color
        // 显式外观优先；避免 effectiveAppearance 晚一拍造成深浅色错配。
        textColor = color.resolvedForAppearance()
        needsDisplay = true
    }
}

func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    monospaced: Bool = false
) -> NSTextField {
    let label = ThemedLabel(labelWithString: text)
    label.font = monospaced
        ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    label.roleColor = color
    label.textColor = color.resolvedForAppearance()
    label.lineBreakMode = .byTruncatingTail
    return label
}

final class ThemedWrappingLabel: NSTextField {
    var roleColor: NSColor = .labelColor

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textColor = roleColor.resolvedForAppearance()
        needsDisplay = true
    }
}

func wrappingLabel(_ text: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
    let label = ThemedWrappingLabel(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.roleColor = color
    label.textColor = color.resolvedForAppearance()
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = width
    return label
}
