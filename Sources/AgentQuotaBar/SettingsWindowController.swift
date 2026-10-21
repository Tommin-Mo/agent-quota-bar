import AppKit

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
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let fill = isHighlighted ? Theme.accent.blended(withFraction: 0.12, of: .black) ?? Theme.accent : Theme.accent
        fill.setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
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

    private func applyStyle() {
        if selected {
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
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

    private let refreshPopup = NSPopUpButton()
    private let proxyField = NSTextField()
    private let menuBarModePopup = NSPopUpButton()
    private let fixedProviderPopup = NSPopUpButton()
    private let loginSwitch = AccentSwitch()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleLabel = NSTextField(labelWithString: "125%")
    private let scalePreview = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let appearanceControl = NSSegmentedControl()
    private let checkinSwitch = AccentSwitch()
    private let checkinHourPopup = NSPopUpButton()
    private let checkinStatusLabel = NSTextField(labelWithString: "")
    private let checkinTitleLabel = NSTextField(labelWithString: "今日签到")
    private let checkinButton = NSButton(title: "立即签到", target: nil, action: nil)
    private let warningSlider = NSSlider()
    private let dangerSlider = NSSlider()
    private let warningValueLabel = NSTextField(labelWithString: "45%")
    private let dangerValueLabel = NSTextField(labelWithString: "20%")
    private let notifySwitch = AccentSwitch()
    private let notifyPercentField = NSTextField()
    private let notifyStatusLabel = NSTextField(labelWithString: "")
    private let testNotifyButton = NSButton(title: "测试", target: nil, action: nil)
    private let notificationSettingsButton = NSButton(title: "权限设置", target: nil, action: nil)
    private var creditThresholdFields: [String: NSTextField] = [:]
    private var colorWells: [NSColorWell] = []
    private weak var scrollView: NSScrollView?

    private let contentStack = NSStackView()
    private var pageViews: [NSView] = []
    private var navButtons: [SidebarButton] = []
    private var selectedPage = 0
    private var providerStatusViews: [String: (dot: NSView, text: NSTextField)] = [:]
    private var visibilitySwitches: [String: AccentSwitch] = [:]
    private var checkinDetailStatusLabels: [String: NSTextField] = [:]

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
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
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
        updateProviderStatuses(service.snapshot)
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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 680))
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.background.resolvedCGColor()

        let topBar = NSView()
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = Theme.background.resolvedCGColor()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)
        buildTopBar(in: topBar)

        let saveBar = NSView()
        saveBar.wantsLayer = true
        saveBar.layer?.backgroundColor = Theme.background.resolvedCGColor()
        saveBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveBar)

        let saveBarLine = NSView()
        saveBarLine.wantsLayer = true
        saveBarLine.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
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
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 58),

            saveBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            saveBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            saveBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            saveBar.heightAnchor.constraint(equalToConstant: 56),

            saveBarLine.topAnchor.constraint(equalTo: saveBar.topAnchor),
            saveBarLine.leadingAnchor.constraint(equalTo: saveBar.leadingAnchor),
            saveBarLine.trailingAnchor.constraint(equalTo: saveBar.trailingAnchor),
            saveBarLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: saveBar.topAnchor),
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

            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
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
        let subtitle = label("v0.4", size: 10.5, color: Theme.tertiary)
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

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
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
        let subtitle = label("v0.4", size: 10.5, color: Theme.tertiary)
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
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.widthAnchor.constraint(equalToConstant: 168).isActive = true
            nav.addArrangedSubview(button)
            navButtons.append(button)
        }

        let background = label("后台签到 · 已启用", size: 10, weight: .medium, color: Theme.success)
        background.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(background)
        let version = label("v0.4", size: 10, color: Theme.tertiary)
        version.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(version)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),

            nav.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),

            background.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            background.bottomAnchor.constraint(equalTo: version.topAnchor, constant: -4),
            version.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            version.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
        ])
    }

    private func buildSaveBar(in bar: NSView) {
        let openConfig = NSButton(title: "打开配置文件", target: self, action: #selector(openConfig))
        openConfig.isBordered = false
        openConfig.font = .systemFont(ofSize: 11)
        openConfig.contentTintColor = Theme.secondary

        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = Theme.secondary

        let save = AccentButton(title: "保存", target: self, action: #selector(save))
        save.isBordered = false
        save.font = .systemFont(ofSize: 13, weight: .semibold)
        save.keyEquivalent = "\r"
        save.translatesAutoresizingMaskIntoConstraints = false
        save.widthAnchor.constraint(equalToConstant: 104).isActive = true
        save.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [openConfig, hintLabel, spacer, save])
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
        refreshPopup.translatesAutoresizingMaskIntoConstraints = false
        refreshPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        proxyField.font = .systemFont(ofSize: 12)
        proxyField.placeholderString = "auto"
        proxyField.translatesAutoresizingMaskIntoConstraints = false
        proxyField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged)
        loginStatusLabel.font = .systemFont(ofSize: 10)
        loginStatusLabel.textColor = Theme.tertiary

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
        appearanceControl.translatesAutoresizingMaskIntoConstraints = false
        appearanceControl.widthAnchor.constraint(equalToConstant: 260).isActive = true

        checkinSwitch.isOn = checkin.isAutoEnabled
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
        checkinHourPopup.target = self
        checkinHourPopup.action = #selector(checkinHourChanged)
        checkinHourPopup.translatesAutoresizingMaskIntoConstraints = false
        checkinHourPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        checkinStatusLabel.font = .systemFont(ofSize: 10)
        checkinStatusLabel.textColor = Theme.tertiary
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
            controlRow("刷新频率", refreshPopup, caption: nil),
            separator(),
            controlRow("系统代理", proxyField, caption: nil),
            separator(),
            controlRow("外观", appearanceControl, caption: nil),
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

    private func makeMenuBarPage() -> NSView {
        menuBarModePopup.removeAllItems()
        menuBarModePopup.addItem(withTitle: "自动切换（谁变化显示谁）")
        menuBarModePopup.lastItem?.representedObject = "auto"
        menuBarModePopup.addItem(withTitle: "固定一家")
        menuBarModePopup.lastItem?.representedObject = "fixed"
        menuBarModePopup.font = .systemFont(ofSize: 12)
        menuBarModePopup.target = self
        menuBarModePopup.action = #selector(menuBarModeChanged)
        menuBarModePopup.translatesAutoresizingMaskIntoConstraints = false
        menuBarModePopup.widthAnchor.constraint(equalToConstant: 250).isActive = true

        fixedProviderPopup.removeAllItems()
        for id in providerOrder {
            fixedProviderPopup.addItem(withTitle: ProviderStyles.style(for: id).shortName)
            fixedProviderPopup.lastItem?.representedObject = id
        }
        fixedProviderPopup.font = .systemFont(ofSize: 12)
        fixedProviderPopup.translatesAutoresizingMaskIntoConstraints = false
        fixedProviderPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        scaleSlider.minValue = 0.8
        scaleSlider.maxValue = 1.6
        scaleSlider.doubleValue = service.config.double("menuBarIconScale", default: 1.25)
        scaleSlider.isContinuous = true
        scaleSlider.trackFillColor = Theme.accent.resolvedForAppearance()
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true

        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = Theme.secondary
        scaleLabel.stringValue = "\(Int(scaleSlider.doubleValue * 100))%"

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

        let scaleRow = NSStackView(views: [scaleSlider, scaleLabel, resetScale])
        scaleRow.orientation = .horizontal
        scaleRow.alignment = .centerY
        scaleRow.spacing = 10

        let scaleBox = NSStackView(views: [scaleRow, scalePreview])
        scaleBox.orientation = .vertical
        scaleBox.alignment = .trailing
        scaleBox.spacing = 8

        let resetOrder = NSButton(title: "恢复默认顺序", target: self, action: #selector(resetOrder))
        resetOrder.bezelStyle = .rounded
        resetOrder.font = .systemFont(ofSize: 11)

        let group1 = groupCard([
            controlRow("显示方式", menuBarModePopup, caption: "自动切换会记住最近发生变化的那一家。"),
            separator(),
            controlRow("固定显示", fixedProviderPopup, caption: "仅在「固定一家」时生效。"),
        ])
        let group2 = groupCard([
            controlRow("图标大小", scaleBox, caption: nil),
        ])
        let group3 = groupCard([
            controlRow("面板顺序", resetOrder, caption: "在面板里上下拖动行即可排序。"),
        ])
        let help = groupCard([
            controlRow("自动切换", label("10 秒冷却，避免来回跳", size: 12, color: Theme.secondary), caption: nil),
            separator(),
            controlRow("面板排序", label("在面板里上下拖动行", size: 12, color: Theme.secondary), caption: nil),
        ])
        return composePage([
            pageHeader("菜单栏", ""),
            groupLabel("显示"),
            group1,
            groupLabel("图标"),
            group2,
            groupLabel("顺序"),
            group3,
            groupLabel("提示"),
            help,
        ])
    }

    private func makeServicesPage() -> NSView {
        var rows: [NSView] = []
        for (index, id) in providerOrder.enumerated() {
            if index > 0 { rows.append(separator()) }
            rows.append(providerRow(id))
        }
        return composePage([
            pageHeader("服务", ""),
            groupCard(rows),
            label("关闭的服务会同时从菜单栏和面板移除。", size: 11, color: Theme.tertiary),
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
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorWells.append(well)
        }

        for slider in [warningSlider, dangerSlider] {
            slider.minValue = 1
            slider.maxValue = 99
            slider.isContinuous = false
            slider.trackFillColor = Theme.accent.resolvedForAppearance()
            slider.target = self
            slider.action = #selector(thresholdChanged)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        warningSlider.doubleValue = QuotaStyle.warningPercent
        dangerSlider.maxValue = max(2, QuotaStyle.warningPercent - 1)
        dangerSlider.doubleValue = min(QuotaStyle.dangerPercent, dangerSlider.maxValue)
        warningValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        dangerValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        updateThresholdLabels()

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
            controlRow("颜色", colorRow, caption: nil),
            separator(),
            controlRow("警戒阈值", NSStackView(views: [warningSlider, warningValueLabel]), caption: nil),
            separator(),
            controlRow("危险阈值", NSStackView(views: [dangerSlider, dangerValueLabel]), caption: nil),
        ])

        notifySwitch.isOn = service.config.bool("notifications.enabled", default: false)
        notifySwitch.target = self
        notifySwitch.action = #selector(notificationToggled)
        notifySwitch.translatesAutoresizingMaskIntoConstraints = false

        notifyPercentField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        notifyPercentField.stringValue = String(format: "%.0f", service.config.double("notifications.percent", default: 20))
        notifyPercentField.alignment = .right
        notifyPercentField.translatesAutoresizingMaskIntoConstraints = false
        notifyPercentField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        notifyStatusLabel.stringValue = service.config.bool("notifications.enabled", default: false) ? "已开启" : "已关闭"
        notifyStatusLabel.font = .systemFont(ofSize: 10)
        notifyStatusLabel.textColor = Theme.tertiary
        notifyStatusLabel.lineBreakMode = .byTruncatingTail

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

        let permissionRow = NSStackView(views: [notifyStatusLabel, notificationSettingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.alignment = .centerY
        permissionRow.spacing = 10

        func thresholdField(_ id: String, fallback: Double) -> NSTextField {
            let field = NSTextField()
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
            field.stringValue = String(format: "%.0f", service.config.double("style.thresholds.\(id)", default: fallback))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 54).isActive = true
            creditThresholdFields[id] = field
            return field
        }

        let pointsRow = NSStackView()
        pointsRow.orientation = .horizontal
        pointsRow.alignment = .centerY
        pointsRow.spacing = 10
        pointsRow.addArrangedSubview(label("Trae", size: 11, color: Theme.tertiary))
        pointsRow.addArrangedSubview(thresholdField("trae", fallback: 200))
        pointsRow.addArrangedSubview(label("WorkBuddy", size: 11, color: Theme.tertiary))
        pointsRow.addArrangedSubview(thresholdField("workbuddy", fallback: 500))

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

    private func updateThresholdLabels() {
        warningValueLabel.stringValue = "\(Int(warningSlider.doubleValue.rounded()))%"
        dangerValueLabel.stringValue = "\(Int(dangerSlider.doubleValue.rounded()))%"
    }

    private func saveStyle() {
        service.config.set("style.warningPercent", warningSlider.doubleValue)
        service.config.set("style.dangerPercent", dangerSlider.doubleValue)
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
        dangerSlider.maxValue = max(2, warningSlider.doubleValue - 1)
        if dangerSlider.doubleValue > dangerSlider.maxValue {
            dangerSlider.doubleValue = dangerSlider.maxValue
        }
        updateThresholdLabels()
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
                self.notifyStatusLabel.stringValue = "系统通知已授权"
                self.notifyStatusLabel.textColor = Theme.success
            case .denied:
                self.notifyStatusLabel.stringValue = "系统通知被关闭"
                self.notifyStatusLabel.textColor = Theme.warning
            default:
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

        let open = NSButton(title: "打开配置文件", target: self, action: #selector(openConfig))
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
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.surface.resolvedCGColor()
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
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
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    private func controlRow(_ title: String, _ control: NSView, caption _: String?) -> NSView {
        let caption: String? = nil
        let titleLabel = label(title, size: 14)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let top = NSStackView(views: [titleLabel, spacer, control])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false

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

        let captionLabel = wrappingLabel(caption, size: 10, color: Theme.tertiary, width: 500)
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
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func providerRow(_ id: String) -> NSView {
        let style = ProviderStyles.style(for: id)
        let avatar = AvatarView(letter: style.letter, color: style.color, size: 24, provider: id)
        let name = label(style.shortName, size: 12.5, weight: .semibold)

        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = Theme.tertiary.resolvedCGColor()

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
        visibilitySwitches[id] = visibility

        let configure = ClosureButton(title: "配置…") { [weak self] in
            self?.onOpenSetup(id)
        }
        configure.font = .systemFont(ofSize: 11, weight: .medium)

        let row = NSStackView(views: [avatar, info, spacer, visibility, configure])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        providerStatusViews[id] = (dot, status)
        return row
    }

    // MARK: - 导航

    @objc private func navTapped(_ sender: SidebarButton) {
        selectPage(sender.tag)
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

    func updateProviderStatuses(_ snapshot: QuotaSnapshot?) {
        for id in providerOrder {
            guard let views = providerStatusViews[id] else { continue }
            guard let provider = snapshot?.providers.first(where: { $0.id == id }) else {
                views.text.stringValue = "未检测"
                views.text.textColor = Theme.secondary
                views.dot.layer?.backgroundColor = Theme.tertiary.resolvedCGColor()
                continue
            }
            switch provider.status {
            case "ok":
                views.text.stringValue = "已连接 · \(provider.plan ?? "自动")"
                views.text.textColor = Theme.secondary
                views.dot.layer?.backgroundColor = Theme.success.resolvedCGColor()
            case "warn":
                views.text.stringValue = provider.detail ?? "额度紧张"
                views.text.textColor = .systemOrange
                views.dot.layer?.backgroundColor = Theme.warning.resolvedCGColor()
            case "error":
                views.text.stringValue = provider.error ?? "凭证失效"
                views.text.textColor = .systemRed
                views.dot.layer?.backgroundColor = Theme.danger.resolvedCGColor()
            case "unconfigured":
                views.text.stringValue = "需要配置"
                views.text.textColor = .systemOrange
                views.dot.layer?.backgroundColor = Theme.warning.resolvedCGColor()
            default:
                views.text.stringValue = "已停用"
                views.text.textColor = Theme.tertiary
                views.dot.layer?.backgroundColor = Theme.tertiary.resolvedCGColor()
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
        for (id, label) in checkinDetailStatusLabels {
            let ok = checkin.hasCheckedInToday
            label.stringValue = ok ? "已签到" : "待签到"
            label.textColor = ok ? Theme.success : Theme.tertiary
        }
    }

    func reloadForAppearance() {
        window?.appearance = NSApp.appearance
        let page = selectedPage
        pageViews.removeAll()
        navButtons.removeAll()
        providerStatusViews.removeAll()
        visibilitySwitches.removeAll()
        checkinDetailStatusLabels.removeAll()
        window?.contentView = buildContent()
        loadValues()
        updateProviderStatuses(service.snapshot)
        selectPage(page)
        updateCheckinStatus()
    }

    @objc private func menuBarModeChanged() {
        let isFixed = (menuBarModePopup.selectedItem?.representedObject as? String) == "fixed"
        fixedProviderPopup.isEnabled = isFixed
        fixedProviderPopup.alphaValue = isFixed ? 1 : 0.45
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
        let scale = scaleSlider.doubleValue
        scaleLabel.stringValue = "\(Int((scale * 100).rounded()))%"
        service.config.set("menuBarIconScale", scale)
        try? service.config.save()
        updateScalePreview()
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func resetScale() {
        scaleSlider.doubleValue = 1.25
        scaleChanged()
    }

    private func updateScalePreview() {
        let scale = CGFloat(service.config.double("menuBarIconScale", default: 1.25))
        scaleLabel.stringValue = "\(Int((scale * 100).rounded()))%"

        let icon = MenuBarIcon.make(
            provider: "opencode",
            value: "72",
            remaining: 72,
            severity: .healthy,
            scale: scale
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
        service.config.set("style.warningPercent", warningSlider.doubleValue)
        service.config.set("style.dangerPercent", dangerSlider.doubleValue)
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

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


func makePaperPanel(cornerRadius: CGFloat) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.borderWidth = 1
    view.layer?.borderColor = Theme.separator.resolvedCGColor()
    view.layer?.shadowColor = NSColor.black.cgColor
    view.layer?.shadowOpacity = 0.05
    view.layer?.shadowRadius = 12
    view.layer?.shadowOffset = CGSize(width: 0, height: -2)
    return view
}
