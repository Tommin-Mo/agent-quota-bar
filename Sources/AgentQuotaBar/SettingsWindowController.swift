import AppKit

private var appVersionText: String {
    let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.4"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    return "v\(short) · build \(build)"
}

/// 玻璃面板：NSVisualEffectView + 高光边，接近 Liquid Glass 的层次。
func makeGlassPanel(cornerRadius: CGFloat, material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

    let highlight = CAGradientLayer()
    highlight.colors = [
        NSColor.white.withAlphaComponent(0.12).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    highlight.startPoint = CGPoint(x: 0.5, y: 1)
    highlight.endPoint = CGPoint(x: 0.5, y: 0.45)
    highlight.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
    highlight.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    view.layer?.insertSublayer(highlight, at: 0)
    return view
}

final class AccentButton: NSButton {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let fill = isHighlighted ? Theme.accent.blended(withFraction: 0.12, of: .black) ?? Theme.accent : Theme.accent
        fill.setFill()
        path.fill()
        // 深色外观的 accent 是亮青色，白字对比不足；改用深色文字保持可读。
        let dark = Theme.isDark(effectiveAppearance)
        let titleColor = dark
            ? Theme.background.resolvedForAppearance(effectiveAppearance)
            : NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: titleColor,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        super.mouseDown(with: event)
        isHighlighted = false
    }
}

final class AccentSwitch: NSControl {
    var isOn: Bool = true {
        didSet {
            needsDisplay = true
            if oldValue != isOn { sendAction(action, to: target) }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRingType = .exterior
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.charactersIgnoringModifiers == " " {
            isOn.toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 1, y: 3, width: 36, height: 16)
        let path = NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8)
        (isOn ? Theme.accent : Theme.separator).setFill()
        path.fill()

        let knobSize: CGFloat = 12
        let knobX = isOn ? track.maxX - knobSize - 2 : track.minX + 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 2, width: knobSize, height: knobSize))
        NSColor.white.setFill()
        knob.fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isOn.toggle()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }
    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        return true
    }
}

final class SidebarButton: NSButton {
    var selected = false {
        didSet { applyStyle() }
    }
    private var hovering = false
    private let indicator = NSView()

    init(title: String, symbol: String, action: Selector, target: AnyObject) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.alignment = .left
        self.imagePosition = .imageLeading
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        self.imageScaling = .scaleProportionallyDown
        self.font = .systemFont(ofSize: 14, weight: .medium)
        self.wantsLayer = true
        self.layer?.cornerRadius = 7
        self.layer?.cornerCurve = .continuous
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1
        indicator.layer?.backgroundColor = Theme.accent.resolvedForAppearance().cgColor
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            indicator.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            indicator.widthAnchor.constraint(equalToConstant: 2),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    func refreshAppearance() {
        applyStyle()
        needsDisplay = true
    }

    private func applyStyle() {
        indicator.isHidden = true
        needsDisplay = true
        if selected {
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.09).cgColor
            contentTintColor = Theme.text
        } else if hovering {
            layer?.backgroundColor = Theme.text.withAlphaComponent(0.05).cgColor
            contentTintColor = Theme.secondary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = Theme.secondary
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private let service: QuotaService
    private let checkin: CheckinService
    private let onSaved: () -> Void
    private let onOpenSetup: (String) -> Void
    private let onAppearanceChanged: () -> Void
    private let onCheckin: () -> Void

    private let refreshPopup = GlideSelect(frame: .zero)
    private let proxyField = QuotaTextField()
    private let menuBarModePopup = GlideSelect(frame: .zero)
    private let fixedProviderPopup = GlideSelect(frame: .zero)
    private let loginSwitch = AccentSwitch()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let scaleSlider = WakeSlider()
    private let scaleLabel = NSTextField(labelWithString: "125%")
    private let scalePreview = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")
    private weak var saveButton: AccentButton?
    private var suppressDirty = true
    private let appearanceControl = NSSegmentedControl()
    private let checkinSwitch = AccentSwitch()
    private let checkinHourPopup = GlideSelect(frame: .zero)
    private let checkinStatusLabel = NSTextField(labelWithString: "")
    private let checkinTitleLabel = NSTextField(labelWithString: "今日签到")
    private let checkinButton = NSButton(title: "立即签到", target: nil, action: nil)
    private let warningSlider = ScrubValueField()
    private let dangerSlider = ScrubValueField()
    private let notifySwitch = AccentSwitch()
    private let notifyPercentField = QuotaTextField()
    private let notifyStatusLabel = NSTextField(labelWithString: "")
    private let permissionMark = StatusMarkView()
    private let testNotifyButton = NSButton(title: "测试", target: nil, action: nil)
    private let notificationSettingsButton = NSButton(title: "权限设置", target: nil, action: nil)
    private var creditThresholdFields: [String: NSTextField] = [:]
    private var colorWells: [NSColorWell] = []
    private weak var scrollView: NSScrollView?

    private let contentStack = FlippedStackView()
    private var pageViews: [NSView] = []
    private var navButtons: [SidebarButton] = []
    private var selectedPage = 0
    private var providerStatusViews: [String: (dot: ThemedSurfaceView, text: NSTextField)] = [:]
    private var visibilitySwitches: [String: AccentSwitch] = [:]
    private var checkinDetailStatusLabels: [String: NSTextField] = [:]
    private var accountPopups: [String: NSPopUpButton] = [:]
    private var accountManager: AccountManagerWindowController?

    // MARK: - 可选 UI 数据钩子（AccountStore / 合并图标后端未落地时保持隐藏）
    /// providerID -> 账户列表；为空/只有一个账户时该行不显示选择器。
    /// 使用 Models.ProviderAccount，避免假设后端把账户拍平成字符串。
    var accountsProvider: ((String) -> [ProviderAccount])? {
        didSet { reloadAccounts() }
    }
    /// providerID -> 当前账户 id（ProviderAccount.id）。
    var activeAccountProvider: ((String) -> String?)? {
        didSet { reloadAccounts() }
    }
    /// 用户在选择器里切换账户：(providerID, accountID)；由后端/AppDelegate 负责持久化。
    var onSelectAccount: ((String, String) -> Void)?
    /// 未注入钩子时直接使用 AccountStore；有钩子时以钩子为准。
    private lazy var accountStore = AccountStore(config: service.config)
    /// AppDelegate + MenuBarIcon 支持 `menuBarMode == "merged"` 后再置为 true。
    var mergedMenuBarModeAvailable = false {
        didSet { populateMenuBarModePopup() }
    }

    private let providerOrder = ["codex", "deepseek", "opencode", "trae", "workbuddy"]
    private let refreshOptions: [(String, Int)] = [("1 分钟", 60), ("5 分钟", 300), ("15 分钟", 900), ("30 分钟", 1800)]

    init(
        service: QuotaService,
        checkin: CheckinService,
        onSaved: @escaping () -> Void,
        onOpenSetup: @escaping (String) -> Void,
        onAppearanceChanged: @escaping () -> Void,
        onCheckin: @escaping () -> Void
    ) {
        self.service = service
        self.checkin = checkin
        self.onSaved = onSaved
        self.onOpenSetup = onOpenSetup
        self.onAppearanceChanged = onAppearanceChanged
        self.onCheckin = onCheckin

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent 额度设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = buildContent()
        selectPage(selectedPage)
        loadValues()
        suppressDirty = false
        updateProviderStatuses(service.snapshot)
        reloadAccounts()
        NotificationCenter.default.addObserver(
            self, selector: #selector(quotaUpdated(_:)), name: .quotaUpdated, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - 外壳

    private func buildContent() -> NSView {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        contentStack.removeFromSuperview()

        let container = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
        container.wantsLayer = true
        container.surfaceColor = Theme.background

        let sidebar = ThemedSurfaceView()
        sidebar.wantsLayer = true
        sidebar.surfaceColor = Theme.surfaceAlt
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        buildSidebar(in: sidebar)

        let sidebarLine = ThemedSurfaceView()
        sidebarLine.wantsLayer = true
        sidebarLine.surfaceColor = NSColor.separatorColor.withAlphaComponent(0.35)
        sidebarLine.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebarLine)

        let saveBar = ThemedSurfaceView()
        saveBar.wantsLayer = true
        saveBar.surfaceColor = Theme.background
        saveBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveBar)

        let saveBarLine = ThemedSurfaceView()
        saveBarLine.wantsLayer = true
        saveBarLine.surfaceColor = NSColor.separatorColor.withAlphaComponent(0.35)
        saveBarLine.translatesAutoresizingMaskIntoConstraints = false
        saveBar.addSubview(saveBarLine)

        let scroll = NSScrollView()
        self.scrollView = scroll
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            sidebarLine.topAnchor.constraint(equalTo: container.topAnchor),
            sidebarLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarLine.bottomAnchor.constraint(equalTo: saveBar.topAnchor),
            sidebarLine.widthAnchor.constraint(equalToConstant: 0.5),

            saveBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            saveBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            saveBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            saveBar.heightAnchor.constraint(equalToConstant: 52),

            saveBarLine.topAnchor.constraint(equalTo: saveBar.topAnchor),
            saveBarLine.leadingAnchor.constraint(equalTo: saveBar.leadingAnchor),
            saveBarLine.trailingAnchor.constraint(equalTo: saveBar.trailingAnchor),
            saveBarLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: saveBar.topAnchor, constant: -10),
        ])

        buildSaveBar(in: saveBar)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(contentStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.detachesHiddenViews = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
        ])

        let fit = document.heightAnchor.constraint(greaterThanOrEqualTo: contentStack.heightAnchor, constant: 0)
        fit.priority = NSLayoutConstraint.Priority.defaultHigh
        fit.isActive = true

        pageViews = [makeGeneralPage(), makeMenuBarPage(), makeServicesPage(), makeAlertsPage()]
        for page in pageViews {
            page.isHidden = true
            contentStack.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        let startPage = Int(ProcessInfo.processInfo.environment["AQB_SETTINGS_PAGE"] ?? "0") ?? 0
        selectPage(min(max(0, startPage), pageViews.count - 1))

        return container
    }

    private func buildTopBar(in bar: NSView) {
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent 额度")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        mark.contentTintColor = Theme.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 28).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let title = label("Agent 额度", size: 17, weight: .semibold)
        let subtitle = label(appVersionText, size: 10.5, color: Theme.tertiary)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0

        let brand = NSStackView(views: [mark, titles])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 8
        brand.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(brand)

        navButtons.removeAll()
        let nav = NSStackView()
        nav.orientation = .horizontal
        nav.alignment = .centerY
        nav.spacing = 4
        nav.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(nav)

        let items = [
            ("通用", "gearshape"),
            ("菜单栏", "menubar.rectangle"),
            ("服务", "square.stack.3d.up"),
            ("提醒", "bell"),
        ]
        for (index, item) in items.enumerated() {
            let button = SidebarButton(title: item.0, symbol: item.1,
                                       action: #selector(navTapped(_:)), target: self)
            button.tag = index
            button.alignment = .center
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.imageHugsTitle = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 112).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            nav.addArrangedSubview(button)
            navButtons.append(button)
        }

        let line = ThemedSurfaceView()
        line.wantsLayer = true
        line.surfaceColor = NSColor.separatorColor.withAlphaComponent(0.35)
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 84),
            brand.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            nav.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -32),
            nav.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func buildSidebar(in sidebar: NSView) {
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent 额度")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        mark.contentTintColor = Theme.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 28).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let title = label("Agent 额度", size: 17, weight: .semibold)
        let subtitle = label(appVersionText, size: 10.5, color: Theme.tertiary)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0

        let header = NSStackView(views: [mark, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(header)

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)

        let items = [
            ("通用", "gearshape"),
            ("菜单栏", "menubar.rectangle"),
            ("服务", "square.stack.3d.up"),
            ("提醒", "bell"),
        ]
        for (index, item) in items.enumerated() {
            let button = SidebarButton(title: item.0, symbol: item.1,
                                       action: #selector(navTapped(_:)), target: self)
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            button.widthAnchor.constraint(equalToConstant: 184).isActive = true
            nav.addArrangedSubview(button)
            navButtons.append(button)
        }

        let background = label("后台签到已启用", size: 10, weight: .medium, color: Theme.success)
        background.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(background)
        let configButton = NSButton(title: "打开配置文件", target: self, action: #selector(openConfig))
        configButton.isBordered = false
        configButton.font = .systemFont(ofSize: 10.5)
        configButton.contentTintColor = Theme.accent
        configButton.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(configButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),

            nav.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),

            background.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            background.bottomAnchor.constraint(equalTo: configButton.topAnchor, constant: -5),
            configButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            configButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
        ])
    }

    private func buildSaveBar(in bar: NSView) {
        let openConfig = NSButton(title: "打开配置文件（JSON）", target: self, action: #selector(openConfig))
        openConfig.toolTip = "在默认编辑器中打开 config.json；会直接修改配置"
        openConfig.isBordered = false
        openConfig.font = .systemFont(ofSize: 11)
        openConfig.contentTintColor = Theme.accent

        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = Theme.secondary
        hintLabel.setAccessibilityLabel("保存状态")
        hintLabel.toolTip = "设置会即时保存；不需要手动点保存"
        hintLabel.stringValue = "更改会自动保存"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [openConfig, spacer, hintLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    // MARK: - 页面

    private func pageHeader(_ title: String, _ subtitle: String) -> NSView {
        let t = label(title, size: 22, weight: .semibold)
        let s = label(subtitle, size: 11, color: Theme.secondary)
        let stack = NSStackView(views: [t, s])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setContentHuggingPriority(.required, for: .vertical)
        return stack
    }

    private func makeGeneralPage() -> NSView {
        refreshPopup.removeAllItems()
        for (title, seconds) in refreshOptions {
            refreshPopup.addItem(withTitle: title)
            refreshPopup.lastItem?.representedObject = seconds
        }
        refreshPopup.font = .systemFont(ofSize: 12)
        refreshPopup.bezelStyle = .rounded
        refreshPopup.controlSize = .large
        refreshPopup.setAccessibilityLabel("刷新频率")
        refreshPopup.target = self
        refreshPopup.action = #selector(refreshOptionChanged)
        refreshPopup.translatesAutoresizingMaskIntoConstraints = false
        refreshPopup.widthAnchor.constraint(equalToConstant: 96).isActive = true
        refreshPopup.setContentHuggingPriority(.required, for: .horizontal)
        refreshPopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        proxyField.font = .systemFont(ofSize: 12)
        proxyField.bezelStyle = .roundedBezel
        proxyField.controlSize = .large
        proxyField.placeholderString = "auto / http://127.0.0.1:7897 / off"
        proxyField.setAccessibilityLabel("系统代理")
        proxyField.delegate = self
        proxyField.translatesAutoresizingMaskIntoConstraints = false
        proxyField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged)
        loginSwitch.setAccessibilityLabel("开机自启动")
        loginStatusLabel.font = .systemFont(ofSize: 10)
        loginStatusLabel.textColor = Theme.tertiary
        loginStatusLabel.setAccessibilityLabel("开机自启动状态")

        let loginColumn = NSStackView(views: [loginSwitch, loginStatusLabel])
        loginColumn.orientation = .vertical
        loginColumn.alignment = .trailing
        loginColumn.spacing = 3


        appearanceControl.segmentCount = 3
        appearanceControl.setLabel("跟随系统", forSegment: 0)
        appearanceControl.setLabel("浅色", forSegment: 1)
        appearanceControl.setLabel("深色", forSegment: 2)
        appearanceControl.selectedSegment = {
            switch service.config.string("appearance", default: "system") {
            case "light": return 1
            case "dark": return 2
            default: return 0
            }
        }()
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.setAccessibilityLabel("外观")
        appearanceControl.translatesAutoresizingMaskIntoConstraints = false
        appearanceControl.widthAnchor.constraint(equalToConstant: 220).isActive = true

        checkinSwitch.isOn = checkin.isAutoEnabled
        checkinSwitch.target = self
        checkinSwitch.action = #selector(checkinAutoChanged)
        checkinSwitch.setAccessibilityLabel("自动签到")
        checkinSwitch.translatesAutoresizingMaskIntoConstraints = false

        checkinHourPopup.removeAllItems()
        for hour in 0...23 {
            checkinHourPopup.addItem(withTitle: String(format: "%02d:00", hour))
            checkinHourPopup.lastItem?.representedObject = hour
        }
        checkinHourPopup.selectItem(at: min(23, max(0, service.config.int("checkin.hour", default: 9))))
        checkinHourPopup.font = .systemFont(ofSize: 12)
        checkinHourPopup.bezelStyle = .rounded
        checkinHourPopup.controlSize = .large
        checkinHourPopup.target = self
        checkinHourPopup.action = #selector(checkinHourChanged)
        checkinHourPopup.setAccessibilityLabel("签到时间")
        checkinHourPopup.translatesAutoresizingMaskIntoConstraints = false
        checkinHourPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        checkinStatusLabel.font = .systemFont(ofSize: 10)
        checkinStatusLabel.textColor = Theme.tertiary
        checkinStatusLabel.setAccessibilityLabel("签到状态")
        checkinButton.bezelStyle = .inline
        checkinButton.isBordered = false
        checkinButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        checkinButton.contentTintColor = Theme.accent
        checkinButton.target = self
        checkinButton.action = #selector(checkinNow)
        let checkinStatusRow = NSStackView(views: [checkinStatusLabel, checkinButton])
        checkinStatusRow.orientation = .horizontal
        checkinStatusRow.spacing = 10
        checkinStatusRow.alignment = .centerY

        let automationGroup = groupCard([
            controlRow("自动签到", checkinSwitch, caption: nil),
            separator(),
            controlRow("签到时间", checkinHourPopup, caption: nil),
            separator(),
            controlRow("签到状态", checkinStatusRow, caption: nil),
        ])

        let preferencesGroup = groupCard([
            controlRow("刷新频率", refreshPopup, caption: "打开 App 后的自动刷新间隔；后台采样独立运行。"),
            separator(),
            controlRow("系统代理", proxyField, caption: "auto 使用系统代理；也可填 http://127.0.0.1:7897；off 关闭。"),
            separator(),
            controlRow("外观", appearanceControl, caption: "只影响 AgentQuotaBar，不修改系统外观。"),
            separator(),
            controlRow("开机自启动", loginColumn, caption: nil),
        ])

        return composePage([
            pageHeader("通用", ""),
            groupLabel("偏好"),
            preferencesGroup,
            groupLabel("自动化"),
            automationGroup,
        ])
    }

    private func makeCheckinPage() -> NSView {
        checkinSwitch.isOn = service.config.bool("checkin.auto", default: true)
        checkinSwitch.target = self
        checkinSwitch.action = #selector(checkinAutoChanged)
        checkinSwitch.translatesAutoresizingMaskIntoConstraints = false

        checkinHourPopup.removeAllItems()
        for hour in 0...23 {
            checkinHourPopup.addItem(withTitle: String(format: "%02d:00", hour))
            checkinHourPopup.lastItem?.representedObject = hour
        }
        checkinHourPopup.selectItem(at: min(23, max(0, service.config.int("checkin.hour", default: 9))))
        checkinHourPopup.font = .systemFont(ofSize: 12)
        checkinHourPopup.bezelStyle = .rounded
        checkinHourPopup.controlSize = .large
        checkinHourPopup.target = self
        checkinHourPopup.action = #selector(checkinHourChanged)
        checkinHourPopup.translatesAutoresizingMaskIntoConstraints = false
        checkinHourPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        checkinTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        checkinTitleLabel.textColor = Theme.text
        checkinStatusLabel.font = .systemFont(ofSize: 12)
        checkinStatusLabel.textColor = Theme.secondary
        checkinStatusLabel.lineBreakMode = .byTruncatingTail

        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "签到") ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let text = NSStackView(views: [checkinTitleLabel, checkinStatusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        checkinButton.bezelStyle = .inline
        checkinButton.isBordered = false
        checkinButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        checkinButton.contentTintColor = Theme.accent
        checkinButton.target = self
        checkinButton.action = #selector(checkinNow)
        checkinButton.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let statusRow = NSStackView(views: [icon, text, spacer, checkinButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 12
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let statusCard = makePaperPanel(cornerRadius: 14)
        statusCard.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 18),
            statusRow.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -18),
            statusRow.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 18),
            statusRow.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -18),
        ])

        let settingsCard = groupCard([
            controlRow("自动签到", checkinSwitch, caption: nil),
            separator(),
            controlRow("签到时间", checkinHourPopup, caption: nil),
        ])

        let streak = service.config.int("checkin.workbuddyStreak", default: 0)
        let detailCard = groupCard([
            checkinProviderRow("trae", subtitle: "每日 +100 积分"),
            separator(),
            checkinProviderRow("workbuddy", subtitle: streak > 0 ? "连续 \(streak) 天 · 每日 +100" : "连续签到有额外奖励"),
        ])

        return composePage([
            pageHeader("签到", ""),
            statusCard,
            groupLabel("计划"),
            settingsCard,
            groupLabel("今日明细"),
            detailCard,
        ])
    }

    private func checkinProviderRow(_ id: String, subtitle: String) -> NSView {
        let style = ProviderStyles.style(for: id)
        let avatar = AvatarView(letter: style.letter, color: style.color, size: 22, provider: id)
        let name = label(style.shortName, size: 12, weight: .medium)
        let detail = label(subtitle, size: 10, color: Theme.tertiary)
        let title = NSStackView(views: [name, detail])
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 1

        let status = label(checkin.hasCheckedInToday ? "已签到" : "待签到", size: 10.5, weight: .medium,
                           color: checkin.hasCheckedInToday ? Theme.success : Theme.tertiary)
        checkinDetailStatusLabels[id] = status
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [avatar, title, spacer, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        return row
    }

    /// 合并图标需要 AppDelegate 真正渲染 "merged" 才暴露，避免给用户一个无效选项。
    private func populateMenuBarModePopup() {
        let current = menuBarModePopup.selectedItem?.representedObject as? String
            ?? service.config.string("menuBarMode", default: "auto")
        menuBarModePopup.removeAllItems()
        menuBarModePopup.addItem(withTitle: "自动切换（最近使用）")
        menuBarModePopup.lastItem?.representedObject = "auto"
        menuBarModePopup.addItem(withTitle: "固定一家")
        menuBarModePopup.lastItem?.representedObject = "fixed"
        if mergedMenuBarModeAvailable || current == "merged" {
            menuBarModePopup.addItem(withTitle: "合并显示（比例最低）")
            menuBarModePopup.lastItem?.representedObject = "merged"
        }
        if let index = menuBarModePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            menuBarModePopup.selectItem(at: index)
        }
    }

    private func makeMenuBarPage() -> NSView {
        populateMenuBarModePopup()
        menuBarModePopup.font = .systemFont(ofSize: 12)
        menuBarModePopup.bezelStyle = .rounded
        menuBarModePopup.controlSize = .large
        menuBarModePopup.target = self
        menuBarModePopup.action = #selector(menuBarModeChanged)
        menuBarModePopup.setAccessibilityLabel("菜单栏显示方式")
        menuBarModePopup.translatesAutoresizingMaskIntoConstraints = false
        menuBarModePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        fixedProviderPopup.removeAllItems()
        for id in providerOrder {
            fixedProviderPopup.addItem(withTitle: ProviderStyles.style(for: id).shortName)
            fixedProviderPopup.lastItem?.representedObject = id
        }
        fixedProviderPopup.font = .systemFont(ofSize: 12)
        fixedProviderPopup.bezelStyle = .rounded
        fixedProviderPopup.controlSize = .large
        fixedProviderPopup.target = self
        fixedProviderPopup.action = #selector(fixedProviderSelected)
        fixedProviderPopup.setAccessibilityLabel("固定显示的服务")
        fixedProviderPopup.translatesAutoresizingMaskIntoConstraints = false
        fixedProviderPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        scaleSlider.minValue = 0.5
        scaleSlider.maxValue = 1.5
        scaleSlider.value = service.menuBarIconScaleFactor
        scaleSlider.onChange = { [weak self] _ in self?.scaleChanged() }
        scaleSlider.setAccessibilityLabel("菜单栏图标大小")
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true

        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = Theme.secondary
        scaleLabel.stringValue = String(format: "%.2f×", scaleSlider.value)

        let resetScale = NSButton(title: "恢复默认", target: self, action: #selector(resetScale))
        resetScale.bezelStyle = .inline
        resetScale.isBordered = false
        resetScale.font = .systemFont(ofSize: 12)
        resetScale.contentTintColor = Theme.secondary

        scalePreview.imageScaling = .scaleProportionallyUpOrDown
        scalePreview.translatesAutoresizingMaskIntoConstraints = false
        scalePreview.wantsLayer = true
        scalePreview.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.52, alpha: 1).cgColor
        scalePreview.layer?.cornerRadius = 7
        scalePreview.widthAnchor.constraint(equalToConstant: 72).isActive = true
        scalePreview.heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateScalePreview()

        let scaleRow = NSStackView(views: [scaleSlider, scaleLabel, resetScale, scalePreview])
        scaleRow.orientation = .horizontal
        scaleRow.alignment = .centerY
        scaleRow.spacing = 10

        let resetOrder = NSButton(title: "恢复默认顺序", target: self, action: #selector(resetOrder))
        resetOrder.bezelStyle = .rounded
        resetOrder.font = .systemFont(ofSize: 11)

        let group1 = groupCard([
            controlRow("显示方式", menuBarModePopup, caption: "自动切换优先跟随最近使用的服务。"),
            separator(),
            controlRow("固定显示", fixedProviderPopup, caption: "仅当显示方式为「固定一家」时可用。"),
        ])
        let group2 = groupCard([
            controlRow("图标大小", scaleRow, caption: "以当前大小为 1.00× 基准；可调 0.50×–1.50×。"),
        ])
        let group3 = groupCard([
            controlRow("面板顺序", resetOrder, caption: "在主面板拖动行排序；这里只恢复默认顺序。"),
        ])
        return composePage([
            pageHeader("菜单栏", ""),
            groupLabel("显示"),
            group1,
            groupLabel("图标"),
            group2,
            groupLabel("顺序"),
            group3,
        ])
    }

    private func makeServicesPage() -> NSView {
        var rows: [NSView] = []
        for (index, id) in providerOrder.enumerated() {
            if index > 0 { rows.append(separator()) }
            rows.append(providerRow(id))
        }
        let privacy = groupCard([
            controlRow(
                "配置文件",
                label(service.config.url.path, size: 10, color: Theme.secondary),
                caption: "本机 0600；不会上传到网络。"
            ),
            separator(),
            controlRow(
                "浏览器 Cookie",
                label("仅 OpenCode / WorkBuddy", size: 11, color: Theme.secondary),
                caption: "自动 Cookie 只在本机 Chrome 登录态失效时回退；首次可能弹钥匙串授权。"
            ),
            separator(),
            controlRow(
                "凭据管理",
                label("账户管理 → 新增 / 编辑 / 切换", size: 11, color: Theme.secondary),
                caption: "切到哪个账号，collector 就查哪个账号。"
            ),
        ])
        return composePage([
            pageHeader("服务", ""),
            groupCard(rows),
            label("关闭的服务会同时从菜单栏和面板移除。", size: 11, color: Theme.tertiary),
            groupLabel("凭证与隐私"),
            privacy,
        ])
    }

    private func makeAlertsPage() -> NSView {
        colorWells = []
        for (index, color) in [QuotaStyle.healthyColor, QuotaStyle.warningColor, QuotaStyle.dangerColor].enumerated() {
            let well = NSColorWell()
            well.colorWellStyle = .minimal
            well.color = color
            well.tag = index
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.setAccessibilityLabel(["充足颜色", "警戒颜色", "危险颜色"][index])
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorWells.append(well)
        }

        for (label, field) in [("警戒阈值", warningSlider), ("危险阈值", dangerSlider)] {
            field.minValue = 1
            field.maxValue = 99
            field.step = 1
            field.suffix = "%"
            field.onChange = { [weak self] _ in self?.thresholdChanged() }
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 88).isActive = true
        }
        warningSlider.value = QuotaStyle.warningPercent
        dangerSlider.maxValue = max(2, QuotaStyle.warningPercent - 1)
        dangerSlider.value = min(QuotaStyle.dangerPercent, dangerSlider.maxValue)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 8
        for (index, title) in ["充足", "警戒", "危险"].enumerated() {
            colorRow.addArrangedSubview(label(title, size: 12, color: Theme.secondary))
            colorRow.addArrangedSubview(colorWells[index])
            if index < 2 { colorRow.setCustomSpacing(16, after: colorWells[index]) }
        }
        let colorGroup = groupCard([
            controlRow("颜色", colorRow, caption: "点击色块修改；只影响面板和菜单栏。"),
            separator(),
            controlRow("警戒阈值", warningSlider, caption: "1–99%；拖动数值或点击输入。低于该比例转为警戒色。"),
            separator(),
            controlRow("危险阈值", dangerSlider, caption: "1% 至「警戒值 − 1」%；低于该比例转为危险色。"),
        ])

        notifySwitch.isOn = service.config.bool("notifications.enabled", default: false)
        notifySwitch.target = self
        notifySwitch.action = #selector(notificationToggled)
        notifySwitch.setAccessibilityLabel("低额度通知")
        notifySwitch.translatesAutoresizingMaskIntoConstraints = false

        notifyPercentField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        notifyPercentField.bezelStyle = .roundedBezel
        notifyPercentField.controlSize = .large
        notifyPercentField.stringValue = String(format: "%.0f", service.config.double("notifications.percent", default: 20))
        notifyPercentField.alignment = .right
        notifyPercentField.setAccessibilityLabel("通知百分比阈值")
        notifyPercentField.translatesAutoresizingMaskIntoConstraints = false
        notifyPercentField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        notifyStatusLabel.stringValue = service.config.bool("notifications.enabled", default: false) ? "已开启" : "已关闭"
        notifyStatusLabel.font = .systemFont(ofSize: 10)
        notifyStatusLabel.textColor = Theme.tertiary
        notifyStatusLabel.lineBreakMode = .byTruncatingTail
        notifyStatusLabel.setAccessibilityLabel("通知权限状态")

        testNotifyButton.bezelStyle = .inline
        testNotifyButton.isBordered = false
        testNotifyButton.font = .systemFont(ofSize: 11)
        testNotifyButton.contentTintColor = Theme.accent
        testNotifyButton.target = self
        testNotifyButton.action = #selector(testNotification)

        testNotifyButton.font = .systemFont(ofSize: 12)
        testNotifyButton.contentTintColor = Theme.accent
        notificationSettingsButton.bezelStyle = .inline
        notificationSettingsButton.isBordered = false
        notificationSettingsButton.font = .systemFont(ofSize: 12)
        notificationSettingsButton.contentTintColor = Theme.secondary
        notificationSettingsButton.target = self
        notificationSettingsButton.action = #selector(openNotificationSettings)

        let notifyControl = NSStackView(views: [notifySwitch, testNotifyButton])
        notifyControl.orientation = .horizontal
        notifyControl.alignment = .centerY
        notifyControl.spacing = 10

        let permissionRow = NSStackView(views: [permissionMark, notifyStatusLabel, notificationSettingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.alignment = .centerY
        permissionRow.spacing = 10

        func thresholdField(_ id: String, fallback: Double) -> NSTextField {
            let field = QuotaTextField()
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.controlSize = .large
            field.alignment = .right
            field.stringValue = String(format: "%.0f", service.config.double("style.thresholds.\(id)", default: fallback))
            field.setAccessibilityLabel("\(id) 阈值")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
            creditThresholdFields[id] = field
            return field
        }

        let pointsRow = NSStackView()
        pointsRow.orientation = .vertical
        pointsRow.alignment = .trailing
        pointsRow.spacing = 3
        for (name, id, fallback) in [("Trae", "trae", 200.0), ("WorkBuddy", "workbuddy", 500.0)] {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            line.addArrangedSubview(label(name, size: 11, color: Theme.tertiary))
            let threshold = thresholdField(id, fallback: fallback)
            line.addArrangedSubview(threshold)
            threshold.trailingAnchor.constraint(equalTo: line.trailingAnchor).isActive = true
            pointsRow.addArrangedSubview(line)
            line.trailingAnchor.constraint(equalTo: pointsRow.trailingAnchor).isActive = true
        }

        let balanceRow = NSStackView()
        balanceRow.orientation = .horizontal
        balanceRow.alignment = .centerY
        balanceRow.spacing = 10
        balanceRow.addArrangedSubview(label("DeepSeek  ¥", size: 11, color: Theme.tertiary))
        balanceRow.addArrangedSubview(thresholdField("deepseek", fallback: 5))

        let notifyRows: [NSView] = [
            controlRow("低额度通知", notifyControl, caption: nil),
            separator(),
            controlRow("通知权限", permissionRow, caption: nil),
            separator(),
            controlRow("百分比阈值", notifyPercentField, caption: nil),
            separator(),
            controlRow("积分阈值", pointsRow, caption: nil),
            separator(),
            controlRow("余额阈值", balanceRow, caption: nil),
        ]

        refreshNotificationStatus()
        return composePage([
            pageHeader("提醒", ""),
            groupLabel("额度颜色"),
            colorGroup,
            groupLabel("低额度提醒"),
            groupCard(notifyRows),
        ])
    }

    private func saveStyle() {
        service.config.set("style.warningPercent", warningSlider.value)
        service.config.set("style.dangerPercent", dangerSlider.value)
        for (index, well) in colorWells.enumerated() {
            let key = ["healthyColor", "warningColor", "dangerColor"][index]
            service.config.set("style.\(key)", QuotaStyle.hex(well.color))
        }
        for (id, field) in creditThresholdFields {
            service.config.set("style.thresholds.\(id)", field.doubleValue)
        }
        service.config.set("notifications.enabled", notifySwitch.isOn)
        service.config.set("notifications.percent", notifyPercentField.doubleValue)
        try? service.config.save()
        QuotaStyle.apply(service.config)
        onSaved()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        saveStyle()
    }

    @objc private func thresholdChanged() {
        dangerSlider.maxValue = max(2, warningSlider.value - 1)
        if dangerSlider.value > dangerSlider.maxValue {
            dangerSlider.value = dangerSlider.maxValue
        }
        saveStyle()
    }

    @objc private func notificationToggled() {
        if notifySwitch.isOn {
            NotificationService.shared.requestAuthorization { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.notifyStatusLabel.stringValue = "系统通知已授权"
                    self.notifyStatusLabel.textColor = Theme.success
                    self.saveStyle()
                } else {
                    self.notifySwitch.isOn = false
                    self.notifyStatusLabel.stringValue = "系统通知已关闭"
                    self.notifyStatusLabel.textColor = Theme.warning
                    self.saveStyle()
                }
            }
        } else {
            notifyStatusLabel.stringValue = "已关闭"
            notifyStatusLabel.textColor = Theme.tertiary
            saveStyle()
        }
    }

    @objc private func testNotification() {
        NotificationService.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized, .provisional, .ephemeral:
                NotificationService.shared.sendTest()
                self.notifyStatusLabel.stringValue = "已发送测试通知"
                self.notifyStatusLabel.textColor = Theme.success
            case .denied:
                self.notifyStatusLabel.stringValue = "系统通知已关闭"
                self.notifyStatusLabel.textColor = Theme.warning
            case .notDetermined:
                NotificationService.shared.requestAuthorization { granted in
                    if granted {
                        NotificationService.shared.sendTest()
                        self.notifyStatusLabel.stringValue = "已授权，测试已发送"
                        self.notifyStatusLabel.textColor = Theme.success
                    } else {
                        self.notifyStatusLabel.stringValue = "未授权"
                        self.notifyStatusLabel.textColor = Theme.warning
                    }
                }
            @unknown default:
                break
            }
        }
    }

    private func refreshNotificationStatus() {
        NotificationService.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized, .provisional, .ephemeral:
                self.permissionMark.state = .authorized
                self.notifyStatusLabel.stringValue = "系统通知已授权"
                self.notifyStatusLabel.textColor = Theme.success
            case .denied:
                self.permissionMark.state = .denied
                self.notifyStatusLabel.stringValue = "系统通知被关闭"
                self.notifyStatusLabel.textColor = Theme.warning
            default:
                self.permissionMark.state = .idle
                self.notifyStatusLabel.stringValue = "尚未授权"
                self.notifyStatusLabel.textColor = Theme.tertiary
            }
        }
    }

    @objc private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func makeAboutPage() -> NSView {
        let config = service.config.url.path
        let path = label(config, size: 11, color: Theme.secondary)
        path.lineBreakMode = .byTruncatingMiddle

        let open = NSButton(title: "打开配置文件（JSON）", target: self, action: #selector(openConfig))
        open.bezelStyle = .rounded
        open.font = .systemFont(ofSize: 11)

        let credits = label("simple-icons (CC0)", size: 10, color: Theme.tertiary)
        credits.lineBreakMode = .byWordWrapping
        credits.maximumNumberOfLines = 2

        let group = groupCard([
            controlRow("配置文件", path, caption: nil),
            separator(),
            controlRow("诊断", open, caption: nil),
            separator(),
            controlRow("说明", credits, caption: nil),
        ])
        return composePage([
            pageHeader("关于", ""),
            group,
        ])
    }

    // MARK: - 组件

    private func composePage(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func groupLabel(_ text: String) -> NSTextField {
        label(text, size: 12, weight: .semibold, color: Theme.tertiary)
    }

    private func groupCard(_ rows: [NSView]) -> NSView {
        let card = ThemedSurfaceView()
        card.wantsLayer = true
        card.surfaceColor = Theme.surface
        card.surfaceBorderColor = NSColor.separatorColor.withAlphaComponent(0.12)
        card.surfaceBorderWidth = 1
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    private func controlRow(_ title: String, _ control: NSView, caption captionText: String?) -> NSView {
        let caption = captionText
        let titleLabel = label(title, size: 14)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let top = NSStackView(views: [titleLabel, spacer, control])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView 会按 alignment rect 分配，部分自定义控件会留下奇怪的右侧缩进；
        // 这里把控件真实 frame 的 trailing 锁到行尾，保证所有控件右边缘一致。
        control.trailingAnchor.constraint(equalTo: top.trailingAnchor).isActive = true

        guard let caption else {
            top.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(top)
            NSLayoutConstraint.activate([
                top.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
                top.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6),
                top.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                top.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            ])
            return wrapper
        }

        let captionLabel = wrappingLabel(caption, size: 11, color: Theme.tertiary, width: 500)
        let column = NSStackView(views: [top, captionLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        captionLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func separator() -> NSView {
        let line = ThemedSurfaceView()
        line.wantsLayer = true
        line.surfaceColor = NSColor.separatorColor.withAlphaComponent(0.16)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func providerRow(_ id: String) -> NSView {
        let style = ProviderStyles.style(for: id)
        let avatar = AvatarView(letter: style.letter, color: style.color, size: 24, provider: id)
        let name = label(style.shortName, size: 12.5, weight: .semibold)

        let dot = ThemedSurfaceView()
        dot.wantsLayer = true
        dot.surfaceColor = Theme.tertiary
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dot.layer?.cornerRadius = 3

        let status = label("未检测", size: 10, color: Theme.secondary)
        let statusRow = NSStackView(views: [dot, status])
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .centerY

        let info = NSStackView(views: [name, statusRow])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let visibility = AccentSwitch()
        visibility.isOn = !service.config.stringArray("hiddenProviders").contains(id)
        visibility.target = self
        visibility.action = #selector(visibilityChanged(_:))
        visibility.identifier = NSUserInterfaceItemIdentifier(id)
        visibility.toolTip = "在面板和菜单栏显示"
        visibility.setAccessibilityLabel("\(style.shortName) 在面板和菜单栏显示")
        visibilitySwitches[id] = visibility

        // 账户选择器：默认隐藏，reloadAccounts() 在后端返回多账户时显示。
        let account = NSPopUpButton()
        account.font = .systemFont(ofSize: 11)
        account.controlSize = .small
        account.target = self
        account.action = #selector(accountChanged(_:))
        account.identifier = NSUserInterfaceItemIdentifier(id)
        account.setAccessibilityLabel("\(style.shortName) 账户")
        account.translatesAutoresizingMaskIntoConstraints = false
        account.widthAnchor.constraint(equalToConstant: 112).isActive = true
        account.isHidden = true
        accountPopups[id] = account

        let autoCookie = AccentSwitch()
        autoCookie.isOn = service.config.bool("providers.\(id).autoCookie", default: false)
        autoCookie.identifier = NSUserInterfaceItemIdentifier(id)
        autoCookie.target = self
        autoCookie.action = #selector(autoCookieChanged(_:))
        autoCookie.toolTip = "自动从 Chrome 读取登录 Cookie（仅 OpenCode / WorkBuddy）"
        autoCookie.setAccessibilityLabel("\(style.shortName) 自动从 Chrome 读取 Cookie")
        autoCookie.isHidden = !(id == "opencode" || id == "workbuddy")
        let autoCookieLabel = label("自动 Cookie", size: 10, color: Theme.tertiary)
        autoCookieLabel.isHidden = autoCookie.isHidden
        autoCookieLabel.toolTip = "仅在没有可用登录态或登录态失效时回退到 Chrome Cookie"
        autoCookieLabel.setContentHuggingPriority(.required, for: .horizontal)
        autoCookieLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        autoCookieLabel.translatesAutoresizingMaskIntoConstraints = false
        autoCookieLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let configure = ClosureButton(title: "配置…") { [weak self] in
            self?.onOpenSetup(id)
        }
        configure.font = .systemFont(ofSize: 11, weight: .medium)

        let manageAccounts = ClosureButton(title: "账户管理") { [weak self] in
            self?.manageAccounts(for: id)
        }
        manageAccounts.font = .systemFont(ofSize: 11, weight: .medium)
        manageAccounts.attributedTitle = NSAttributedString(
            string: "账户管理",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.linkColor,
            ]
        )
        manageAccounts.identifier = NSUserInterfaceItemIdentifier(id)
        manageAccounts.setAccessibilityLabel("管理 \(style.shortName) 账户")
        manageAccounts.toolTip = "添加、编辑、删除或切换账户"

        let row = NSStackView(views: [avatar, info, spacer, autoCookieLabel, autoCookie, account, visibility, manageAccounts, configure])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        providerStatusViews[id] = (dot, status)
        return row
    }

    // MARK: - 多账户

    /// 后端账户数据变化后调用；只有多于一个账户时才显示选择器，避免无意义控件。
    func reloadAccounts() {
        guard isWindowLoaded, !accountPopups.isEmpty else { return }
        for (id, popup) in accountPopups {
            let accounts = accountsProvider?(id) ?? accountStore.accounts(for: id)
            popup.removeAllItems()
            for account in accounts {
                let title = account.label.isEmpty ? (account.account ?? account.id) : account.label
                popup.addItem(withTitle: title)
                popup.lastItem?.representedObject = account.id
            }
            let active = activeAccountProvider?(id) ?? accountStore.activeAccountID(for: id)
            if let active,
               let index = accounts.firstIndex(where: { $0.id == active }) {
                popup.selectItem(at: index)
            }
            let showsPicker = accounts.count > 1
            popup.isHidden = !showsPicker
            popup.toolTip = showsPicker
                ? "切换 \(ProviderStyles.style(for: id).shortName) 账户"
                : nil
        }
    }

    @objc private func autoCookieChanged(_ sender: AccentSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        service.config.set("providers.\(id).autoCookie", sender.isOn)
        do {
            try service.config.save()
        } catch {
            hintLabel.stringValue = "保存失败：\(error.localizedDescription)"
            hintLabel.textColor = .systemRed
            return
        }
        hintLabel.stringValue = sender.isOn
            ? "已开启 \(ProviderStyles.style(for: id).shortName) 自动 Cookie；首次读取可能弹出钥匙串授权"
            : "已关闭 \(ProviderStyles.style(for: id).shortName) 自动 Cookie"
        hintLabel.textColor = Theme.secondary
        service.refresh()
    }

    @objc private func accountChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,
              let accountID = sender.selectedItem?.representedObject as? String else { return }
        let accountLabel = sender.selectedItem?.title ?? accountID
        if let onSelectAccount {
            onSelectAccount(id, accountID)
        } else {
            do {
                // activate 会把选中账号的凭据镜像回扁平字段，兼容现有 collector。
                _ = try accountStore.activate(accountID, for: id)
                service.refresh()
            } catch {
                hintLabel.stringValue = "切换失败：\(error.localizedDescription)"
                hintLabel.textColor = .systemRed
                return
            }
        }
        hintLabel.stringValue = "已切换 \(ProviderStyles.style(for: id).shortName) 账户：\(accountLabel)"
        hintLabel.textColor = Theme.secondary
    }

    /// 仅供截图/回归：打开某家的账户管理 sheet。
    func openAccountManagerForDebug(_ provider: String, showForm: Bool = false) {
        guard let window, accountManager == nil else { return }
        let manager = AccountManagerWindowController(provider: provider, store: accountStore) { [weak self] in
            guard let self else { return }
            self.reloadAccounts()
            self.service.refresh()
        }
        guard let sheet = manager.window else { return }
        accountManager = manager
        window.beginSheet(sheet) { [weak self] _ in
            self?.accountManager = nil
            self?.reloadAccounts()
        }
        if showForm {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                manager.beginFormForDebug()
            }
        }
    }

    private func manageAccounts(for id: String) {
        guard let window, accountManager == nil else { return }
        let manager = AccountManagerWindowController(provider: id, store: accountStore) { [weak self] in
            guard let self else { return }
            self.reloadAccounts()
            self.service.refresh()
        }
        guard let sheet = manager.window else { return }
        accountManager = manager
        window.beginSheet(sheet) { [weak self] _ in
            self?.accountManager = nil
            self?.reloadAccounts()
        }
    }

    @objc private func manageAccountsTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        manageAccounts(for: id)
    }

    // MARK: - 导航

    @objc private func navTapped(_ sender: SidebarButton) {
        selectPage(sender.tag)
    }

    /// 仅供截图/回归：按名称切换设置页。
    func selectPageForDebug(_ name: String) {
        let map = ["general": 0, "menubar": 1, "services": 2, "alerts": 3, "about": 4]
        if let index = map[name] { selectPage(index) }
    }

    private func selectPage(_ index: Int) {
        selectedPage = index
        for (i, page) in pageViews.enumerated() {
            page.isHidden = i != index
        }
        for (i, button) in navButtons.enumerated() {
            button.selected = i == index
        }
        window?.makeFirstResponder(nil)
        contentStack.layoutSubtreeIfNeeded()
        if let scrollView {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        if ProcessInfo.processInfo.environment["AQB_LOG"] == "1" {
            log("settings stack=\(contentStack.frame) doc=\(contentStack.superview?.frame ?? .zero)")
            for (i, p) in pageViews.enumerated() where !p.isHidden {
                log("page\(i) frame=\(p.frame) sub=\((p as? NSStackView)?.arrangedSubviews.map { $0.frame } ?? [])")
            }
        }
    }

    // MARK: - 数据

    private func loadValues() {
        let config = service.config
        if let index = refreshOptions.firstIndex(where: { $0.1 == config.refreshSeconds }) {
            refreshPopup.selectItem(at: index)
        } else {
            refreshPopup.selectItem(at: 1)
        }
        let proxy = config.string("proxy", default: "auto")
        proxyField.stringValue = proxy.isEmpty ? "auto" : proxy

        let mode = config.string("menuBarMode", default: "auto")
        if let index = menuBarModePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == mode }) {
            menuBarModePopup.selectItem(at: index)
        }
        let preferred = config.string("menuBarProvider", default: "codex")
        if let index = fixedProviderPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == preferred }) {
            fixedProviderPopup.selectItem(at: index)
        }
        menuBarModeChanged()
        refreshLoginState()
        updateCheckinStatus()
    }

    func refreshLoginState() {
        loginSwitch.isOn = LaunchAtLogin.isEnabled
        loginStatusLabel.stringValue = LaunchAtLogin.statusText
        loginStatusLabel.textColor = LaunchAtLogin.requiresApproval ? .systemOrange : Theme.tertiary
    }

    private static func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "free": return "免费"
        default: return plan
        }
    }

    func updateProviderStatuses(_ snapshot: QuotaSnapshot?) {
        for id in providerOrder {
            guard let views = providerStatusViews[id] else { continue }
            guard let provider = snapshot?.providers.first(where: { $0.id == id }) else {
                views.text.stringValue = "未检测"
                views.text.textColor = Theme.secondary
                views.dot.surfaceColor = Theme.tertiary
                continue
            }
            switch provider.status {
            case "ok":
                views.text.stringValue = provider.plan.map { "已连接 · \(Self.displayPlan($0))" } ?? "已连接"
                views.text.textColor = Theme.secondary
                views.dot.surfaceColor = QuotaStyle.healthyColor
            case "warn":
                views.text.stringValue = provider.detail ?? "额度紧张"
                views.text.textColor = .systemOrange
                views.dot.surfaceColor = Theme.warning
            case "error":
                views.text.stringValue = provider.error ?? "凭证失效"
                views.text.textColor = .systemRed
                views.dot.surfaceColor = Theme.danger
            case "unconfigured":
                views.text.stringValue = "需要配置"
                views.text.textColor = .systemOrange
                views.dot.surfaceColor = Theme.warning
            default:
                views.text.stringValue = "已停用"
                views.text.textColor = Theme.tertiary
                views.dot.surfaceColor = Theme.tertiary
            }
        }
    }

    @objc private func quotaUpdated(_ note: Notification) {
        updateProviderStatuses(note.object as? QuotaSnapshot)
    }

    // MARK: - 动作

    @objc private func appearanceChanged() {
        let value: String
        switch appearanceControl.selectedSegment {
        case 1: value = "light"
        case 2: value = "dark"
        default: value = "system"
        }
        service.config.set("appearance", value)
        try? service.config.save()
        onAppearanceChanged()
    }

    @objc private func checkinAutoChanged() {
        service.config.set("checkin.auto", checkinSwitch.isOn)
        try? service.config.save()
        updateCheckinStatus()
    }

    @objc private func checkinHourChanged() {
        service.config.set("checkin.hour", checkinHourPopup.indexOfSelectedItem)
        try? service.config.save()
        updateCheckinStatus()
    }

    @objc private func checkinNow() {
        checkinButton.isEnabled = false
        onCheckin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkinButton.isEnabled = true
        }
    }

    func updateCheckinStatus() {
        checkinTitleLabel.stringValue = checkin.hasCheckedInToday ? "今日已签到" : "今日待签到"
        checkinStatusLabel.stringValue = "\(checkin.statusText) · \(checkin.detailText)"
        checkinStatusLabel.textColor = checkin.hasCheckedInToday ? Theme.success : Theme.secondary
        checkinSwitch.isOn = checkin.isAutoEnabled
        checkinButton.title = checkin.isRunning ? "签到中…" : "立即签到"
        checkinButton.isEnabled = !checkin.isRunning
        checkinButton.isHidden = checkin.hasCheckedInToday
        for (_, label) in checkinDetailStatusLabels {
            let ok = checkin.hasCheckedInToday
            label.stringValue = ok ? "已签到" : "待签到"
            label.textColor = ok ? Theme.success : Theme.tertiary
        }
    }

    /// 外观变化时原地刷新颜色，不再重建 contentView / 重新 loadValues，
    /// 以免丢掉未保存的输入、first responder、滚动位置，也避免复用控件上累积约束。
    func reloadForAppearance() {
        guard let window, let content = window.contentView else { return }
        window.appearance = NSApp.appearance
        refreshThemedSurfaces(in: content)

        // 这些控件保存的是静态 CGColor / 具体色，需要在外观切换后重新解析。
        navButtons.forEach { $0.refreshAppearance() }
        scaleSlider.needsDisplay = true
        warningSlider.needsDisplay = true
        dangerSlider.needsDisplay = true

        // 状态色（成功/警告/危险）在深色外观下也是动态色，重算一次圆点与文字。
        updateProviderStatuses(service.snapshot)
        updateScalePreview()
        content.needsDisplay = true
    }

    private func refreshThemedSurfaces(in node: NSView) {
        (node as? ThemedSurfaceView)?.applySurface()
        (node as? AvatarView)?.refreshInk()
        for subview in node.subviews {
            refreshThemedSurfaces(in: subview)
        }
    }

    @objc private func menuBarModeChanged() {
        let isFixed = (menuBarModePopup.selectedItem?.representedObject as? String) == "fixed"
        fixedProviderPopup.isEnabled = true
        fixedProviderPopup.alphaValue = isFixed ? 1 : 0.82
        saveGeneralSettings()
    }

    @objc private func fixedProviderSelected() {
        // 选服务即切换为“固定一家”，不再要求用户先改上面的显示方式。
        if let index = menuBarModePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == "fixed" }) {
            menuBarModePopup.selectItem(at: index)
        }
        menuBarModeChanged()
    }

    @objc private func refreshOptionChanged() {
        saveGeneralSettings()
    }

    private func saveGeneralSettings() {
        guard !suppressDirty else { return }
        let config = service.config
        config.set("refreshSeconds", refreshPopup.selectedItem?.representedObject as? Int ?? 300)
        let proxy = proxyField.stringValue.trimmingCharacters(in: .whitespaces)
        config.set("proxy", proxy.isEmpty ? "auto" : proxy)
        config.set("menuBarMode", menuBarModePopup.selectedItem?.representedObject as? String ?? "auto")
        config.set("menuBarProvider", fixedProviderPopup.selectedItem?.representedObject as? String ?? "codex")
        do {
            try config.save()
            hintLabel.stringValue = "已自动保存"
            hintLabel.textColor = Theme.secondary
            onSaved()
        } catch {
            hintLabel.stringValue = "保存失败：\(error.localizedDescription)"
            hintLabel.textColor = .systemRed
        }
    }

    @objc private func loginSwitchChanged() {
        if let error = LaunchAtLogin.set(loginSwitch.isOn) {
            let alert = NSAlert()
            alert.messageText = "无法修改开机启动"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.runModal()
        }
        refreshLoginState()
    }

    @objc private func scaleChanged() {
        let factor = scaleSlider.value
        scaleLabel.stringValue = String(format: "%.2f×", factor)
        service.config.set("menuBarIconScaleFactor", factor)
        service.config.set("menuBarIconScale", Double(service.effectiveMenuBarIconScale))
        try? service.config.save()
        updateScalePreview()
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func resetScale() {
        scaleSlider.value = 1.0
        scaleChanged()
    }

    private func updateScalePreview() {
        let scale = service.effectiveMenuBarIconScale
        scaleLabel.stringValue = String(format: "%.2f×", service.menuBarIconScaleFactor)

        let icon = MenuBarIcon.make(
            provider: "opencode",
            value: "72",
            remaining: 72,
            severity: .healthy,
            scale: scale,
            ink: .white,
            fixedInk: true
        )
        scalePreview.image = icon
    }

    @objc private func visibilityChanged(_ sender: AccentSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        var hidden = Set(service.config.stringArray("hiddenProviders"))
        if sender.isOn {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        service.config.set("hiddenProviders", Array(hidden).sorted())
        try? service.config.save()
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func resetOrder() {
        service.config.set("providerOrder", providerOrder)
        try? service.config.save()
        hintLabel.stringValue = "已恢复默认顺序"
        hintLabel.textColor = Theme.secondary
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    private func saveStyleValues() {
        guard warningSlider.superview != nil else { return }
        service.config.set("style.warningPercent", warningSlider.value)
        service.config.set("style.dangerPercent", dangerSlider.value)
        for (index, well) in colorWells.enumerated() {
            let key = ["healthyColor", "warningColor", "dangerColor"][index]
            service.config.set("style.\(key)", QuotaStyle.hex(well.color))
        }
        for (id, field) in creditThresholdFields {
            service.config.set("style.thresholds.\(id)", field.doubleValue)
        }
        service.config.set("notifications.enabled", notifySwitch.isOn)
        service.config.set("notifications.percent", notifyPercentField.doubleValue)
    }

    @objc private func save() {
        let config = service.config
        let seconds = refreshPopup.selectedItem?.representedObject as? Int ?? 300
        config.set("refreshSeconds", seconds)
        let proxy = proxyField.stringValue.trimmingCharacters(in: .whitespaces)
        config.set("proxy", proxy.isEmpty ? "auto" : proxy)
        config.set("menuBarMode", menuBarModePopup.selectedItem?.representedObject as? String ?? "auto")
        config.set("menuBarProvider", fixedProviderPopup.selectedItem?.representedObject as? String ?? "codex")
        saveStyleValues()
        do {
            try config.save()
            hintLabel.stringValue = "已保存"
            hintLabel.textColor = Theme.secondary
            saveButton?.title = "保存"
            onSaved()
        } catch {
            hintLabel.stringValue = "保存失败：\(error.localizedDescription)"
            hintLabel.textColor = .systemRed
        }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(service.config.url)
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === proxyField else { return }
        saveGeneralSettings()
    }
}

// MARK: - 账户管理窗口

/// 以 sheet 形式管理某个 provider 的多个账户：添加（名称 + 凭据字段）、编辑、
/// 删除、设为当前。凭据字段完全来自 `AccountStore.credentialKeysByProvider`，
/// 不假设任何 provider 的扁平字段。
final class AccountManagerWindowController: NSWindowController {
    private let provider: String
    private let store: AccountStore
    private let onChanged: () -> Void

    private let container = ThemedSurfaceView()
    private let scrollView = NSScrollView()
    private let contentStack = FlippedStackView()
    private let listStack = NSStackView()
    private let formContainer = ThemedSurfaceView()
    private let formStack = NSStackView()
    private let formTitleLabel = NSTextField(labelWithString: "")
    private let labelField = NSTextField()
    private let identityField = NSTextField()
    private var credentialFields: [String: NSTextField] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerStatusLabel = NSTextField(labelWithString: "")
    private var accounts: [ProviderAccount] = []
    private var editingAccount: ProviderAccount?

    private var providerName: String { ProviderStyles.style(for: provider).shortName }

    init(provider: String, store: AccountStore, onChanged: @escaping () -> Void) {
        self.provider = provider
        self.store = store
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "管理 \(ProviderStyles.style(for: provider).shortName) 账户"
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.center()
        super.init(window: window)
        buildContent()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 仅供截图/回归：直接展开添加表单。
    func beginFormForDebug() {
        beginForm(editing: nil)
    }

    // MARK: 构建

    private func buildContent() {
        guard let window else { return }
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 340)
        container.wantsLayer = true
        container.surfaceColor = Theme.background
        window.contentView = container

        let title = label("\(providerName) 账户", size: 18, weight: .semibold)
        let subtitle = label(
            "凭据保存在本地配置；设为当前账号后会同步给采集器。",
            size: 11,
            color: Theme.secondary
        )
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        // 账户列表直接放在容器里，不再用 scrollView 包一层：
        // NSStackView 在 flipped document 中容易把首行顶到底部，造成大片空白。
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.detachesHiddenViews = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.detachesHiddenViews = true
        listStack.translatesAutoresizingMaskIntoConstraints = false

        buildForm()

        contentStack.addArrangedSubview(listStack)
        contentStack.addArrangedSubview(formContainer)
        listStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        formContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            contentStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -64),
        ])

        let add = NSButton(title: "添加账户", target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.bezelColor = Theme.accent
        add.font = .systemFont(ofSize: 12, weight: .medium)
        add.setAccessibilityLabel("添加 \(providerName) 账户")

        let done = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded

        footerStatusLabel.font = .systemFont(ofSize: 10.5)
        footerStatusLabel.textColor = Theme.secondary
        footerStatusLabel.lineBreakMode = .byTruncatingTail
        footerStatusLabel.setAccessibilityLabel("账户管理状态")
        footerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let footer = NSStackView(views: [add, footerStatusLabel, footerSpacer, done])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func buildForm() {
        formContainer.wantsLayer = true
        formContainer.surfaceColor = Theme.surfaceAlt
        formContainer.surfaceBorderColor = Theme.separator
        formContainer.surfaceBorderWidth = 1
        formContainer.layer?.cornerRadius = 10
        formContainer.layer?.cornerCurve = .continuous
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        formContainer.isHidden = true

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 8
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 14),
            formStack.bottomAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: -14),
            formStack.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 14),
            formStack.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -14),
        ])

        formTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        formTitleLabel.textColor = Theme.text
        formStack.addArrangedSubview(formTitleLabel)

        labelField.font = .systemFont(ofSize: 12)
        labelField.placeholderString = "例如：工作账号"
        labelField.setAccessibilityLabel("账户名称")
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        formStack.addArrangedSubview(formRow("名称", labelField))

        identityField.font = .systemFont(ofSize: 12)
        identityField.placeholderString = "邮箱 / 用户名（可选）"
        identityField.setAccessibilityLabel("账户标识")
        identityField.translatesAutoresizingMaskIntoConstraints = false
        identityField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        formStack.addArrangedSubview(formRow("账户标识", identityField))

        for key in AccountStore.credentialKeys(for: provider) {
            let field: NSTextField = Self.isSecret(key) ? NSSecureTextField() : NSTextField()
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.placeholderString = Self.placeholder(for: key)
            field.setAccessibilityLabel(Self.displayName(for: key))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            credentialFields[key] = field
            formStack.addArrangedSubview(formRow(Self.displayName(for: key), field))
        }

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = Theme.secondary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("账户操作状态")
        formStack.addArrangedSubview(statusLabel)

        let save = NSButton(title: "保存账户", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.bezelColor = Theme.accent
        save.font = .systemFont(ofSize: 12, weight: .medium)
        save.keyEquivalent = "\r"

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        let buttons = NSStackView(views: [save, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(buttons)
    }

    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let titleLabel = label(title, size: 11, color: Theme.secondary)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [titleLabel, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: 列表

    private func reload() {
        accounts = store.accounts(for: provider)
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let activeID = store.activeAccountID(for: provider)
        guard !accounts.isEmpty else {
            let empty = label(
                "还没有账户。点下方「添加账户」创建第一个账号。",
                size: 11,
                color: Theme.tertiary
            )
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 0
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                return
        }
        for account in accounts {
            let card = accountCard(account, activeID: activeID)
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func scrollToTop() {
        guard let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()

    }

    private func accountCard(_ account: ProviderAccount, activeID: String?) -> NSView {
        let card = ThemedSurfaceView()
        card.wantsLayer = true
        card.surfaceColor = Theme.surface
        card.surfaceBorderColor = Theme.separator
        card.surfaceBorderWidth = 1
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = label(account.label, size: 13, weight: .semibold)
        var details: [String] = []
        if let identity = account.account, !identity.isEmpty { details.append(identity) }
        details.append(account.isLegacy ? "旧版默认账号" : account.id)
        let subtitle = label(details.joined(separator: " · "), size: 10, color: Theme.tertiary)
        subtitle.lineBreakMode = .byTruncatingMiddle

        let info = NSStackView(views: [title, subtitle])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        var trailing: [NSView] = []
        if account.isLegacy {
            trailing.append(label("旧版", size: 10, weight: .medium, color: Theme.tertiary))
        } else {
            if activeID == account.id {
                trailing.append(label("当前", size: 10, weight: .semibold, color: Theme.success))
            } else {
                let activate = ClosureButton(title: "设为当前") { [weak self] in self?.activate(account) }
                activate.font = .systemFont(ofSize: 11, weight: .medium)
                activate.contentTintColor = Theme.accent
                trailing.append(activate)
            }
            let edit = ClosureButton(title: "编辑") { [weak self] in self?.beginForm(editing: account) }
            edit.font = .systemFont(ofSize: 11, weight: .medium)
            edit.contentTintColor = Theme.secondary
            trailing.append(edit)

            let delete = ClosureButton(title: "删除") { [weak self] in self?.requestDelete(account) }
            delete.font = .systemFont(ofSize: 11, weight: .medium)
            delete.contentTintColor = .systemRed
            trailing.append(delete)
        }

        let row = NSStackView(views: [info, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    // MARK: 表单

    private func beginForm(editing account: ProviderAccount?) {
        editingAccount = account
        formTitleLabel.stringValue = account == nil ? "添加账户" : "编辑账户"
        labelField.stringValue = account?.label ?? ""
        identityField.stringValue = account?.account ?? ""
        for (key, field) in credentialFields {
            field.stringValue = account?.credentials[key] ?? ""
        }
        statusLabel.stringValue = ""
        formContainer.isHidden = false
        contentStack.layoutSubtreeIfNeeded()
        resizeSheet(expanded: true)
        window?.makeFirstResponder(labelField)
    }

    private func resizeSheet(expanded: Bool) {
        guard let window else { return }
        let height: CGFloat = expanded ? 720 : 340
        var frame = window.frame
        let delta = height - frame.height
        frame.size.height = height
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
        container.setFrameSize(NSSize(width: 600, height: height))
        contentStack.layoutSubtreeIfNeeded()
    }

    private func cancelForm() {
        editingAccount = nil
        formContainer.isHidden = true
        statusLabel.stringValue = ""
        footerStatusLabel.stringValue = ""
        resizeSheet(expanded: false)
    }

    @objc private func addTapped() {
        beginForm(editing: nil)
    }

    @objc private func cancelTapped() {
        cancelForm()
    }

    @objc private func saveTapped() {
        let labelText = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !labelText.isEmpty else {
            setStatus("请填写账户名称", error: true)
            return
        }
        let identity = identityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var credentials: [String: String] = [:]
        for (key, field) in credentialFields {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { credentials[key] = value }
        }

        do {
            if var account = editingAccount {
                account.label = labelText
                account.account = identity.isEmpty ? nil : identity
                account.credentials = credentials
                try store.updateAccount(account, for: provider)
            } else {
                // Codex 允许空凭据（使用默认 auth.json / CODEX_HOME）；其他 provider 至少一项。
                if provider != "codex", credentials.isEmpty {
                    setStatus("请至少填写一项凭据", error: true)
                    return
                }
                _ = try store.addAccount(
                    for: provider,
                    label: labelText,
                    account: identity.isEmpty ? nil : identity,
                    credentials: credentials,
                    makeActive: true
                )
            }
            editingAccount = nil
            formContainer.isHidden = true
            resizeSheet(expanded: false)
            statusLabel.stringValue = "已保存"
            statusLabel.textColor = Theme.success
            reload()
            onChanged()
        } catch {
            setStatus("保存失败：\(error.localizedDescription)", error: true)
        }
    }

    private func activate(_ account: ProviderAccount) {
        do {
            _ = try store.activate(account.id, for: provider)
            setStatus("已切换为「\(account.label)」", error: false)
            reload()
            onChanged()
        } catch {
            setStatus("切换失败：\(error.localizedDescription)", error: true)
        }
    }

    private func requestDelete(_ account: ProviderAccount) {
        let alert = NSAlert()
        alert.messageText = "删除账户「\(account.label)」？"
        alert.informativeText = "会从本地配置中移除该账户及保存的凭据，无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.removeAccount(withID: account.id, for: provider)
            if editingAccount?.id == account.id {
                cancelForm()
            }
            reload()
            setStatus("已删除「\(account.label)」", error: false)
            onChanged()
        } catch {
            setStatus("删除失败：\(error.localizedDescription)", error: true)
        }
    }

    @objc private func doneTapped() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            close()
        }
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : Theme.success
        footerStatusLabel.stringValue = text
        footerStatusLabel.textColor = error ? .systemRed : Theme.success
    }

    private func scrollToBottom() {
        guard let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let y = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: 文案

    private static func displayName(for key: String) -> String {
        switch key {
        case "apiKey": return "API Key"
        case "cookie": return "Console Cookie"
        case "workspaceId": return "Workspace ID"
        case "token": return "Access Token"
        case "uid": return "UID"
        case "edition": return "版本（cn/solo/sg/solo-sg）"
        case "authPath": return "auth.json 路径"
        case "codexHome": return "CODEX_HOME"
        default: return key
        }
    }

    private static func isSecret(_ key: String) -> Bool {
        ["apiKey", "cookie", "token"].contains(key)
    }

    private static func placeholder(for key: String) -> String {
        switch key {
        case "apiKey": return "sk-..."
        case "cookie": return "__Host-console_session（登录后自动写入）"
        case "workspaceId": return "wrk_...（可选，留空自动获取）"
        case "token": return "eyJ... 或 Bearer eyJ..."
        case "uid": return "可选，留空自动识别"
        case "edition": return "cn / solo / sg / solo-sg"
        case "authPath": return "~/.codex/auth.json（留空使用默认）"
        case "codexHome": return "~/.codex（留空使用默认）"
        default: return ""
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}


func makePaperPanel(cornerRadius: CGFloat) -> NSView {
    let view = ThemedSurfaceView()
    view.wantsLayer = true
    view.surfaceColor = Theme.surfaceAlt
    view.surfaceBorderColor = Theme.separator
    view.surfaceBorderWidth = 1
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.shadowColor = NSColor.black.cgColor
    view.layer?.shadowOpacity = 0.05
    view.layer?.shadowRadius = 12
    view.layer?.shadowOffset = CGSize(width: 0, height: -2)
    return view
}
