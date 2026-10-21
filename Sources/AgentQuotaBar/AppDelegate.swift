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
    private var timer: Timer?
    private var checkinTimer: Timer?
    private var popoverController: QuotaPopoverViewController!
    private var settingsController: SettingsWindowController?
    private var setupControllers: [String: SetupWindowController] = [:]
    private var activeProviderID: String?
    private var lastSignatures: [String: String] = [:]
    private var lastSwitchAt = Date.distantPast
    private let switchCooldown: TimeInterval = 10
    private var didPopoverSnapshot = false
    private var didStatusSnapshot = false
    private var didIconPreview = false
    private var loginPreview: WebLoginWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        QuotaStyle.apply(service.config)
        BackgroundCheckin.installIfNeeded()
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
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        service.onChange = { [weak self] in
            DispatchQueue.main.async { self?.render() }
        }

        checkin.onUpdate = { [weak self] in
            self?.refreshCheckinUI()
        }
        checkinTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.checkin.runIfNeeded()
        }
        if let checkinTimer { RunLoop.main.add(checkinTimer, forMode: .common) }

        render()
        refreshCheckinUI()
        service.refresh()
        scheduleTimer()
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
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.render()
        }
    }

    // MARK: 开发调试（AQB_* 环境变量，不影响正常使用）

    private func toggleAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        service.config.set("appearance", dark ? "light" : "dark")
        try? service.config.save()
        applyAppearance()
        popoverController.refreshAppearance()
        settingsController?.reloadForAppearance()
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
            }
        }

        if let appearance = env["AQB_TEST_APPEARANCE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.service.config.set("appearance", appearance)
                try? self.service.config.save()
                self.applyAppearance()
                self.popoverController.refreshAppearance()
                self.settingsController?.reloadForAppearance()
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

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(service.config.refreshSeconds), repeats: true) { [weak self] _ in
            self?.service.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func render() {
        QuotaStyle.apply(service.config)
        log("render providers=\(service.snapshot?.providers.count ?? -1) refreshing=\(service.isRefreshing) err=\(service.errorMessage ?? "nil")")
        guard let button = statusItem.button else { return }

        let mode = service.config.string("menuBarMode", default: "auto")
        let hidden = Set(service.config.stringArray("hiddenProviders"))
        let visibleSnapshot = service.snapshot?.excluding(hidden)
        if let snapshot = visibleSnapshot {
            updateActiveProvider(snapshot: snapshot, mode: mode)
        }

        if let snapshot = visibleSnapshot {
            let providerID = activeProviderID
                ?? service.config.string("menuBarProvider", default: "auto")
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
                    ink: menuBarInk()
                )
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
                let name = ProviderStyles.style(for: id).shortName
                button.toolTip = "\(name)\n\(item.tooltip)"
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
            button.toolTip = service.errorMessage ?? "点击打开面板"
        }

        popoverController.update(
            snapshot: visibleSnapshot,
            error: service.errorMessage,
            isRefreshing: service.isRefreshing
        )
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
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
    private func updateActiveProvider(snapshot: QuotaSnapshot, mode: String) {
        let candidates = snapshot.providers.filter { $0.status != "disabled" }
        var signatures: [String: String] = [:]
        for provider in candidates {
            signatures[provider.id] = snapshot.signature(for: provider)
        }

        if mode == "fixed" {
            let fixed = service.config.string("menuBarProvider", default: "auto")
            if snapshot.provider(withID: fixed) != nil {
                activeProviderID = fixed
                lastSignatures = signatures
                return
            }
        }

        var changed: [String] = []
        for provider in candidates where provider.isUsable {
            if let old = lastSignatures[provider.id], old != signatures[provider.id] {
                changed.append(provider.id)
            }
        }

        let now = Date()
        if !changed.isEmpty, now.timeIntervalSince(lastSwitchAt) >= switchCooldown {
            if let current = activeProviderID, changed.contains(current) {
                // 当前这家自己变了，保持不动
            } else {
                activeProviderID = changed.first
                lastSwitchAt = now
            }
        }

        if activeProviderID == nil || snapshot.provider(withID: activeProviderID!) == nil {
            activeProviderID = snapshot.worstProviderID()
        }
        if let id = activeProviderID,
           let provider = snapshot.provider(withID: id),
           provider.status == "error" || provider.status == "unconfigured" {
            activeProviderID = snapshot.worstProviderID()
        }

        lastSignatures = signatures
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if service.snapshot == nil { service.refresh() }
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
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let checkinItem = NSMenuItem(title: "立即签到", action: #selector(checkinNowMenu), keyEquivalent: "")
        checkinItem.target = self
        menu.addItem(checkinItem)

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
        service.refresh()
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
                    self?.scheduleTimer()
                    self?.service.refresh()
                },
                onOpenSetup: { [weak self] provider in
                    self?.openSetup(provider: provider)
                },
                onAppearanceChanged: { [weak self] in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.applyAppearance()
                        self.popoverController.refreshAppearance()
                        self.settingsController?.reloadForAppearance()
                    }
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
            self?.service.refresh()
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

func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    monospaced: Bool = false
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = monospaced
        ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    label.textColor = color.resolvedForAppearance()
    label.lineBreakMode = .byTruncatingTail
    return label
}

func wrappingLabel(_ text: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = color.resolvedForAppearance()
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = width
    return label
}
