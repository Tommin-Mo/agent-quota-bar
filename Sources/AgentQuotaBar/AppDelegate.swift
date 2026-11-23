import AppKit

extension Notification.Name {
    static let quotaUpdated = Notification.Name("AgentQuota.quotaUpdated")
    static let quotaSettingsChanged = Notification.Name("AgentQuota.settingsChanged")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let quotaPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var panelAnchor = NSPoint.zero
    private var panelScreen: NSScreen?
    private var outsideGlobal: Any?
    private var outsideLocal: Any?
    private var pendingMenuDismissal: DispatchWorkItem?
    private let service = QuotaService()
    private lazy var checkin = CheckinService(service: service)
    private var scheduler: RefreshScheduler!
    private var checkinTimer: Timer?
    private var offlineTimer: Timer?
    private let menuProgress = MenuBarProgressView()
    private lazy var networkMonitor = NetworkMonitor()
    private var popoverController: QuotaPopoverViewController!
    private var settingsController: SettingsWindowController?
    private var setupControllers: [String: SetupWindowController] = [:]
    private var activeProviderID: String?
    private var lastUsage: [String: ProviderUsageSnapshot] = [:]
    private var lastSwitchAt = Date.distantPast
    private var lastMenuBarMode: String?
    private var pendingUsage: (id: String, at: Date, magnitude: Double)?
    private var frontmostMonitor: FrontmostProviderMonitor!
    private var lastOpenCodeSession: Date?
    private let switchCooldown: TimeInterval = 10
    private var didPopoverSnapshot = false
    private var didDebugPopover = false
    private var historyController: HistoryWindowController?
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
            menuProgress.frame = button.bounds
            menuProgress.autoresizingMask = [.width, .height]
            menuProgress.setAccessibilityElement(false)
            button.addSubview(menuProgress)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }

        popoverController = QuotaPopoverViewController(service: service)
        popoverController.onConfigure = { [weak self] provider in
            self?.closePopover()
            self?.openSetup(provider: provider)
        }
        popoverController.onSelectServices = { [weak self] in
            self?.closePopover()
            self?.openSettings()
            self?.settingsController?.showServicesPage()
        }
        popoverController.onOpenSettings = { [weak self] in
            self?.closePopover()
            self?.openSettings()
        }
        popoverController.onRefresh = { [weak self] in
            self?.scheduler.refreshNow()
        }
        popoverController.historyProvider = { [weak self] in
            guard let self else { return [] }
            return HistoryStore.shared.remainingValues(provider: self.activeProviderID ?? "codex")
        }
        popoverController.historyCaption = "近 7 天剩余"

        popoverController.onCheckin = { [weak self] in
            self?.checkin.runNow(manual: true)
        }
        popoverController.onHistory = { [weak self] in
            self?.closePopover()
            self?.openHistory()
        }
        popoverController.onToggleAppearance = { [weak self] in
            self?.toggleAppearance()
        }
        popoverController.onReorder = { [weak self] order in
            guard let self else { return }
            // 面板只提交可见行；隐藏/禁用服务必须保留在原序列附近，
            // 否则重新启用时会被追加到末尾，用户的自定义顺序就丢了。
            let previous = self.service.config.stringArray("providerOrder")
            var merged = order
            for (index, id) in previous.enumerated() where !merged.contains(id) {
                merged.insert(id, at: min(index, merged.count))
            }
            for id in ProviderRegistry.ids where !merged.contains(id) {
                merged.append(id)
            }
            self.service.config.set("providerOrder", merged)
            do {
                try self.service.config.save()
            } catch {
                log("save order failed: \(error)")
            }
        }
        popoverController.onPreferredContentSizeChange = { [weak self] size in
            guard let self, self.quotaPanel.isVisible else { return }
            self.positionPanel(size)
        }
        quotaPanel.contentViewController = popoverController
        quotaPanel.isReleasedWhenClosed = false
        quotaPanel.animationBehavior = .none
        quotaPanel.level = .popUpMenu
        quotaPanel.isFloatingPanel = true
        quotaPanel.hidesOnDeactivate = false
        quotaPanel.isOpaque = false
        quotaPanel.backgroundColor = .clear
        quotaPanel.hasShadow = true
        quotaPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        popoverController.view.wantsLayer = true
        popoverController.view.layer?.cornerRadius = 12
        popoverController.view.layer?.masksToBounds = true

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
        lastOpenCodeSession = OpenCodeActivity.latestSessionDate()
        frontmostMonitor = FrontmostProviderMonitor()
        frontmostMonitor.onChange = { [weak self] provider in
            self?.frontmostProviderChanged(provider)
        }
        frontmostMonitor.start()
        render()
        refreshCheckinUI()
        scheduler.start()
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
            self?.service.publishWidgetSnapshot()
            self?.historyController?.refreshForExternalSnapshot()
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
        workspaceCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            self?.refreshThemeSurfaces()
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                    object: nil, queue: .main) { [weak self] note in
            guard let self, self.quotaPanel.isVisible,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.closePopover()
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
    private func openHistory() {
        if historyController == nil {
            // 历史默认是整体额度监控；具体 Agent 在窗口内选择。
            historyController = HistoryWindowController(providerID: "all")
        }
        historyController?.currentSnapshotProvider = { [weak self] in guard let self else { return nil }; return self.service.snapshot }
        historyController?.refreshForExternalSnapshot()
        historyController?.showWindow(nil)
        historyController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshThemeSurfaces() {
        for setup in setupControllers.values {
            if let content = setup.window?.contentView { Theme.refreshViews(content) }
        }
        historyController?.refreshAppearance()
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
        Theme.design = DesignTheme(setting: service.config.string("designTheme"))
        switch service.config.string("appearance", default: "system") {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
        for window in NSApp.windows where window !== statusItem?.button?.window {
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

    private func installDebugHooks() {
        let env = ProcessInfo.processInfo.environment

        if env["AQB_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettings()
                if let page = env["AQB_SETTINGS_PAGE"] {
                    self?.settingsController?.selectPageForDebug(page)
                }
                if let provider = env["AQB_ACCOUNT_MANAGER"] {
                    self?.settingsController?.openAccountManagerForDebug(
                        provider,
                        showForm: env["AQB_ACCOUNT_FORM"] == "1")
                }
                if let path = env["AQB_SETTINGS_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard let view = self?.settingsController?.window?.contentView else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
                if let path = env["AQB_SHEET_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard let view = self?.settingsController?.window?.attachedSheet?.contentView else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if env["AQB_OPEN_HISTORY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.openHistory()
                if let path = env["AQB_HISTORY_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard let view = self?.historyController?.window?.contentView else { return }
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
                if let path = env["AQB_SHEET_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard let view = self?.settingsController?.window?.attachedSheet?.contentView else { return }
                        self?.writeSnapshot(of: view, to: path)
                    }
                }
            }
        }

        if env["AQB_TEST_NOTIFICATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NotificationService.shared.sendTest { accepted in
                    NSLog("AQB notification test accepted=%@", accepted ? "yes" : "no")
                }
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
                if let path = env["AQB_SHEET_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard let view = self?.settingsController?.window?.attachedSheet?.contentView else { return }
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
                    scale: service.effectiveMenuBarIconScale
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
        let disabled = Set(service.snapshot?.providers.filter { $0.status == "disabled" }.map(\.id) ?? [])
        let visibleSnapshot = service.snapshot?.excluding(hidden.union(disabled))
        if let snapshot = visibleSnapshot {
            updateActiveProvider(snapshot: snapshot, mode: mode)
        }

        let icon: MenuBarIcon
        if let snapshot = visibleSnapshot {
            let configured = service.config.string("menuBarProvider", default: "auto")
            let providerID = activeProviderID
                ?? (configured == "auto" ? nil : configured)
                ?? snapshot.worstProviderID()
                ?? snapshot.providers.first?.id
            if let id = providerID, let item = snapshot.menuBarItem(for: id) {
                let scale = service.effectiveMenuBarIconScale
                icon = MenuBarIcon.make(
                    provider: id,
                    value: item.value,
                    remaining: item.remaining,
                    scale: scale
                )
                let name = ProviderStyles.style(for: id).shortName
                button.toolTip = "\(name)\n\(item.tooltip)" + (service.isOffline ? "\n网络未连接，显示上次数据" : "")
            } else {
                icon = MenuBarIcon.make(
                    provider: "quota",
                    value: "",
                    remaining: nil,
                    scale: service.effectiveMenuBarIconScale
                )
                button.toolTip = "没有可显示的 Agent"
            }
        } else {
            icon = MenuBarIcon.make(
                provider: "quota",
                value: "",
                remaining: nil,
                scale: service.effectiveMenuBarIconScale
            )
            button.toolTip = service.isOffline
                ? "网络未连接，等待恢复"
                : (service.errorMessage ?? "点击打开面板")
        }

        button.image = icon.foreground
        menuProgress.progress = icon.progress

        popoverController.update(
            snapshot: visibleSnapshot,
            error: service.errorMessage,
            isRefreshing: service.isRefreshing,
            isOffline: service.isOffline
        )
        updateOfflineRetry()

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
            if env["AQB_SHOW_POPOVER"] == "1", !didDebugPopover {
                didDebugPopover = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.showPopover()
                }
            }
            if let path = env["AQB_SNAPSHOT"], !didPopoverSnapshot {
                didPopoverSnapshot = true
                let delay = Double(env["AQB_SNAPSHOT_DELAY"] ?? "") ?? 0.8
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let view = self?.popoverController.view else { return }
                    if let id = env["AQB_SNAPSHOT_EXPAND"], let controller = self?.popoverController {
                        controller.expandForSnapshot(id)
                        view.layoutSubtreeIfNeeded()
                    }
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
                remaining: item.remaining
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
        var identity = ""
        var percents: [String: Double] = [:]
        var consumed: Double?
        var balance: Double?
        /// 最近一次检测到真实使用的快照时间；冷却期间也不会丢，冷却结束后补切。
        var lastUsedAt: Date?
        /// 同一轮全量快照里多家都变化时，用变化幅度做 tie-break。
        var magnitude: Double = 0
    }

    /// 最近使用只看“真的消耗”：used 上升、consumed 增加、余额下降。
    /// 窗口重置、签到 +100、充值上涨都不算使用。
    @discardableResult
    private func detectUsage(_ provider: ProviderStatus, at timestamp: Date) -> Bool {
        guard provider.cached != true, provider.isUsable else { return false }
        if lastUsage[provider.id]?.identity != provider.identity { lastUsage[provider.id] = nil }
        var current = ProviderUsageSnapshot()
        current.identity = provider.identity
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
        current.magnitude = lastUsage[provider.id]?.magnitude ?? 0

        var used = false
        var magnitude = 0.0
        if let previous = lastUsage[provider.id] {
            for (label, value) in current.percents {
                if let old = previous.percents[label], value > old + 0.0001 {
                    used = true
                    magnitude = max(magnitude, value - old)
                }
            }
            if let consumed = current.consumed, let old = previous.consumed,
               consumed > old + 0.0001 {
                used = true
                magnitude = max(magnitude, consumed - old)
            }
            if let balance = current.balance, let old = previous.balance,
               balance < old - 0.0001 {
                used = true
                magnitude = max(magnitude, old - balance)
            }
        }
        if used {
            current.magnitude = magnitude
        }
        if used {
            current.lastUsedAt = timestamp
        }
        lastUsage[provider.id] = current
        return used
    }

    private func frontmostProviderChanged(_ providerID: String?) {
        // 前台窗口不是用量。打开 WorkBuddy 不代表在用 WorkBuddy 的额度；
        // 菜单栏只跟随真实额度差值 / 会话活动，前台应用在这里不再改 activeProviderID。
        _ = providerID
    }

    private func updateActiveProvider(snapshot: QuotaSnapshot, mode: String) {
        let candidates = snapshot.providers.filter { $0.status != "disabled" }

        if lastMenuBarMode != mode {
            lastMenuBarMode = mode
            if mode == "auto" {
                activeProviderID = nil
                lastUsage.removeAll()
                pendingUsage = nil
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

        if mode == "merged" {
            // 单图标合并模式：显示最紧张的一家；展开面板仍看全部。
            activeProviderID = snapshot.worstProviderID()
            pendingUsage = nil
            return
        }

        let now = Date()
        let usageTimestamp = snapshot.updatedDate ?? now
        for provider in candidates where provider.isUsable {
            if detectUsage(provider, at: usageTimestamp) {
                let magnitude = lastUsage[provider.id]?.magnitude ?? 0
                // 只保留一个待切换事件：同一轮多家都变化时，变化幅度大的优先。
                if pendingUsage == nil
                    || usageTimestamp > pendingUsage!.at
                    || (usageTimestamp == pendingUsage!.at && magnitude > pendingUsage!.magnitude) {
                    pendingUsage = (provider.id, usageTimestamp, magnitude)
                }
            }
        }

        // 前台 App 不再作为自动切换信号；看真实额度变化和会话活动。

        // OpenCode 本地真正创建/更新会话时，即使窗口不在前台也能补一次。
        if let sessionDate = OpenCodeActivity.latestSessionDate() {
            if lastOpenCodeSession == nil {
                lastOpenCodeSession = sessionDate
            } else if sessionDate > lastOpenCodeSession! {
                lastOpenCodeSession = sessionDate
                if var current = lastUsage["opencode"] {
                    current.lastUsedAt = now
                    current.magnitude = max(current.magnitude, 1)
                    lastUsage["opencode"] = current
                }
                if pendingUsage == nil || now > pendingUsage!.at {
                    pendingUsage = ("opencode", now, 1)
                }
            }
        }

        if mode == "auto", let pendingUsage,
           now.timeIntervalSince(lastSwitchAt) >= switchCooldown {
            // 冷却期间只暂存，不丢；到点再切，切完清空，避免旧事件反复触发。
            activeProviderID = pendingUsage.id
            persistActiveProvider(pendingUsage.id, at: now)
            lastSwitchAt = now
            self.pendingUsage = nil
        }

        if activeProviderID == nil || snapshot.provider(withID: activeProviderID!) == nil {
            let configured = service.config.string("menuBarProvider", default: "auto")
            if configured != "auto", snapshot.provider(withID: configured) != nil {
                activeProviderID = configured
            } else if let recent = recentActivityProvider(snapshot: snapshot, now: now) {
                activeProviderID = recent
                persistActiveProvider(recent, at: now)
            } else if let stored = storedActivityProvider(snapshot: snapshot, now: now) {
                activeProviderID = stored
                persistActiveProvider(stored, at: now)
            } else if let last = Optional(service.config.string("lastActiveProvider")),
                      !last.isEmpty,
                      snapshot.provider(withID: last) != nil {
                activeProviderID = last
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

    /// 当本地会话库不可用（OpenCode 数据库为空/被清理）时，用已保存的 7 天
    /// 历史活跃区间兜底，避免菜单栏永远停在上次某个余额服务上。
    private func storedActivityProvider(snapshot: QuotaSnapshot, now: Date) -> String? {
        var best: (id: String, score: Double)?
        for provider in snapshot.providers where provider.isUsable {
            let entries = HistoryStore.shared.entries(provider: provider.id, days: 7, now: now)
            let score = entries.reduce(0.0) { total, entry in
                total + Double(entry.activeIntervals ?? 0) + (entry.hasQuotaSpend ? 1 : 0)
            }
            guard score > 0 else { continue }
            if best == nil || score > best!.score || (score == best!.score && provider.id < best!.id) {
                best = (provider.id, score)
            }
        }
        return best?.id
    }

    /// 启动时没有新的额度变化时，按最近真实活动决定菜单栏服务。
    /// OpenCode 的本地会话时间比一个没有时间戳的 lastActiveProvider 更可靠；
    /// 有 lastActiveAt 时则让时间较新的那一家胜出，避免旧的 DeepSeek 记录压住今天在用的 OpenCode。
    private func recentActivityProvider(snapshot: QuotaSnapshot, now: Date) -> String? {
        var best: (id: String, at: Date)?
        if let session = OpenCodeActivity.latestSessionDate(),
           snapshot.provider(withID: "opencode")?.isUsable == true,
           now.timeIntervalSince(session) < 7 * 24 * 3600 {
            best = ("opencode", session)
        }
        let lastID = service.config.string("lastActiveProvider")
        let raw = service.config.string("lastActiveAt")
        if !raw.isEmpty,
           let date = FlexibleDateParser.date(from: raw),
           !lastID.isEmpty,
           snapshot.provider(withID: lastID)?.isUsable == true,
           now.timeIntervalSince(date) < 7 * 24 * 3600 {
            if best == nil || date > best!.at { best = (lastID, date) }
        }
        return best?.id
    }

    private func persistActiveProvider(_ id: String, at date: Date) {
        service.config.set("lastActiveProvider", id)
        service.config.set("lastActiveAt", ISO8601DateFormatter().string(from: date))
        try? service.config.save()
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        log("system wake / session active; refreshing")
        scheduler.refreshNow()
    }

    @objc private func statusItemClicked() {
        pendingMenuDismissal?.cancel()
        pendingMenuDismissal = nil
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if quotaPanel.isVisible {
            let point = NSEvent.mouseLocation
            if panelScreen?.frame.contains(point) != true, let clicked = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                showQuotaPanel(at: point, on: clicked)
            } else { closePopover() }
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
        guard !quotaPanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? statusItem.button?.window?.screen else { return }
        showQuotaPanel(at: pointer, on: screen)
    }

    func showQuotaPanel(at pointer: NSPoint, on screen: NSScreen) {
        panelScreen = screen
        panelAnchor = NSPoint(x: pointer.x, y: min(screen.frame.maxY - NSStatusBar.system.thickness, screen.visibleFrame.maxY) - 3)
        popoverController.availableHeight = min(900, panelAnchor.y - screen.visibleFrame.minY - 8)
        positionPanel(popoverController.preferredContentSize)
        guard !quotaPanel.isVisible else { return }
        quotaPanel.orderFrontRegardless()
        popoverController.setPanelVisible(true)
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.dismissForOutsideEvent(event)
        }
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: [events, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePopover(); return nil }
            } else if event.window !== self.quotaPanel && event.window !== self.statusItem.button?.window { self.closePopover() }
            return event
        }
    }

    private func dismissForOutsideEvent(_ event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if event.type == .leftMouseUp {
            if statusItem.button?.window?.frame.contains(point) == true { return }
            if panelScreen?.frame.contains(point) != true,
               let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
               point.y >= min(screen.visibleFrame.maxY, screen.frame.maxY - NSStatusBar.system.thickness) {
                // The other display's menu-bar replica can deliver the global release
                // before forwarding our button action. Give that action first refusal.
                pendingMenuDismissal?.cancel()
                let dismissal = DispatchWorkItem { [weak self] in
                    guard let self, self.statusItem.button?.window?.frame.contains(point) != true else { return }
                    self.closePopover()
                }
                pendingMenuDismissal = dismissal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: dismissal)
                return
            }
        }
        closePopover()
    }

    private func positionPanel(_ size: NSSize) {
        guard let frame = panelScreen?.visibleFrame else { return }
        let x = max(frame.minX, min(panelAnchor.x - size.width / 2, frame.maxX - size.width))
        quotaPanel.setFrame(NSRect(x: x, y: panelAnchor.y - size.height, width: size.width, height: size.height), display: true)
    }

    func closePopover() {
        pendingMenuDismissal?.cancel()
        pendingMenuDismissal = nil
        popoverController.setPanelVisible(false)
        quotaPanel.orderOut(nil)
        if let outsideGlobal { NSEvent.removeMonitor(outsideGlobal); self.outsideGlobal = nil }
        if let outsideLocal { NSEvent.removeMonitor(outsideLocal); self.outsideLocal = nil }
    }

    private func showContextMenu() {
        checkin.refreshFromDisk()
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let display = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        display.submenu = menuBarProviderMenu()
        menu.addItem(display)

        if !checkin.hasCheckedInToday {
            let checkinItem = NSMenuItem(
                title: "一键签到 Trae / WorkBuddy / 豆包",
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

    private func menuBarProviderMenu() -> NSMenu {
        let menu = NSMenu()
        let mode = service.config.string("menuBarMode", default: "auto")
        let current = service.config.string("menuBarProvider", default: "auto")

        let auto = NSMenuItem(title: "自动（最近使用）", action: #selector(chooseMenuBarProvider(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = "auto"
        auto.state = mode == "auto" ? .on : .off
        menu.addItem(auto)
        let merged = NSMenuItem(title: "显示最紧张服务", action: #selector(chooseMenuBarProvider(_:)), keyEquivalent: "")
        merged.target = self
        merged.representedObject = "merged"
        merged.state = mode == "merged" ? .on : .off
        menu.addItem(merged)
        menu.addItem(.separator())

        for descriptor in ProviderRegistry.all where !service.config.stringArray("hiddenProviders").contains(descriptor.id) {
            let id = descriptor.id
            let item = NSMenuItem(title: descriptor.shortName, action: #selector(chooseMenuBarProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (mode == "fixed" && current == id) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseMenuBarProvider(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String ?? "auto"
        if value == "auto" {
            service.config.set("menuBarMode", "auto")
        } else if value == "merged" {
            service.config.set("menuBarMode", "merged")
        } else {
            service.config.set("menuBarMode", "fixed")
            service.config.set("menuBarProvider", value)
        }
        do {
            try service.config.save()
        } catch {
            log("save menu bar provider failed: \(error)")
        }
        activeProviderID = (value == "auto" || value == "merged") ? nil : value
        lastUsage.removeAll()
        pendingUsage = nil
        render()
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
            settingsController?.mergedMenuBarModeAvailable = true
        }
        settingsController?.showWindow(nil)
        // LSUIElement 的 accessory app 在部分 macOS 版本上无法仅靠 activate
        // 获得键盘焦点；临时进入 regular，等窗口成为 key 后再退回菜单栏模式。
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKey()
        settingsController?.window?.orderFrontRegardless()
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.settingsController?.window else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeKey()
            }
        }
        if wasAccessory, let settingsWindow = settingsController?.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: settingsWindow,
                queue: .main
            ) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
        }
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
        self.contentTintColor = Theme.accent
        self.target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { onTap() }
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
