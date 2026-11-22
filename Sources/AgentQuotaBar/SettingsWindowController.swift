import UserNotifications
import AppKit
import SwiftUI

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

final class AccentSwitch: NSHostingView<AccentSwitch.ToggleView> {
    final class Model: ObservableObject {
        @Published var isOn = false
        @Published var label = ""
        var changed: (() -> Void)?
    }

    struct ToggleView: View {
        @ObservedObject var model: Model

        var body: some View {
            Toggle(model.label, isOn: Binding(get: { model.isOn }, set: { newValue in
                model.isOn = newValue
                model.changed?()
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color(nsColor: Theme.accent))
            .accessibilityLabel(Text(model.label))
            .fixedSize()
        }
    }

    weak var target: AnyObject?
    var action: Selector?
    var isOn: Bool {
        get { rootView.model.isOn }
        set { rootView.model.isOn = newValue }
    }

    init() {
        let model = Model()
        super.init(rootView: ToggleView(model: model))
        model.changed = { [weak self] in
            guard let self, let action else { return }
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    required init(rootView: ToggleView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError() }

    override func setAccessibilityLabel(_ label: String?) {
        rootView.model.label = label ?? ""
    }
}

final class SettingsTabButton: NSButton {
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
        self.imagePosition = .noImage
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        self.imageScaling = .scaleProportionallyDown
        self.font = .systemFont(ofSize: 14, weight: .medium)
        self.wantsLayer = true
        self.layer?.cornerRadius = 7
        self.layer?.cornerCurve = .continuous
        setAccessibilityLabel(title)
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconRect = NSRect(x: 12, y: (bounds.height - 17) / 2, width: 17, height: 17)
        if Theme.design == .claude && selected {
            Theme.accent.setFill()
            NSBezierPath(rect: NSRect(x: 2, y: 7, width: 3, height: bounds.height - 14)).fill()
        }
        if Theme.design != .claude, let image {
            ProviderLogo.tint(image, color: contentTintColor ?? Theme.text).draw(in: iconRect)
        }
        if isHighlighted { Theme.text.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
        let caption = attributedTitle
        caption.draw(at: NSPoint(x: Theme.design == .claude ? 17 : iconRect.maxX + 11, y: (bounds.height - caption.size().height) / 2))
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
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
        let ink: NSColor = (selected && Theme.design != .original ? Theme.accent : selected ? (Theme.isDark() ? Theme.text : NSColor.white) : Theme.secondary).resolvedForAppearance()
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: selected ? .semibold : .medium),
            .foregroundColor: ink
        ])
        contentTintColor = ink
        layer?.backgroundColor = (selected ? (Theme.design != .original ? Theme.accentSoft : Theme.forest) : hovering ? Theme.hover : NSColor.clear).resolvedCGColor()
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(NSNumber(value: selected))
    }
}

/// Theme changes redraw the current window. Keep keyboard interaction on the
/// same native picker after a pointer selection.
private final class AppearanceSegments: ThemeSegments {
    weak var followingPicker: AppearanceSegments?
    weak var precedingPicker: AppearanceSegments?

    private func handleNavigation(_ event: NSEvent) -> Bool {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 48, let other = event.modifierFlags.contains(.shift) ? precedingPicker : followingPicker {
            return window?.makeFirstResponder(other) == true
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            let forward = (event.keyCode == 124) == (userInterfaceLayoutDirection == .leftToRight)
            let next = selectedSegment + (forward ? 1 : -1)
            if (0..<segmentCount).contains(next) {
                selectedSegment = next
                _ = sendAction(action, to: target)
            }
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        showKeyboardFocus()
        if !handleNavigation(event) { super.keyDown(with: event) }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if isEnabled { window?.makeFirstResponder(self) }
    }
}

final class SettingsWindowController: NSWindowController {
    private let service: QuotaService
    private let checkin: CheckinService
    private let onSaved: () -> Void
    private let onOpenSetup: (String) -> Void
    private let onAppearanceChanged: () -> Void
    private let onCheckin: () -> Void

    private let refreshPopup = SettingsPopUpButton(frame: .zero, pullsDown: false)
    private let proxyMode = SettingsPopUpButton(frame: .zero, pullsDown: false)
    private let proxyField = QuotaTextField()
    private let proxyError = NSTextField(labelWithString: "")
    private let thresholdError = NSTextField(labelWithString: "")
    private static let pickerWidth: CGFloat = 270
    private let modePicker = ThemeSegments()
    private let modeValues = ["auto", "fixed", "merged"]
    private weak var fixedChoiceRow: NSView?
    private let fixedProviderPopup = SettingsPopUpButton(frame: .zero, pullsDown: false)
    private let loginSwitch = AccentSwitch()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleLabel = NSTextField(labelWithString: "125%")
    private let hintLabel = NSTextField(labelWithString: "")
    private var suppressDirty = true
    private let themePicker = AppearanceSegments()
    private var pageHeadings: [NSTextField] = []
    private let appearancePicker = AppearanceSegments()
    private let appearanceModes = ["system", "light", "dark"]
    private let checkinSwitch = AccentSwitch()
    private let checkinHourPopup = SettingsPopUpButton(frame: .zero, pullsDown: false)
    private let checkinStatusLabel = NSTextField(labelWithString: "")
    private let checkinTitleLabel = NSTextField(labelWithString: "今日签到")
    private let checkinButton = NSButton(title: "立即签到", target: nil, action: nil)
    private let warningSlider = QuotaTextField()
    private let dangerSlider = QuotaTextField()
    private let notifySwitch = AccentSwitch()
    private let notifyPercentField = QuotaTextField()
    private let notifyStatusLabel = ThemedLabel(labelWithString: "")
    private let permissionMark = StatusMarkView()
    private let testNotifyButton = NSButton(title: "测试", target: nil, action: nil)
    private let notificationSettingsButton = NSButton(title: "权限设置", target: nil, action: nil)
    private var creditThresholdFields: [String: QuotaTextField] = [:]
    private let warningScale = NSSlider()
    private let dangerScale = NSSlider()
    private let resetColors = NSButton()
    private let colorKeys = ["healthyColor", "warningColor", "dangerColor"]
    private var colorWells: [NSColorWell] = []

    private let contentStack = FlippedStackView()
    private var pageViews: [NSView] = []
    private var navButtons: [SettingsTabButton] = []
    private var selectedPage = 0
    private var providerStatusViews: [String: (dot: ThemedSurfaceView, text: NSTextField)] = [:]
    private var visibilitySwitches: [String: AccentSwitch] = [:]
    private var checkinDetailStatusLabels: [String: NSTextField] = [:]
    private var browserFallbackRows: [NSView] = []
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

    private var providerOrder: [String] {
        let original = ["codex", "deepseek", "opencode", "trae", "workbuddy"]
        return original + ProviderRegistry.ids.filter { !original.contains($0) }
    }
    private let serviceList = NSStackView()
    private let servicePages = SettingsPopUpButton()
    private weak var displayHeading: NSTextField?
    private var displayHeadingPosition: NSLayoutConstraint?
    private var listedServices: [String] = []
    private var serviceViews: [String: NSView] = [:]
    private var agentDirectory: URL { service.config.url.deletingLastPathComponent().appendingPathComponent("agents", isDirectory: true) }
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
            contentRect: NSRect(x: 0, y: 0, width: 910, height: 586),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 910, height: 586)
        window.title = "Agent 额度设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = buildContent()
        window.autorecalculatesKeyViewLoop = true
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

        let container = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: 910, height: 586))
        container.wantsLayer = true
        container.isWindowCanvas = true
        container.surfaceColor = Theme.background

        let toolbar = ThemedSurfaceView()
        toolbar.wantsLayer = true
        toolbar.isNavigationSurface = true
        toolbar.surfaceColor = Theme.sidebar
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        buildSidebar(in: toolbar)

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

        let document = NSView()
        document.identifier = NSUserInterfaceItemIdentifier("settings-content")
        document.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(document)

        let top = toolbar.topAnchor.constraint(equalTo: container.topAnchor)
        let leading = toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let bottom = toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        toolbar.designLayout = { [weak toolbar] design in
            top.constant = design == .glass ? 8 : 0
            leading.constant = design == .glass ? 8 : 0
            bottom.constant = design == .glass ? -12 : 0
            toolbar?.layer?.cornerRadius = design == .glass ? 18 : 0
            toolbar?.surfaceColor = design == .claude ? Theme.background : Theme.sidebar
        }
        NSLayoutConstraint.activate([
            top, leading, bottom,
            toolbar.widthAnchor.constraint(equalToConstant: 194),
            saveBar.leadingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            saveBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            saveBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            saveBar.heightAnchor.constraint(equalToConstant: 38),

            saveBarLine.topAnchor.constraint(equalTo: saveBar.topAnchor),
            saveBarLine.leadingAnchor.constraint(equalTo: saveBar.leadingAnchor),
            saveBarLine.trailingAnchor.constraint(equalTo: saveBar.trailingAnchor),
            saveBarLine.heightAnchor.constraint(equalToConstant: 1),

            document.topAnchor.constraint(equalTo: container.topAnchor),
            document.leadingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            document.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            document.bottomAnchor.constraint(equalTo: saveBar.topAnchor),
        ])

        buildSaveBar(in: saveBar)

        document.addSubview(contentStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.detachesHiddenViews = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
        ])



        let menu = makeMenuBarPage()
        let alerts = makeAlertsPage()
        let services = makeServicesPage()
        let general = makeGeneralPage()
        let groups = [composePage([menu[0], menu[1], general[2]])] + alerts
            + [composePage([services[0], menu[2]]), services[1], composePage(Array(general.prefix(2)))]
        pageViews = zip(Self.destinations, groups).map { destination, group in
            composePage([pageHeader(destination.0), group])
        }
        for page in pageViews {
            page.identifier = NSUserInterfaceItemIdentifier("settings-page")
            page.isHidden = true
            contentStack.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        let startPage = Int(ProcessInfo.processInfo.environment["AQB_SETTINGS_PAGE"] ?? "0") ?? 0
        selectPage(min(max(0, startPage), pageViews.count - 1))

        return container
    }

    private static let destinations = [
        ("菜单栏", "menubar.rectangle"),
        ("低额度通知", "bell"), ("额度颜色", "paintpalette"),
        ("服务与账户", "person.2"), ("本机接入", "lock.shield"),
        ("运行与签到", "gearshape")
    ]

    private func buildSidebar(in bar: NSView) {
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent 额度")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        mark.contentTintColor = Theme.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 28).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let title = label("Agent 额度", size: 17, weight: .semibold, color: Theme.text)
        let subtitle = label(appVersionText, size: 12, color: Theme.secondary)
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
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 3
        nav.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(nav)

        for (index, item) in Self.destinations.enumerated() {
            if let title = [0: "显示", 1: "提醒", 3: "服务", 5: "应用"][index] {
                let heading = label(title, size: 12, weight: .semibold, color: Theme.secondary)
                nav.addArrangedSubview(heading)
                if index > 0 { nav.setCustomSpacing(13, after: navButtons[index - 1]) }
            }
            let button = SettingsTabButton(title: item.0, symbol: item.1,
                                       action: #selector(navTapped(_:)), target: self)
            button.tag = index
            button.keyEquivalent = String(index + 1)
            button.keyEquivalentModifierMask = .command
            button.toolTip = item.0 + "（⌘" + String(index + 1) + "）"
            button.alignment = .left
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.imageHugsTitle = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 166).isActive = true
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
            brand.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 17),
            brand.topAnchor.constraint(equalTo: bar.topAnchor, constant: 20),

            nav.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 18),

            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func buildSaveBar(in bar: NSView) {
        let openConfig = NSButton(title: "打开配置文件…", target: self, action: #selector(openConfig))
        openConfig.toolTip = "在默认编辑器中打开 config.json；会直接修改配置"
        openConfig.isBordered = false
        openConfig.font = .systemFont(ofSize: 12)
        openConfig.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        openConfig.contentTintColor = Theme.accent

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = Theme.secondary
        hintLabel.setAccessibilityLabel("保存状态")
        hintLabel.toolTip = "设置会即时保存；不需要手动点保存"
        hintLabel.stringValue = "更改会自动保存"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [hintLabel, spacer, openConfig])
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

    private func pageHeader(_ title: String) -> NSView {
        let heading = label(title, size: 26, weight: .bold, color: Theme.text)
        heading.font = Theme.headingFont(size: Theme.design == .claude ? 33 : 26, weight: .bold)
        pageHeadings.append(heading)
        return heading
    }

    private func settingSection(_ title: String, symbol: String, rows: [NSView]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let caption = label(title, size: 15, weight: .semibold)
        let heading = NSStackView(views: [icon, caption, NSView()])
        heading.spacing = 8
        let card = groupCard(rows)
        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        let wrap = ThemedSurfaceView()
        section.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(section)
        NSLayoutConstraint.activate([section.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: wrap.trailingAnchor), section.topAnchor.constraint(equalTo: wrap.topAnchor),
            section.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)])
        wrap.designLayout = { [weak section] design in
            section?.spacing = design == .claude ? 4 : 8
            icon.isHidden = design == .claude
            (caption as? ThemedLabel)?.applyRole(design == .claude ? Theme.accent : Theme.text)
            caption.font = Theme.headingFont(size: design == .claude ? 16 : 15, weight: .semibold)
        }
        return wrap
    }

    private func appearancePanel() -> NSView {
        func configure(_ picker: NSSegmentedControl, labels: [String], name: String, action: Selector) {
            picker.segmentCount = labels.count
            picker.trackingMode = .selectOne
            picker.segmentDistribution = .fillEqually
            picker.segmentStyle = .rounded
            picker.controlSize = .large
            picker.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true
            picker.setAccessibilityLabel(name)
            picker.target = self
            picker.action = action
            for (index, label) in labels.enumerated() { picker.setLabel(label, forSegment: index) }
        }
        configure(themePicker, labels: DesignTheme.allCases.map(\.title), name: "界面主题", action: #selector(themeChanged))
        configure(appearancePicker, labels: ["跟随系统", "浅色", "深色"], name: "明暗外观", action: #selector(appearanceChanged))
        themePicker.followingPicker = appearancePicker
        appearancePicker.precedingPicker = themePicker
        themePicker.nextKeyView = appearancePicker
        updateAppearanceChoices()
        return settingSection("界面外观", symbol: "circle.lefthalf.filled", rows: [
            controlRow("主题", themePicker, caption: nil), controlRow("明暗", appearancePicker, caption: nil)
        ])
    }

    @objc private func themeChanged() {
        let themes = DesignTheme.allCases
        guard themes.indices.contains(themePicker.selectedSegment) else { return }
        if persist(["designTheme": themes[themePicker.selectedSegment].rawValue]) { onAppearanceChanged() }
        updateAppearanceChoices()
    }

    private func makeGeneralPage() -> [NSView] {
        refreshPopup.removeAllItems()
        for (title, seconds) in refreshOptions {
            refreshPopup.addItem(withTitle: title)
            refreshPopup.lastItem?.representedObject = seconds
        }
        refreshPopup.font = .systemFont(ofSize: 12)
        refreshPopup.bezelStyle = .texturedRounded
        refreshPopup.controlSize = .large
        refreshPopup.setAccessibilityLabel("刷新频率")
        refreshPopup.target = self
        refreshPopup.action = #selector(refreshOptionChanged)
        refreshPopup.translatesAutoresizingMaskIntoConstraints = false
        refreshPopup.widthAnchor.constraint(equalToConstant: 96).isActive = true
        refreshPopup.setContentHuggingPriority(.required, for: .horizontal)
        refreshPopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        proxyMode.addItems(withTitles: ["跟随系统", "关闭代理", "自定义地址"])
        proxyMode.bezelStyle = .texturedRounded
        proxyMode.controlSize = .large
        proxyMode.setAccessibilityLabel("代理模式")
        proxyMode.target = self
        proxyMode.action = #selector(proxyModeChanged)
        proxyMode.widthAnchor.constraint(equalToConstant: 140).isActive = true
        proxyField.font = .systemFont(ofSize: 12)
        proxyField.bezelStyle = .roundedBezel
        proxyField.controlSize = .large
        proxyField.placeholderString = "http://127.0.0.1:7897"
        proxyField.setAccessibilityLabel("系统代理")
        proxyField.usesSingleLineMode = true
        proxyField.cell?.isScrollable = true
        proxyField.delegate = self
        proxyField.translatesAutoresizingMaskIntoConstraints = false
        proxyField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        proxyError.textColor = Theme.danger
        proxyError.isHidden = true
        let proxyControls = NSStackView(views: [proxyMode, proxyField])
        proxyControls.orientation = .horizontal
        proxyControls.alignment = .centerY
        proxyControls.spacing = 8
        let proxyGroup = NSStackView(views: [proxyControls, proxyError])
        proxyGroup.orientation = .vertical
        proxyGroup.alignment = .trailing
        proxyGroup.detachesHiddenViews = true
        proxyGroup.spacing = 4

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
        checkinHourPopup.bezelStyle = .texturedRounded
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

        let automationGroup = settingSection("自动签到", symbol: "calendar.badge.clock", rows: [
            controlRow("每日签到", checkinSwitch, caption: nil),
            separator(),
            controlRow("签到时间", checkinHourPopup, caption: nil),
            separator(),
            controlRow("签到状态", checkinStatusRow, caption: nil),
        ])

        let preferencesGroup = settingSection("运行与连接", symbol: "network", rows: [
            controlRow("刷新频率", refreshPopup, caption: "面板按此间隔更新，后台采样独立运行。"),
            separator(),
            controlRow("网络代理", proxyGroup, caption: nil),
            separator(),
            controlRow("开机自启动", loginColumn, caption: nil),
        ])

        return [preferencesGroup, automationGroup, appearancePanel()]
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
        checkinHourPopup.bezelStyle = .texturedRounded
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
            pageHeader("签到"),
            statusCard,
            groupLabel("计划"),
            settingsCard,
            groupLabel("今日明细"),
            detailCard,
        ])
    }

    private func checkinProviderRow(_ id: String, subtitle: String) -> NSView {
        let style = ProviderStyles.style(for: id)
        let avatar = ProviderMarkView(provider: id, size: 22)
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
        let current = service.config.string("menuBarMode", default: "auto")
        modePicker.segmentCount = mergedMenuBarModeAvailable || current == "merged" ? 3 : 2
        for index in 0..<modePicker.segmentCount {
            modePicker.setLabel(["最近使用", "固定服务", "额度优先"][index], forSegment: index)
            modePicker.setToolTip(["跟随最近使用的服务", "始终显示选定服务", "显示剩余额度最紧张的服务"][index], forSegment: index)
            modePicker.setWidth(0, forSegment: index)
        }
        modePicker.selectedSegment = modeValues.firstIndex(of: current) ?? 0
        fixedChoiceRow?.isHidden = current != "fixed"
    }

    private func populateFixedProviders() {
        let selected = service.config.string("menuBarProvider")
        fixedProviderPopup.removeAllItems()
        for id in editingOrder where !service.config.stringArray("hiddenProviders").contains(id) && service.config.bool("providers.\(id).enabled", default: true) {
            fixedProviderPopup.addItem(withTitle: ProviderStyles.style(for: id).shortName)
            fixedProviderPopup.lastItem?.representedObject = id
        }
        if let item = fixedProviderPopup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            fixedProviderPopup.select(item)
        } else if fixedProviderPopup.numberOfItems > 0 {
            fixedProviderPopup.selectItem(at: 0)
        }
        fixedProviderPopup.isEnabled = fixedProviderPopup.numberOfItems > 0
    }

    private func makeMenuBarPage() -> [NSView] {
        populateMenuBarModePopup()
        modePicker.segmentDistribution = .fillEqually
        modePicker.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true
        modePicker.trackingMode = .selectOne
        modePicker.segmentStyle = .rounded
        modePicker.selectedSegmentBezelColor = Theme.segmentTint
        modePicker.controlSize = .large
        modePicker.font = .systemFont(ofSize: 14, weight: .medium)
        modePicker.target = self
        modePicker.action = #selector(menuBarModeChanged)
        modePicker.setAccessibilityLabel("菜单栏显示方式")

        populateFixedProviders()
        fixedProviderPopup.font = .systemFont(ofSize: 14)
        fixedProviderPopup.bezelStyle = .texturedRounded
        fixedProviderPopup.controlSize = .large
        fixedProviderPopup.target = self
        fixedProviderPopup.action = #selector(fixedProviderSelected)
        fixedProviderPopup.setAccessibilityLabel("固定显示的服务")
        fixedProviderPopup.translatesAutoresizingMaskIntoConstraints = false
        fixedProviderPopup.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true

        scaleSlider.trackFillColor = Theme.accent
        scaleSlider.minValue = 0.5
        scaleSlider.maxValue = 1.5
        scaleSlider.doubleValue = service.menuBarIconScaleFactor
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        scaleSlider.isContinuous = true
        scaleSlider.setAccessibilityLabel("菜单栏图标大小")
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.widthAnchor.constraint(equalToConstant: 188).isActive = true

        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = Theme.secondary
        scaleLabel.stringValue = String(format: "%.2f×", scaleSlider.doubleValue)

        let resetScale = NSButton(title: "恢复默认", target: self, action: #selector(resetScale))
        resetScale.bezelStyle = .rounded
        resetScale.isBordered = true
        resetScale.font = .systemFont(ofSize: 12)
        resetScale.contentTintColor = Theme.accent

        let scaleRow = NSStackView(views: [scaleSlider, scaleLabel, resetScale])
        scaleRow.orientation = .horizontal
        scaleRow.alignment = .centerY
        scaleRow.spacing = 10

        let resetOrder = NSButton(title: "恢复默认顺序", target: self, action: #selector(resetOrder))
        resetOrder.bezelStyle = .rounded
        resetOrder.font = .systemFont(ofSize: 13, weight: .medium)
        resetOrder.contentTintColor = Theme.accent

        let fixed = controlRow("固定服务", fixedProviderPopup, caption: nil)
        fixedChoiceRow = fixed
        fixed.isHidden = modePicker.selectedSegment != 1
        let mode = settingSection("菜单栏图标", symbol: "menubar.rectangle", rows: [
            controlRow("显示方式", modePicker, caption: nil), fixed, separator(),
            controlRow("图标大小", scaleRow, caption: nil)
        ])
        orderSelector.setAccessibilityLabel("调整服务顺序")
        orderSelector.target = self
        orderSelector.action = #selector(orderSelectionChanged)
        for (button, title) in [(earlier, "上移"), (later, "下移")] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(moveOrder(_:))
        }
        reloadOrder()
        let moves = NSStackView(views: [orderSelector, earlier, later])
        let order = settingSection("服务顺序", symbol: "arrow.up.arrow.down", rows: [
            controlRow("额度页排序", moves, caption: nil), separator(), controlRow("默认顺序", resetOrder, caption: nil)
        ])
        windowRows.orientation = .vertical
        windowRows.alignment = .leading
        let periods = settingSection("主额度周期", symbol: "clock", rows: [windowRows])
        periods.isHidden = true
        windowSection = periods
        return [mode, periods, order]
    }

    private let windowRows = NSStackView()
    private let orderSelector = SettingsPopUpButton()
    private let earlier = NSButton()
    private let later = NSButton()

    private var editingOrder: [String] {
        let saved = service.config.stringArray("providerOrder")
        return (saved + providerOrder).reduce(into: []) { result, id in
            if providerOrder.contains(id), !result.contains(id) { result.append(id) }
        }
    }

    private func reloadOrder(selected: String? = nil) {
        let keep = selected ?? orderSelector.selectedItem?.representedObject as? String
        orderSelector.removeAllItems()
        for (index, id) in editingOrder.enumerated() {
            orderSelector.addItem(withTitle: String(index + 1) + "  " + ProviderStyles.style(for: id).shortName)
            orderSelector.lastItem?.representedObject = id
        }
        if let keep, let index = editingOrder.firstIndex(of: keep) { orderSelector.selectItem(at: index) }
        orderSelectionChanged()
    }

    @objc private func orderSelectionChanged() {
        earlier.isEnabled = orderSelector.indexOfSelectedItem > 0
        later.isEnabled = orderSelector.indexOfSelectedItem < orderSelector.numberOfItems - 1
    }

    @objc private func moveOrder(_ sender: NSButton) {
        var order = editingOrder
        guard let id = orderSelector.selectedItem?.representedObject as? String, let index = order.firstIndex(of: id) else { return }
        let next = index + (sender === earlier ? -1 : 1)
        guard order.indices.contains(next) else { return }
        order.swapAt(index, next)
        guard persist(["providerOrder": order]) else { return }
        reloadOrder(selected: id)
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    private var windowOptions: [String: [String]] = [:]
    private var windowOptionOrder: [String] = []
    private weak var windowSection: NSView?

    private let periodAgentPicker = SettingsPopUpButton()
    private let periodValuePicker = SettingsPopUpButton()

    @objc private func populatePeriodValues() {
        guard let id = periodAgentPicker.selectedItem?.representedObject as? String else { return }
        periodValuePicker.removeAllItems()
        periodValuePicker.addItems(withTitles: ["自动"] + (windowOptions[id] ?? []))
        let preferred = service.config.string("panelWindow." + id)
        if periodValuePicker.itemTitles.contains(preferred) { periodValuePicker.selectItem(withTitle: preferred) }
    }

    @objc private func savePickedPeriod() {
        guard let id = periodAgentPicker.selectedItem?.representedObject as? String else { return }
        let value = periodValuePicker.indexOfSelectedItem > 0 ? periodValuePicker.titleOfSelectedItem ?? "" : ""
        if persist(["panelWindow." + id: value]) {
            NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
        } else { populatePeriodValues() }
    }

    private func updateWindowPreferences(_ snapshot: QuotaSnapshot?) {
        guard let snapshot else { return }
        var options: [String: [String]] = [:]
        for provider in snapshot.providers where provider.status != "disabled" && service.config.bool("providers." + provider.id + ".enabled", default: true) && !service.config.stringArray("hiddenProviders").contains(provider.id) {
            let labels = provider.metrics.filter { $0.kind == "percent" && $0.remainingPercent != nil }.map(\.label)
            if provider.hasExpandableWindows, labels.count > 1 { options[provider.id] = labels }
        }
        let order = editingOrder.filter { options[$0] != nil }
        guard options != windowOptions || order != windowOptionOrder else { return }
        windowOptions = options
        windowOptionOrder = order
        windowRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        windowSection?.isHidden = options.isEmpty
        if order.count > 2 || options.values.contains(where: { $0.count > 3 || $0.contains(where: { $0.count > 6 }) }) {
            let previous = periodAgentPicker.selectedItem?.representedObject as? String
            periodAgentPicker.removeAllItems()
            for id in order {
                periodAgentPicker.addItem(withTitle: ProviderStyles.style(for: id).shortName)
                periodAgentPicker.lastItem?.representedObject = id
            }
            if let previous, let index = order.firstIndex(of: previous) { periodAgentPicker.selectItem(at: index) }
            periodAgentPicker.target = self
            periodAgentPicker.action = #selector(populatePeriodValues)
            periodAgentPicker.setAccessibilityLabel("选择周期所属服务")
            periodValuePicker.target = self
            periodValuePicker.action = #selector(savePickedPeriod)
            periodValuePicker.setAccessibilityLabel("主额度周期")
            populatePeriodValues()
            let row = NSStackView(views: [periodAgentPicker, NSView(), periodValuePicker])
            row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            windowRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: windowRows.widthAnchor).isActive = true
            return
        }
        for id in order {
            guard let labels = options[id] else { continue }
            let choices = ["自动"] + labels
            let menu = PeriodSegments(labels: choices, trackingMode: .selectOne, target: self, action: #selector(windowPreferenceChanged(_:)))
            menu.controlSize = .large
            menu.font = .systemFont(ofSize: 14, weight: .medium)
            menu.selectedSegmentBezelColor = Theme.segmentTint
            menu.identifier = NSUserInterfaceItemIdentifier(id)
            menu.selectedSegment = choices.firstIndex(of: service.config.string("panelWindow." + id)) ?? 0
            menu.segmentDistribution = .fillEqually
            menu.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true
            menu.setAccessibilityLabel(ProviderStyles.style(for: id).shortName + " 主额度周期")
            let row = controlRow(ProviderStyles.style(for: id).shortName, menu, caption: nil)
            windowRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: windowRows.widthAnchor).isActive = true
        }
    }

    @objc private func windowPreferenceChanged(_ sender: NSSegmentedControl) {
        guard let id = sender.identifier?.rawValue, sender.selectedSegment >= 0, let title = sender.label(forSegment: sender.selectedSegment) else { return }
        guard persist(["panelWindow." + id: sender.selectedSegment == 0 ? "" : title]) else {
            sender.selectedSegment = (0..<sender.segmentCount).first { sender.label(forSegment: $0) == service.config.string("panelWindow." + id) } ?? 0
            return
        }
        (sender as? PeriodSegments)?.moveSelection()
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    private func makeServicesPage() -> [NSView] {
        serviceList.orientation = .vertical
        serviceList.alignment = .leading
        serviceList.spacing = 0
        servicePages.target = self
        servicePages.action = #selector(displayServicePage)
        servicePages.setAccessibilityLabel("服务列表分页")
        rebuildServiceList()
        let tableHeader = NSView()
        tableHeader.heightAnchor.constraint(equalToConstant: 33).isActive = true
        let nameHeading = label("服务与连接状态", size: 12, weight: .medium, color: Theme.secondary)
        let visibilityHeading = label("显示", size: 12, weight: .medium, color: Theme.secondary)
        let accountHeading = label("账户与接入", size: 12, weight: .medium, color: Theme.secondary)
        for heading in [nameHeading, visibilityHeading, accountHeading] {
            tableHeader.addSubview(heading)
            heading.translatesAutoresizingMaskIntoConstraints = false
            heading.centerYAnchor.constraint(equalTo: tableHeader.centerYAnchor).isActive = true
        }
        nameHeading.leadingAnchor.constraint(equalTo: tableHeader.leadingAnchor).isActive = true
        accountHeading.trailingAnchor.constraint(equalTo: tableHeader.trailingAnchor).isActive = true
        let local = wrappingLabel(service.config.url.path, size: 12, color: Theme.secondary, width: 320)
        local.toolTip = service.config.url.path
        let privacy = wrappingLabel("OpenCode 和 WorkBuddy 可在本机登录态失效时读取浏览器 Cookie。首次使用可能需要钥匙串授权。", size: 12, color: Theme.secondary, width: 320)

        func insetText(_ field: NSTextField) -> NSView {
            let row = NSView()
            row.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                field.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
                field.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
            ])
            return row
        }

        let directory = ClosureButton(title: "接入目录…") { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                NSWorkspace.shared.open(agentDirectory)
            } catch { NSApp.presentError(error) }
        }
        directory.toolTip = "打开其他 Agent 的额度文件目录"
        let footer = NSStackView(views: [directory, NSView(), servicePages])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let table = groupCard([tableHeader, separator(), serviceList, footer])
        displayHeading = visibilityHeading
        alignServiceHeading()
        return [table, composePage([
            settingSection("浏览器授权", symbol: "lock", rows: [insetText(privacy)] + browserFallbackRows),
            settingSection("本机配置文件", symbol: "doc", rows: [insetText(local)])
        ])]
    }

    private func rebuildServiceList() {
        let names = providerOrder.map { ProviderStyles.style(for: $0).shortName }
        let identity = zip(providerOrder, names).map { $0 + ":" + $1 }
        guard identity != listedServices else { return }
        let oldPage = max(0, servicePages.indexOfSelectedItem)
        listedServices = identity
        servicePages.removeAllItems()
        for start in stride(from: 0, to: names.count, by: 5) {
            servicePages.addItem(withTitle: "服务 \(start + 1)–\(min(start + 5, names.count))")
        }
        servicePages.selectItem(at: min(oldPage, servicePages.numberOfItems - 1))
        servicePages.isHidden = names.count <= 5
        for (id, view) in serviceViews where !providerOrder.contains(id) {
            view.removeFromSuperview()
            serviceViews.removeValue(forKey: id)
            providerStatusViews.removeValue(forKey: id)
            visibilitySwitches.removeValue(forKey: id)
            accountPopups.removeValue(forKey: id)
        }
        for id in providerOrder {
            if serviceViews[id] == nil || ProviderRegistry.provider(withID: id)?.supportsMultipleAccounts == false {
                serviceViews[id] = providerRow(id)
            }
        }
        displayServicePage()
        reloadOrder()
        populateFixedProviders()
    }

    private func alignServiceHeading() {
        displayHeadingPosition?.isActive = false
        let offset = max(0, servicePages.indexOfSelectedItem) * 5
        guard let first = providerOrder.dropFirst(offset).first, let toggle = visibilitySwitches[first],
              let displayHeading, toggle.window != nil || serviceList.superview != nil else { return }
        displayHeadingPosition = displayHeading.centerXAnchor.constraint(equalTo: toggle.centerXAnchor)
        displayHeadingPosition?.isActive = true
    }

    @objc private func displayServicePage() {
        displayHeadingPosition?.isActive = false
        serviceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let offset = max(0, servicePages.indexOfSelectedItem) * 5
        for id in providerOrder.dropFirst(offset).prefix(5) {
            guard let row = serviceViews[id] else { continue }
            if !serviceList.arrangedSubviews.isEmpty {
                let rule = separator()
                serviceList.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: serviceList.widthAnchor).isActive = true
            }
            serviceList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: serviceList.widthAnchor).isActive = true
        }
        alignServiceHeading()
    }

    private func makeAlertsPage() -> [NSView] {
        colorWells = []
        for (index, color) in [QuotaStyle.healthyColor, QuotaStyle.warningColor, QuotaStyle.dangerColor].enumerated() {
            let well = NSColorWell()
            well.colorWellStyle = .minimal
            well.color = color.resolvedForAppearance()
            well.tag = index
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.setAccessibilityLabel(["充足颜色", "警戒颜色", "危险颜色"][index])
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorWells.append(well)
        }

        for (name, field) in [("警戒阈值", warningSlider), ("危险阈值", dangerSlider), ("通知阈值", notifyPercentField)] {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.alignment = .center
            field.setAccessibilityLabel(name + "（%）")
            field.cell?.sendsActionOnEndEditing = true
            field.target = self
            field.action = #selector(percentChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 88).isActive = true
        }
        func thresholdControl(_ field: NSTextField, _ slider: NSSlider, _ name: String) -> NSView {
            slider.trackFillColor = Theme.accent.resolvedForAppearance()
            slider.minValue = field === warningSlider ? 2 : 1
            slider.maxValue = field === warningSlider ? 99 : 98
            slider.isContinuous = false
            slider.setAccessibilityLabel(name + "滑块")
            slider.target = self
            slider.action = #selector(thresholdDragged(_:))
            slider.widthAnchor.constraint(equalToConstant: 142).isActive = true
            let row = NSStackView(views: [slider, field])
            row.spacing = 12
            return row
        }
        let warningControl = thresholdControl(warningSlider, warningScale, "警戒阈值")
        let dangerControl = thresholdControl(dangerSlider, dangerScale, "危险阈值")
        reloadPercentFields()

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 8
        for (index, title) in ["充足", "警戒", "危险"].enumerated() {
            colorRow.addArrangedSubview(label(title, size: 12, color: Theme.secondary))
            colorRow.addArrangedSubview(colorWells[index])
            if index < 2 { colorRow.setCustomSpacing(16, after: colorWells[index]) }
        }
        resetColors.title = "跟随主题"
        resetColors.target = self
        resetColors.action = #selector(restoreThemeColors)
        resetColors.setAccessibilityLabel("恢复主题额度颜色")
        resetColors.bezelStyle = .rounded
        colorRow.addArrangedSubview(resetColors)
        refreshColorWells()
        let colorGroup = settingSection("颜色与分级", symbol: "paintpalette", rows: [
            controlRow("颜色", colorRow, caption: nil),
            separator(),
            controlRow("警戒阈值（%）", warningControl, caption: "剩余达到或低于此值时进入警戒。可设 2–99%。"),
            separator(),
            controlRow("危险阈值（%）", dangerControl, caption: "剩余达到或低于此值时显示危险色。须低于警戒值。"),
        ])

        notifySwitch.isOn = service.config.bool("notifications.enabled", default: false)
        notifySwitch.target = self
        notifySwitch.action = #selector(notificationToggled)
        notifySwitch.setAccessibilityLabel("低额度通知")
        notifySwitch.translatesAutoresizingMaskIntoConstraints = false

        notifyStatusLabel.stringValue = service.config.bool("notifications.enabled", default: false) ? "已开启" : "已关闭"
        notifyStatusLabel.font = .systemFont(ofSize: 12)
        notifyStatusLabel.applyRole(Theme.tertiary)
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

        func thresholdField(_ id: String, fallback: Double) -> QuotaTextField {
            let field = QuotaTextField()
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.alignment = .center
            field.stringValue = NSNumber(value: service.config.double("style.thresholds.\(id)", default: fallback)).stringValue
            field.setAccessibilityLabel(ProviderStyles.style(for: id).shortName + (id == "deepseek" ? " CNY" : " 积分") + "阈值")
            field.cell?.sendsActionOnEndEditing = true
            field.target = self
            field.action = #selector(thresholdFieldChanged)
            field.widthAnchor.constraint(equalToConstant: 88).isActive = true
            creditThresholdFields[id] = field
            return field
        }

        thresholdError.textColor = Theme.danger
        thresholdError.isHidden = true
        let delivery = settingSection("通知", symbol: "bell", rows: [
            controlRow("低额度通知", notifyControl, caption: nil),
            separator(),
            controlRow("通知权限", permissionRow, caption: "共享屏幕或开启专注模式时，横幅可能只送达通知中心。")
        ])
        let notifyRows: [NSView] = [
            controlRow("百分比提醒线（%）", notifyPercentField, caption: nil),
            separator(),
            controlRow("Trae 积分", thresholdField("trae", fallback: 200), caption: nil),
            separator(),
            controlRow("WorkBuddy 积分", thresholdField("workbuddy", fallback: 500), caption: nil),
            separator(),
            controlRow("DeepSeek 余额（CNY）", thresholdField("deepseek", fallback: 5), caption: "其他币种和 OpenCode Zen 在余额耗尽时提醒。"),
            thresholdError,
        ]

        refreshNotificationStatus()
        return [
            composePage([delivery, settingSection("低额度提醒线", symbol: "slider.horizontal.3", rows: notifyRows)]), colorGroup
        ]
    }

    @discardableResult
    private func persist(_ changes: [String: Any]) -> Bool {
        guard !suppressDirty else { return false }
        do {
            try service.config.withRollback {
                for (key, value) in changes { service.config.set(key, value) }
                try service.config.save()
            }
            hintLabel.stringValue = "已自动保存"
            hintLabel.textColor = Theme.secondary
            return true
        } catch {
            suppressDirty = true
            loadValues()
            suppressDirty = false
            reloadPercentFields()
            for (id, field) in creditThresholdFields {
                field.stringValue = NSNumber(value: service.config.double("style.thresholds." + id, default: ["deepseek":5, "trae":200, "workbuddy":500][id] ?? 0)).stringValue
            }
            refreshColorWells()
            scaleSlider.doubleValue = service.menuBarIconScaleFactor
            scaleLabel.stringValue = String(format: "%.2f×", service.menuBarIconScaleFactor)
            notifySwitch.isOn = service.config.bool("notifications.enabled", default: false)
            hintLabel.stringValue = "保存失败，已保留原设置"
            hintLabel.textColor = Theme.danger
            return false
        }
    }

    private func saveStyle(_ changes: [String: Any]) {
        guard persist(changes) else { return }
        QuotaStyle.apply(service.config)
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
        onSaved()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let key = colorKeys[sender.tag]
        saveStyle(["style." + key: QuotaStyle.hex(sender.color), "style.customColors." + key: true])
        refreshColorWells()
    }

    @objc private func restoreThemeColors() {
        var changes: [String: Any] = [:]
        for key in colorKeys {
            changes["style." + key] = ""
            changes["style.customColors." + key] = false
        }
        saveStyle(changes)
        refreshColorWells()
    }

    private func refreshColorWells() {
        for (well, color) in zip(colorWells, [QuotaStyle.healthyColor, QuotaStyle.warningColor, QuotaStyle.dangerColor]) {
            well.color = color.resolvedForAppearance()
        }
        resetColors.isEnabled = QuotaStyle.hasCustomColors
    }

    @objc private func thresholdDragged(_ slider: NSSlider) {
        let field = slider === warningScale ? warningSlider : dangerSlider
        field.stringValue = NSNumber(value: QuotaStyle.percent(slider.doubleValue)).stringValue
        percentChanged(field)
    }

    @objc private func thresholdFieldChanged(_ sender: NSTextField) {
        guard let id = creditThresholdFields.first(where: { $0.value === sender })?.key else { return }
        let path = "style.thresholds.\(id)"
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite, (0...100_000).contains(value) else {
            sender.stringValue = NSNumber(value: service.config.double(path, default: ["deepseek": 5, "workbuddy": 500, "trae": 200][id] ?? 0)).stringValue
            thresholdError.stringValue = "\(ProviderStyles.style(for: id).shortName) 请输入 0–100000，已保留原值"
            thresholdError.isHidden = false
            sender.setAccessibilityHelp(thresholdError.stringValue)
            return
        }
        thresholdError.isHidden = true
        sender.setAccessibilityHelp(nil)
        if service.config.double(path, default: ["deepseek": 5, "workbuddy": 500, "trae": 200][id] ?? 0) == value { return }
        saveStyle([path: value])
    }

    private func reloadPercentFields() {
        warningSlider.stringValue = NSNumber(value: QuotaStyle.warningPercent).stringValue
        dangerSlider.stringValue = NSNumber(value: QuotaStyle.dangerPercent).stringValue
        notifyPercentField.stringValue = NSNumber(value: QuotaStyle.percent(min(100, max(0, service.config.double("notifications.percent", default: 20))))).stringValue
        warningScale.doubleValue = QuotaStyle.warningPercent
        dangerScale.maxValue = QuotaStyle.warningPercent - 1
        dangerScale.isEnabled = dangerScale.maxValue > dangerScale.minValue
        dangerScale.doubleValue = QuotaStyle.dangerPercent
    }

    @objc private func percentChanged(_ field: NSTextField) {
        let warning = field === warningSlider
        let notification = field === notifyPercentField
        let lower: Double = notification ? 0 : warning ? 2 : 1
        let upper: Double = notification ? 100 : warning ? 99 : QuotaStyle.warningPercent - 1
        guard let input = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (lower...upper).contains(input) else {
            reloadPercentFields()
            let message = "请输入 " + lower.formatted() + "–" + upper.formatted() + "%，已保留原值"
            field.setAccessibilityHelp(message)
            hintLabel.stringValue = message
            hintLabel.textColor = Theme.danger
            return
        }
        let value = QuotaStyle.percent(input)
        field.setAccessibilityHelp(nil)
        if notification { saveStyle(["notifications.percent": value]) }
        else if warning { saveStyle(["style.warningPercent": value, "style.dangerPercent": min(QuotaStyle.dangerPercent, QuotaStyle.percent(value - 1))]) }
        else { saveStyle(["style.dangerPercent": value]) }
        reloadPercentFields()
    }

    @objc private func notificationToggled() {
        if notifySwitch.isOn {
            NotificationService.shared.requestAuthorization { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.refreshNotificationStatus()
                    self.notifyStatusLabel.applyRole(Theme.success)
                    self.saveStyle(["notifications.enabled": self.notifySwitch.isOn])
                } else {
                    self.notifySwitch.isOn = false
                    self.notifyStatusLabel.stringValue = "系统通知已关闭"
                    self.notifyStatusLabel.applyRole(Theme.warning)
                    self.saveStyle(["notifications.enabled": self.notifySwitch.isOn])
                }
            }
        } else {
            notifyStatusLabel.stringValue = "已关闭"
            notifyStatusLabel.applyRole(Theme.tertiary)
            saveStyle(["notifications.enabled": notifySwitch.isOn])
        }
    }

    @objc private func testNotification() {
        func submit() {
            testNotifyButton.isEnabled = false
            notifyStatusLabel.stringValue = "正在提交测试通知…"
            NotificationService.shared.sendTest { [weak self] accepted in
                guard let self else { return }
                self.testNotifyButton.isEnabled = true
                self.notifyStatusLabel.stringValue = accepted ? "系统已接收" : "提交失败，请检查系统通知设置"
                if accepted { NotificationService.shared.presentationStatus { [weak self] _, text in self?.notifyStatusLabel.stringValue = "已提交 · " + text } }
                self.notifyStatusLabel.applyRole(accepted ? Theme.success : Theme.warning)
            }
        }
        NotificationService.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized, .provisional, .ephemeral:
                submit()
            case .denied:
                self.notifyStatusLabel.stringValue = "系统通知已关闭"
                self.notifyStatusLabel.applyRole(Theme.warning)
            case .notDetermined:
                NotificationService.shared.requestAuthorization { granted in
                    if granted {
                        submit()
                    } else {
                        self.notifyStatusLabel.stringValue = "未授权"
                        self.notifyStatusLabel.applyRole(Theme.warning)
                    }
                }
            @unknown default:
                break
            }
        }
    }

    private func refreshNotificationStatus() {
        NotificationService.shared.presentationStatus { [weak self] status, presentation in
            self?.presentNotificationPermission(status, presentation: presentation)
        }
    }

    func presentNotificationPermission(_ status: UNAuthorizationStatus, presentation: String) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            permissionMark.state = .authorized
            notifyStatusLabel.stringValue = presentation
            notifyStatusLabel.applyRole(Theme.success)
        case .denied:
            permissionMark.state = .denied
            notifyStatusLabel.stringValue = "系统通知被关闭"
            notifyStatusLabel.applyRole(Theme.warning)
        default:
            permissionMark.state = .idle
            notifyStatusLabel.stringValue = "尚未授权"
            notifyStatusLabel.applyRole(Theme.tertiary)
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

        let open = NSButton(title: "打开配置文件…", target: self, action: #selector(openConfig))
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
            pageHeader("关于"),
            group,
        ])
    }

    // MARK: - 组件

    private func composePage(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func groupLabel(_ text: String) -> NSTextField {
        label(text, size: 12, weight: .semibold, color: Theme.accent)
    }

    private func groupCard(_ rows: [NSView]) -> NSView {
        let card = ThemedSurfaceView()
        card.wantsLayer = true
        card.designLayout = { [weak card] design in
            card?.surfaceColor = design == .claude ? Theme.surfaceAlt : Theme.surface
            card?.surfaceBorderColor = Theme.separator
            card?.surfaceBorderWidth = design == .claude ? 0 : 0.5
            card?.layer?.cornerRadius = design == .claude ? 5 : design == .glass ? 15 : 12
        }
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
        if let popup = control as? NSPopUpButton {
            popup.controlSize = .large
            popup.font = .systemFont(ofSize: 14)
            popup.bezelStyle = .texturedRounded
            popup.contentTintColor = Theme.accent
        }
        let caption = captionText
        let titleLabel = label(title, size: 15, weight: .medium)
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
            top.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(top)
            NSLayoutConstraint.activate([
                top.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
                top.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
                top.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                top.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            ])
            return wrapper
        }

        let captionLabel = wrappingLabel(caption, size: 12, color: Theme.secondary, width: 500)
        let column = NSStackView(views: [top, captionLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
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
        let avatar = ProviderMarkView(provider: id, size: 24)
        let name = label(style.shortName, size: 14, weight: .semibold)

        let dot = ThemedSurfaceView()
        dot.wantsLayer = true
        dot.surfaceColor = Theme.tertiary
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dot.layer?.cornerRadius = 3

        let status = label("未检测", size: 12, color: Theme.secondary)
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
        visibility.isOn = !service.config.stringArray("hiddenProviders").contains(id) && service.config.bool("providers.\(id).enabled", default: true)
        visibility.target = self
        visibility.action = #selector(visibilityChanged(_:))
        visibility.identifier = NSUserInterfaceItemIdentifier(id)
        visibility.toolTip = "在面板和菜单栏显示"
        visibility.setAccessibilityLabel("\(style.shortName) 在面板和菜单栏显示")
        visibilitySwitches[id] = visibility

        // 账户选择器：默认隐藏，reloadAccounts() 在后端返回多账户时显示。
        let account = SettingsPopUpButton()
        account.font = .systemFont(ofSize: 11)
        account.bezelStyle = .texturedRounded
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
        let configure = ClosureButton(title: "配置…") { [weak self] in
            self?.onOpenSetup(id)
        }
        configure.setAccessibilityLabel("配置 \(ProviderStyles.style(for: id).shortName)")
        configure.font = .systemFont(ofSize: 12, weight: .medium)
        configure.isBordered = true
        configure.bezelStyle = .rounded
        configure.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true

        let manageAccounts = ClosureButton(title: "账户管理") { [weak self] in
            self?.manageAccounts(for: id)
        }
        manageAccounts.font = .systemFont(ofSize: 12, weight: .medium)
        manageAccounts.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        manageAccounts.identifier = NSUserInterfaceItemIdentifier(id)
        manageAccounts.setAccessibilityLabel("管理 \(style.shortName) 账户")
        manageAccounts.toolTip = "添加、编辑、删除或切换账户"

        if !autoCookie.isHidden { browserFallbackRows.append(controlRow(style.shortName, autoCookie, caption: nil)) }
        let actions: [NSView]
        if ProviderRegistry.provider(withID: id)?.supportsMultipleAccounts == true {
            actions = [manageAccounts, configure]
        } else {
            let source = ClosureButton(title: id == "doubao" ? "读取权限…" : "查看文件") { [weak self] in
                if id == "doubao" {
                    DoubaoQuota.openPermissions()
                } else if let directory = self?.agentDirectory {
                    NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent(id + ".json")])
                }
            }
            source.toolTip = id == "doubao" ? "在屏幕录制权限中允许 Agent 额度读取豆包侧栏" : "在访达中显示额度文件"
            actions = [source]
        }
        let row = NSStackView(views: [avatar, info, spacer, account, visibility] + actions)
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

    @objc private func autoCookieChanged(_ view: NSView) {
        guard let sender = view as? AccentSwitch else { return }
        guard let id = sender.identifier?.rawValue else { return }
        guard persist(["providers.\(id).autoCookie": sender.isOn]) else {
            sender.isOn = service.config.bool("providers.\(id).autoCookie", default: false)
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
                hintLabel.textColor = Theme.danger
                return
            }
        }
        hintLabel.stringValue = "已切换 \(ProviderStyles.style(for: id).shortName) 账户：\(accountLabel)"
        hintLabel.textColor = Theme.secondary
    }

    /// 仅供截图/回归：打开某家的账户管理 sheet。
    func openAccountManagerForDebug(_ provider: String, showForm: Bool = false) {
        guard let window, accountManager == nil else { return }
        let manager = AccountManagerWindowController(provider: provider, service: service) { [weak self] in
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
        let manager = AccountManagerWindowController(provider: id, service: service) { [weak self] in
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

    @objc private func navTapped(_ sender: SettingsTabButton) {
        selectPage(sender.tag)
    }

    /// 仅供截图/回归：按名称切换设置页。
    func showServicesPage() { selectPage(3) }

    func selectPageForDebug(_ name: String) {
        let map = ["general": 5, "menubar": 0, "services": 3, "alerts": 1, "periods": 0, "colors": 2, "appearance": 0, "access": 4, "checkin": 5]
        if let index = map[name] { selectPage(index) }
    }

    private func selectPage(_ index: Int) {
        window?.makeFirstResponder(nil)
        selectedPage = index
        for (i, page) in pageViews.enumerated() {
            page.isHidden = i != index
        }
        for (i, button) in navButtons.enumerated() {
            button.selected = i == index
        }
        contentStack.layoutSubtreeIfNeeded()
        if index == 3 { reloadOrder() }


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
            let seconds = config.refreshSeconds
            if !refreshPopup.itemArray.contains(where: { ($0.representedObject as? Int) == seconds }) {
                refreshPopup.addItem(withTitle: "\(seconds) 秒")
                refreshPopup.lastItem?.representedObject = seconds
            }
            refreshPopup.select(refreshPopup.itemArray.first { ($0.representedObject as? Int) == seconds })
        }
        let proxy = config.string("proxy", default: "auto")
        let index = ["", "auto"].contains(proxy) ? 0 : (["off", "none"].contains(proxy) ? 1 : 2)
        proxyMode.selectItem(at: index)
        proxyField.isHidden = index != 2
        proxyField.stringValue = index == 2 ? proxy : ""

        populateMenuBarModePopup()
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
        loginStatusLabel.textColor = LaunchAtLogin.requiresApproval ? Theme.warning : Theme.tertiary
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
        rebuildServiceList()
        updateWindowPreferences(snapshot)
        for id in providerOrder {
            guard let views = providerStatusViews[id] else { continue }
            guard let provider = snapshot?.providers.first(where: { $0.id == id }) else {
                views.text.stringValue = "未检测"
                views.text.textColor = Theme.secondary
                views.dot.surfaceColor = Theme.tertiary
                continue
            }
            if provider.cached == true {
                views.text.stringValue = provider.displaySubtitle
                views.dot.surfaceColor = Theme.warning
                continue
            }
            switch provider.status {
            case "ok":
                views.text.stringValue = provider.plan.map { "已连接 · \(Self.displayPlan($0))" } ?? "已连接"
                views.text.textColor = Theme.secondary
                views.dot.surfaceColor = QuotaStyle.healthyColor
            case "warn":
                views.text.stringValue = provider.detail ?? "额度紧张"
                views.text.textColor = Theme.warning
                views.dot.surfaceColor = Theme.warning
            case "error":
                views.text.stringValue = provider.error ?? "凭证失效"
                views.text.textColor = Theme.danger
                views.dot.surfaceColor = Theme.danger
            case "unconfigured":
                views.text.stringValue = "需要配置"
                views.text.textColor = Theme.warning
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
        let index = appearancePicker.selectedSegment
        guard appearanceModes.indices.contains(index) else { return }
        if persist(["appearance": appearanceModes[index]]) { onAppearanceChanged() }
        updateAppearanceChoices()
    }

    private func updateAppearanceChoices() {
        let current = DesignTheme(setting: service.config.string("designTheme"))
        themePicker.selectedSegment = DesignTheme.allCases.firstIndex(of: current) ?? 0
        appearancePicker.selectedSegment = appearanceModes.firstIndex(of: service.config.string("appearance")) ?? 0
        let fill = Theme.segmentTint
        for picker in [themePicker, appearancePicker, modePicker] { picker.selectedSegmentBezelColor = fill }
    }

    @objc private func checkinAutoChanged() {
        _ = persist(["checkin.auto": checkinSwitch.isOn])
        updateCheckinStatus()
    }

    @objc private func checkinHourChanged() {
        guard persist(["checkin.hour": checkinHourPopup.indexOfSelectedItem]) else { return }
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
        checkinHourPopup.isEnabled = checkinSwitch.isOn
        checkinButton.title = checkin.isRunning ? "签到中…" : "立即签到"
        checkinButton.isEnabled = !checkin.isRunning
        checkinButton.isHidden = checkin.hasCheckedInToday
        for (id, label) in checkinDetailStatusLabels {
            label.stringValue = CheckinService.result(for: id, in: service.config)
            label.textColor = label.stringValue == "已签到" ? Theme.success : Theme.secondary
        }
    }

    /// 外观变化时原地刷新颜色，不再重建 contentView / 重新 loadValues，
    /// 以免丢掉未保存的输入、first responder、滚动位置，也避免复用控件上累积约束。
    func reloadForAppearance() {
        guard let window, let content = window.contentView else { return }
        window.appearance = NSApp.appearance
        Theme.refreshViews(content)
        pageHeadings.forEach { $0.font = Theme.headingFont(size: Theme.design == .claude ? 33 : 26, weight: .bold) }
        if let sheet = window.attachedSheet?.contentView { Theme.refreshViews(sheet) }

        // 这些控件保存的是静态 CGColor / 具体色，需要在外观切换后重新解析。
        navButtons.forEach { $0.refreshAppearance() }
        updateAppearanceChoices()
        scaleSlider.needsDisplay = true
        refreshColorWells()
        warningScale.trackFillColor = Theme.accent.resolvedForAppearance()
        dangerScale.trackFillColor = Theme.accent.resolvedForAppearance()
        warningSlider.needsDisplay = true
        dangerSlider.needsDisplay = true

        // 状态色（成功/警告/危险）在深色外观下也是动态色，重算一次圆点与文字。
        updateProviderStatuses(service.snapshot)
        content.needsDisplay = true
    }

    @objc private func menuBarModeChanged() {
        guard !suppressDirty else { return }
        guard modeValues.indices.contains(modePicker.selectedSegment) else { return }
        let mode = modeValues[modePicker.selectedSegment]
        var changes: [String: Any] = ["menuBarMode": mode]
        if mode == "fixed", let id = fixedProviderPopup.selectedItem?.representedObject as? String {
            changes["menuBarProvider"] = id
        }
        if persist(changes) {
            fixedChoiceRow?.isHidden = mode != "fixed"
            onSaved()
        }
    }

    @objc private func fixedProviderSelected() {
        modePicker.selectedSegment = 1
        if persist(["menuBarMode": "fixed", "menuBarProvider": fixedProviderPopup.selectedItem?.representedObject as? String ?? "codex"]) { onSaved() }
    }

    @objc private func refreshOptionChanged() {
        guard !suppressDirty, let seconds = refreshPopup.selectedItem?.representedObject as? Int else { return }
        if persist(["refreshSeconds": seconds]) { onSaved() }
    }

    @objc private func proxyModeChanged() {
        let custom = proxyMode.indexOfSelectedItem == 2
        proxyField.isHidden = !custom
        proxyError.isHidden = true
        if custom {
            window?.makeFirstResponder(proxyField)
            if proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proxyError.isHidden = true
                hintLabel.stringValue = "自定义代理地址未填写，尚未保存"
                hintLabel.textColor = Theme.secondary
            } else {
                saveProxy()
            }
        } else {
            let mode = proxyMode.indexOfSelectedItem == 1 ? "off" : "auto"
            if persist(["proxy": mode]) { onSaved() }
        }
    }

    private func saveProxy() {
        guard !suppressDirty, proxyMode.indexOfSelectedItem == 2 else { return }
        let value = proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }),
              let url = URLComponents(string: value),
              ["http","https","socks4","socks4a","socks5","socks5h"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.port.map({ (1...65535).contains($0) }) ?? true else {
            hintLabel.stringValue = "代理地址无效，已保留上次设置"
            hintLabel.textColor = Theme.danger
            proxyError.stringValue = "代理地址无效"
            proxyError.isHidden = false
            proxyField.setAccessibilityHelp(hintLabel.stringValue)
            return
        }
        proxyError.isHidden = true
        proxyField.setAccessibilityHelp(nil)
        if persist(["proxy": value]) { onSaved() }
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
        let factor = scaleSlider.doubleValue
        scaleLabel.stringValue = String(format: "%.2f×", factor)
        let baseline = service.config.double("menuBarIconScaleBaseline", default: 1.43)
        guard persist(["menuBarIconScaleFactor": factor, "menuBarIconScale": factor * baseline]) else { return }
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func resetScale() {
        scaleSlider.doubleValue = 1.0
        scaleChanged()
    }

    @objc private func visibilityChanged(_ view: NSView) {
        guard let sender = view as? AccentSwitch else { return }
        guard let id = sender.identifier?.rawValue else { return }
        var hidden = Set(service.config.stringArray("hiddenProviders"))
        if sender.isOn {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        var changes: [String: Any] = ["hiddenProviders": Array(hidden).sorted()]
        let enabling = sender.isOn && !service.config.bool("providers.\(id).enabled", default: true)
        if enabling { changes["providers.\(id).enabled"] = true }
        guard persist(changes) else { sender.isOn.toggle(); return }
        populateFixedProviders()
        if enabling { service.refresh(only: id) }
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func resetOrder() {
        guard persist(["providerOrder": providerOrder]) else { return }
        reloadOrder()
        hintLabel.stringValue = "已恢复默认顺序"
        hintLabel.textColor = Theme.secondary
        NotificationCenter.default.post(name: .quotaSettingsChanged, object: nil)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(service.config.url)
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === proxyField {
            saveProxy()
        }
    }
}

// MARK: - 账户管理窗口

/// 以 sheet 形式管理某个 provider 的多个账户：添加（名称 + 凭据字段）、编辑、
/// 删除、设为当前。凭据字段完全来自 `AccountStore.credentialKeysByProvider`，
/// 不假设任何 provider 的扁平字段。
final class AccountManagerWindowController: NSWindowController {
    private var formFooter: NSView?
    private let provider: String
    private let store: AccountStore
    private let service: QuotaService
    private var formRevision = UUID()
    private let onChanged: () -> Void

    private let container = ThemedSurfaceView()
    private var accountPage = 0
    private let contentStack = FlippedStackView()
    private let listStack = NSStackView()
    private let formContainer = ThemedSurfaceView()
    private let formStack = NSStackView()
    private let formTitleLabel = NSTextField(labelWithString: "")
    private let labelField = NSTextField()
    private let identityField = NSTextField()
    private let accountMode = ThemeSegments(labels: ["Go 订阅", "Zen 余额"], trackingMode: .selectOne, target: nil, action: nil)
    private let editionSelector = SettingsPopUpButton()
    private var credentialRows: [String: NSView] = [:]
    private var credentialFields: [String: NSTextField] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerStatusLabel = NSTextField(labelWithString: "")
    private var accounts: [ProviderAccount] = []
    private var editingAccount: ProviderAccount?

    private var providerName: String { ProviderStyles.style(for: provider).shortName }

    init(provider: String, service: QuotaService, onChanged: @escaping () -> Void) {
        self.provider = provider
        self.service = service
        self.store = AccountStore(config: service.config)
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 235),
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
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 235)
        container.wantsLayer = true
        container.surfaceColor = Theme.background
        window.contentView = container

        let title = label("\(providerName) 账户", size: 22, weight: .bold)
        let subtitle = label(
            "凭据保存在本机。切换账户后按所选账户查询额度。",
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

        footerStatusLabel.font = .systemFont(ofSize: 12)
        footerStatusLabel.textColor = Theme.secondary
        footerStatusLabel.lineBreakMode = .byTruncatingTail
        footerStatusLabel.setAccessibilityLabel("账户管理状态")
        footerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let footer = NSStackView(views: [add, footerStatusLabel, footerSpacer, done])
        formFooter = footer
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
        formFooter?.isHidden = false
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

        if provider == "opencode" {
            accountMode.selectedSegment = 0
            accountMode.setAccessibilityLabel("账户额度模式")
            accountMode.target = self
            accountMode.action = #selector(accountModeChanged)
            formStack.addArrangedSubview(formRow("额度模式", accountMode))
        }
        for key in AccountStore.credentialKeys(for: provider) {
            if key == "edition" {
                for (id, name) in ProviderRegistry.traeEditions {
                    editionSelector.addItem(withTitle: name)
                    editionSelector.lastItem?.representedObject = id
                }
                editionSelector.setAccessibilityLabel("Trae 版本")
                formStack.addArrangedSubview(formRow("版本", editionSelector))
                continue
            }
            let field: NSTextField = Self.isSecret(key) ? NSSecureTextField() : NSTextField()
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.placeholderString = Self.placeholder(for: key)
            field.setAccessibilityLabel(Self.displayName(for: key))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            credentialFields[key] = field
            let row = formRow(Self.displayName(for: key), field)
            credentialRows[key] = row
            formStack.addArrangedSubview(row)
        }

        statusLabel.font = .systemFont(ofSize: 12)
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
        listStack.isHidden = !formContainer.isHidden
        accounts = store.accounts(for: provider)
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let activeID = store.activeAccountID(for: provider)
        defer { resizeSheet(expanded: !formContainer.isHidden) }
        guard !accounts.isEmpty else {
            let empty = label(
                "还没有账户。点下方「添加账户」创建第一个账号。",
                size: 13,
                color: Theme.secondary
            )
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 0
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }
        let pageSize = 4
        let pageCount = (accounts.count + pageSize - 1) / pageSize
        accountPage = min(max(0, accountPage), pageCount - 1)
        for account in accounts.dropFirst(accountPage * pageSize).prefix(pageSize) {
            let card = accountCard(account, activeID: activeID)
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        if pageCount > 1 {
            let prev = NSButton(title: "上一页", target: self, action: #selector(turnAccountPage(_:)))
            let next = NSButton(title: "下一页", target: self, action: #selector(turnAccountPage(_:)))
            prev.tag = -1
            next.tag = 1
            prev.isEnabled = accountPage > 0
            next.isEnabled = accountPage + 1 < pageCount
            listStack.addArrangedSubview(NSStackView(views: [prev, label("\(accountPage + 1) / \(pageCount)", size: 12), next]))
        }
    }

    @objc private func turnAccountPage(_ sender: NSButton) {
        accountPage += sender.tag
        reload()
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
        let subtitle = label(details.joined(separator: " · "), size: 12, color: Theme.tertiary)
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
            delete.contentTintColor = Theme.danger
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

    @objc private func accountModeChanged() {
        let go = accountMode.selectedSegment == 0
        credentialRows["apiKey"]?.isHidden = !go
        credentialRows["cookie"]?.isHidden = go
        credentialRows["workspaceId"]?.isHidden = go
        formRevision = UUID()
        if !formContainer.isHidden { resizeSheet(expanded: true) }
    }

    private func beginForm(editing account: ProviderAccount?) {
        formRevision = UUID()
        editingAccount = account
        formTitleLabel.stringValue = account == nil ? "添加账户" : "编辑账户"
        if provider == "opencode" {
            accountMode.selectedSegment = AccountStore.mode(for: account?.credentials ?? [:], fallback: account?.credentials["mode"] ?? "go") == "go" ? 0 : 1
            accountModeChanged()
        }
        if provider == "trae" {
            let edition = account?.credentials["edition"] ?? service.config.string("providers.trae.edition", default: "cn")
            editionSelector.selectItem(at: editionSelector.itemArray.firstIndex { $0.representedObject as? String == edition } ?? 0)
        }
        labelField.stringValue = account?.label ?? ""
        identityField.stringValue = account?.account ?? ""
        for (key, field) in credentialFields {
            field.stringValue = account?.credentials[key] ?? ""
        }
        statusLabel.stringValue = ""
        formFooter?.isHidden = true
        listStack.isHidden = true
        formContainer.isHidden = false
        contentStack.layoutSubtreeIfNeeded()
        resizeSheet(expanded: true)
        window?.makeFirstResponder(labelField)
    }

    private func resizeSheet(expanded: Bool) {
        guard let window else { return }
        let available = window.screen?.visibleFrame.height ?? 720
        let height: CGFloat = expanded ? min(available, max(420, contentStack.fittingSize.height + 145)) : min(available, max(208, contentStack.fittingSize.height + 150))
        var frame = window.frame
        let delta = height - frame.height
        frame.size.height = height
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
        container.setFrameSize(NSSize(width: 600, height: height))
        contentStack.layoutSubtreeIfNeeded()
    }

    private func cancelForm() {
        formRevision = UUID()
        listStack.isHidden = false
        editingAccount = nil
        formFooter?.isHidden = false
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

        if provider == "opencode" {
            let go = accountMode.selectedSegment == 0
            guard credentials[go ? "apiKey" : "cookie"]?.isEmpty == false else {
                setStatus(go ? "请填写 Go API Key" : "请填写 Zen Cookie", error: true)
                return
            }
            credentials["mode"] = go ? "go" : "zen"
        } else if provider == "trae" {
            credentials["edition"] = editionSelector.selectedItem?.representedObject as? String
        }
        do { try AccountStore.validate(credentials, for: provider) }
        catch { setStatus(error.localizedDescription, error: true); return }

        let draft = credentialFields.mapValues(\.stringValue)
        let id = UUID()
        formRevision = id
        let selection = service.config.string("providers.\(provider).selectionRevision")
        let accountRevision = service.config.string("providers.\(provider).quotaRevision")
        var candidate = service.config.dictionary("providers." + provider) ?? [:]
        for key in AccountStore.credentialKeys(for: provider) { candidate.removeValue(forKey: key) }
        for (key, value) in credentials { candidate[key] = value }
        candidate["enabled"] = true
        setStatus("正在验证…", error: false)
        service.verify(provider: provider, candidate: candidate) { [weak self] result in
            guard let self, self.formRevision == id else { return }
            guard (self.provider != "trae" || self.editionSelector.selectedItem?.representedObject as? String == credentials["edition"]), self.credentialFields.mapValues(\.stringValue) == draft,
                  self.labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == labelText,
                  self.identityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == identity,
                  self.service.config.string("providers.\(self.provider).selectionRevision") == selection,
                  self.service.config.string("providers.\(self.provider).quotaRevision") == accountRevision else {
                self.setStatus("输入或当前账户已变更，请重新验证", error: true)
                return
            }
            guard case .success(let status) = result, status.isUsable else {
                self.setStatus("验证失败，原账户已保留", error: true)
                return
            }
            self.commitAccount(labelText, identity: identity, credentials: credentials)
        }
    }

    private func commitAccount(_ labelText: String, identity: String, credentials: [String: String]) {
        do {
            if var account = editingAccount {
                account.label = labelText
                account.account = identity.isEmpty ? nil : identity
                account.credentials = credentials
                try store.updateAccount(account, for: provider)
            } else {
                _ = try store.addAccount(for: provider, label: labelText, account: identity.isEmpty ? nil : identity, credentials: credentials)
            }
            editingAccount = nil
            formFooter?.isHidden = false
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
        statusLabel.textColor = error ? Theme.danger : Theme.success
        footerStatusLabel.stringValue = text
        footerStatusLabel.textColor = error ? Theme.danger : Theme.success
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
