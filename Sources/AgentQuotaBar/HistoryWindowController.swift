import AppKit

/// 独立的用量历史窗口：按月展示每天的使用强度。
/// 颜色只用一个绿色色相，用深浅表达级别，避免把不同 provider 的额度单位硬凑在一起。
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let scopeMenu = NSMenu(title: "历史视图")
    private let mainScopeItem = NSMenuItem()
    private let heading = NSTextField(labelWithString: "用量历史")
    private let monthLabel = NSTextField(labelWithString: "")
    private static let windowSize = NSSize(width: 840, height: 506)
    private let yearLabel = NSTextField(labelWithString: "")
    private let activeCount = NSTextField(labelWithString: "")
    private let streakCount = NSTextField(labelWithString: "")
    private let selectedDate = NSTextField(labelWithString: "")
    private let weekdayLabel = NSTextField(labelWithString: "")
    private let coverageLabel = NSTextField(labelWithString: "")
    private var cardBottom: NSLayoutConstraint!
    private weak var statusRow: NSStackView?
    private var entriesForDay: [String: [UsageHistoryEntry]] = [:]
    private var ratingPopover: NSPopover?
    private let currentLabel = NSTextField(labelWithString: "")
    private let calendarStack = MonthGrid()
    private let detailRows = LedgerStack()
    private var selectedDay = ""
    private var lastCalendarRevealKey = ""
    private var overallLocation: (month: Int, day: String)?
    private let backButton = NSButton()
    private let scopeButton = NSButton()
    private var dayButtons: [HistoryDayCell] = []
    private let legendRow = NSStackView()
    private var providerID: String
    private var visibleIDs: [String] {
        let config = ConfigStore()
        let order = config.stringArray("providerOrder").filter { ProviderRegistry.ids.contains($0) }
        var seen = Set<String>()
        let ids = (order + ProviderRegistry.ids).filter { seen.insert($0).inserted }
        // 隐藏只影响菜单栏/面板；历史记录不能因为“当前不显示”就消失。
        // 否则用户关掉 Codex 后，之前的所有 Codex 用量和重置都会从日历里蒸发。
        return ids.filter { config.bool("providers.\($0).enabled", default: true) }
    }
    private let prev = NSButton()
    private let next = NSButton()
    private var monthOffset = 0
    private var calendar: Calendar
    var currentSnapshotProvider: (() -> QuotaSnapshot?)?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(providerID: String = "all") {
        self.providerID = providerID
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一开头
        self.calendar = cal

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "用量历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentMinSize = NSSize(width: 680, height: 506)
        window.contentView = buildContent()
        window.setContentSize(Self.windowSize)
        populateProviders()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        let root = ThemedSurfaceView(frame: NSRect(origin: .zero, size: Self.windowSize))
        root.wantsLayer = true
        root.isWindowCanvas = true
        root.surfaceColor = Palette.paper


        let masthead = panel(color: Palette.forest, border: false)
        let monthCard = panel(color: Palette.calendar)
        let calendarPaper = panel(color: Palette.calendar)
        monthCard.addSubview(calendarPaper)
        let dayCard = panel(color: Theme.surface)
        for item in [masthead, monthCard, dayCard] { root.addSubview(item) }

        let mark = symbol("calendar", color: .white, size: 23)
        heading.font = Theme.headingFont(size: 22, weight: .semibold)
        heading.textColor = .white
        heading.toolTip = "右键选择历史视图"
        root.menu = scopeMenu
        masthead.menu = scopeMenu
        heading.menu = scopeMenu
        backButton.title = "返回整体"
        backButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.isBordered = false
        backButton.contentTintColor = Theme.accent
        backButton.keyEquivalent = "["
        backButton.keyEquivalentModifierMask = .command
        backButton.toolTip = "返回原来选中的日期（⌘[）"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(returnToOverall)
        backButton.setAccessibilityLabel("返回整体历史")
        scopeButton.title = "整体历史"
        scopeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        scopeButton.imagePosition = .imageTrailing
        scopeButton.isBordered = false
        scopeButton.font = .systemFont(ofSize: 12, weight: .medium)
        scopeButton.contentTintColor = .white
        scopeButton.target = self
        scopeButton.action = #selector(showScopeMenu)
        scopeButton.setAccessibilityLabel("选择历史服务")
        scopeButton.toolTip = "选择整体历史或单个服务"
        scopeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let scope = row([mark, heading, scopeButton], spacing: 10)
        let stats = row([stat("本月使用", activeCount), stat("连续使用", streakCount)], spacing: 24)
        let top = row([scope, NSView(), stats], spacing: 16)
        embed(top, in: masthead, inset: 19, centered: true)

        yearLabel.font = .systemFont(ofSize: 11, weight: .medium)
        yearLabel.textColor = Theme.secondary
        monthLabel.font = .systemFont(ofSize: 28, weight: .bold)
        monthLabel.textColor = Theme.text
        let dateHeading = column([yearLabel, monthLabel], spacing: 0)
        for (button, icon, name, action) in [(prev, "chevron.left", "上个月", #selector(previousMonth)),
                                              (next, "chevron.right", "下个月", #selector(nextMonth))] {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: name)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(name)
            button.toolTip = name
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let today = NSButton(title: "今天", target: self, action: #selector(goToToday))
        today.bezelStyle = .rounded
        today.setAccessibilityLabel("回到今天")
        for button in [prev, today, next] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        }
        today.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let monthControls = row([prev, today, next], spacing: 3)
        let monthNavigation = ThemedSurfaceView()
        monthNavigation.wantsLayer = true
        monthNavigation.layer?.cornerRadius = 14
        monthNavigation.isNavigationSurface = true
        monthNavigation.surfaceColor = .clear
        monthControls.translatesAutoresizingMaskIntoConstraints = false
        monthNavigation.addSubview(monthControls)
        NSLayoutConstraint.activate([monthControls.topAnchor.constraint(equalTo: monthNavigation.topAnchor, constant: 3),
            monthControls.bottomAnchor.constraint(equalTo: monthNavigation.bottomAnchor, constant: -3),
            monthControls.leadingAnchor.constraint(equalTo: monthNavigation.leadingAnchor, constant: 5),
            monthControls.trailingAnchor.constraint(equalTo: monthNavigation.trailingAnchor, constant: -5)])
        let navigation = row([dateHeading, NSView(), monthNavigation], spacing: 4)
        let weekdays = row(["一","二","三","四","五","六","日"].map {
            let day = label($0, size: 12, weight: .medium, color: Theme.secondary)
            day.alignment = .center
            return day
        }, spacing: 5)
        weekdays.identifier = NSUserInterfaceItemIdentifier("history-weekdays")
        weekdays.distribution = .fillEqually
        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        buildLegend()
        let rule = separator()
        for part in [navigation, weekdays, calendarStack, rule, legendRow] {
            part.translatesAutoresizingMaskIntoConstraints = false
            monthCard.addSubview(part)
            part.leadingAnchor.constraint(equalTo: monthCard.leadingAnchor, constant: 16).isActive = true
            part.trailingAnchor.constraint(equalTo: monthCard.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            calendarPaper.leadingAnchor.constraint(equalTo: monthCard.leadingAnchor),
            calendarPaper.trailingAnchor.constraint(equalTo: monthCard.trailingAnchor),
            calendarPaper.topAnchor.constraint(equalTo: weekdays.topAnchor, constant: -6),
            calendarPaper.bottomAnchor.constraint(equalTo: monthCard.bottomAnchor),
            navigation.topAnchor.constraint(equalTo: monthCard.topAnchor, constant: 15),
            weekdays.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 10),
            calendarStack.topAnchor.constraint(equalTo: weekdays.bottomAnchor, constant: 8),
            rule.topAnchor.constraint(greaterThanOrEqualTo: calendarStack.bottomAnchor, constant: 10),
            rule.bottomAnchor.constraint(equalTo: legendRow.topAnchor, constant: -9),
            legendRow.bottomAnchor.constraint(equalTo: monthCard.bottomAnchor, constant: -14)
        ])

        selectedDate.font = .systemFont(ofSize: 26, weight: .bold)
        selectedDate.textColor = Theme.text
        weekdayLabel.font = .systemFont(ofSize: 12, weight: .medium)
        weekdayLabel.textColor = Theme.secondary
        coverageLabel.font = .systemFont(ofSize: 12)
        coverageLabel.textColor = Theme.secondary
        let dateLine = row([selectedDate, weekdayLabel, NSView()], spacing: 9)
        let detailsHeader = row([coverageLabel, NSView(), backButton], spacing: 4)
        let headings = column([dateLine, detailsHeader], spacing: 5)
        headings.alignment = .width
        headings.setContentHuggingPriority(.required, for: .vertical)
        headings.setContentCompressionResistancePriority(.required, for: .vertical)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        detailRows.orientation = .vertical
        detailRows.alignment = .width
        detailRows.spacing = 0
        detailRows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = detailRows
        let line = separator()
        for child in [headings, line, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            dayCard.addSubview(child)
            child.leadingAnchor.constraint(equalTo: dayCard.leadingAnchor, constant: 17).isActive = true
            child.trailingAnchor.constraint(equalTo: dayCard.trailingAnchor, constant: -17).isActive = true
        }
        NSLayoutConstraint.activate([
            headings.topAnchor.constraint(equalTo: dayCard.topAnchor, constant: 17),
            line.topAnchor.constraint(equalTo: headings.bottomAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: dayCard.bottomAnchor, constant: -12),
            detailRows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            detailRows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            detailRows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let status = row([symbol("gauge.with.dots.needle.50percent", color: Theme.secondary, size: 14), currentLabel], spacing: 7)
        status.translatesAutoresizingMaskIntoConstraints = false
        statusRow = status
        currentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentLabel.textColor = Theme.secondary
        currentLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        cardBottom = monthCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        let calendarFirst = [monthCard.leadingAnchor.constraint(equalTo: masthead.leadingAnchor),
            dayCard.leadingAnchor.constraint(equalTo: monthCard.trailingAnchor, constant: 10),
            dayCard.trailingAnchor.constraint(equalTo: masthead.trailingAnchor)]
        let detailFirst = [dayCard.leadingAnchor.constraint(equalTo: masthead.leadingAnchor),
            monthCard.leadingAnchor.constraint(equalTo: dayCard.trailingAnchor, constant: 12),
            monthCard.trailingAnchor.constraint(equalTo: masthead.trailingAnchor)]
        let headerHeight = masthead.heightAnchor.constraint(equalToConstant: 72)
        root.designLayout = { [weak self, weak masthead, weak monthCard, weak dayCard] design in
            guard let self else { return }
            NSLayoutConstraint.deactivate(calendarFirst + detailFirst)
            NSLayoutConstraint.activate(design == .claude ? detailFirst : calendarFirst)
            let original = design == .original
            masthead?.surfaceColor = original ? Palette.forest : .clear
            headerHeight.constant = design == .claude ? 66 : (original ? 72 : 60)
            mark.isHidden = !original
            self.heading.textColor = original ? .white : Theme.text
            self.heading.font = Theme.headingFont(size: design == .claude ? 31 : 23, weight: .semibold)
            // masthead 在玻璃/Claude 主题下是浅色透明底，白色 scope 文案会消失。
            self.scopeButton.contentTintColor = original ? .white : Theme.accent
            self.monthLabel.font = Theme.headingFont(size: design == .claude ? 23 : 28, weight: .bold)
            self.selectedDate.font = Theme.headingFont(size: design == .claude ? 30 : 26, weight: .bold)
            for number in [self.activeCount, self.streakCount] { number.textColor = original ? .white : Theme.text }
            for panel in [monthCard, dayCard] {
                panel?.surfaceBorderWidth = design == .claude ? 0 : 1
                panel?.layer?.cornerRadius = design == .claude ? 0 : 13
            }
            dayCard?.surfaceColor = design == .claude ? .clear : Theme.surface
            calendarPaper.isHidden = design != .glass
            monthCard?.surfaceBorderWidth = original ? 1 : 0
            monthCard?.surfaceColor = design == .glass ? .clear : (original ? Palette.calendar : Theme.sidebar)
            for button in [self.prev, today, self.next] { button.isBordered = design != .glass }
        }
        NSLayoutConstraint.activate([
            masthead.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            masthead.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            masthead.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            headerHeight,
            monthCard.topAnchor.constraint(equalTo: masthead.bottomAnchor, constant: 12),
            monthCard.widthAnchor.constraint(equalTo: masthead.widthAnchor, multiplier: 0.54),
            dayCard.topAnchor.constraint(equalTo: monthCard.topAnchor),
            dayCard.bottomAnchor.constraint(equalTo: monthCard.bottomAnchor),
            cardBottom,
            status.leadingAnchor.constraint(equalTo: masthead.leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: masthead.trailingAnchor),
            status.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -19)
        ])
        return root
    }

    private func panel(color: NSColor, border: Bool = true) -> ThemedSurfaceView {
        let view = ThemedSurfaceView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.surfaceColor = color
        view.layer?.cornerRadius = 13
        view.layer?.cornerCurve = .continuous
        if border { view.surfaceBorderColor = Palette.line; view.surfaceBorderWidth = 1 }
        return view
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func embed(_ view: NSView, in parent: NSView, inset: CGFloat, centered: Bool = false) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset).isActive = true
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset).isActive = true
        if centered { view.centerYAnchor.constraint(equalTo: parent.centerYAnchor).isActive = true }
        else {
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset).isActive = true
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset).isActive = true
        }
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        view.contentTintColor = color
        return view
    }

    private func stat(_ title: String, _ value: NSTextField) -> NSView {
        value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        value.textColor = .white
        return column([label(title, size: 11, weight: .medium, color: Theme.historyCaption), row([value, label("天", size: 11, color: Theme.historyCaption)], spacing: 4)], spacing: 1)
    }

    private func swatch(_ level: UsageLevel, size: CGFloat) -> NSView {
        let swatch = panel(color: level.fill, border: level == .none)
        swatch.layer?.cornerRadius = 3
        swatch.layer?.masksToBounds = true
        swatch.widthAnchor.constraint(equalToConstant: size).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: size).isActive = true
        if level == .spent { SpendHatch.cover(swatch) }
        return swatch
    }

    private func buildLegend() {
        legendRow.spacing = 7
        legendRow.distribution = .equalSpacing
        for level in UsageLevel.grades {
            let item = row([swatch(level, size: 10), label(level.title, size: 11, color: Theme.secondary)], spacing: 4)
            legendRow.addArrangedSubview(item)
        }
        legendRow.addArrangedSubview(row([swatch(.spent, size: 10), label("已使用", size: 11, color: Theme.secondary)], spacing: 4))
        let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!, target: self, action: #selector(explainRating(_:)))
        info.isBordered = false
        info.contentTintColor = Theme.accent
        info.setAccessibilityLabel("分档说明")
        info.toolTip = "分档说明"
        info.widthAnchor.constraint(equalToConstant: 24).isActive = true
        info.heightAnchor.constraint(equalToConstant: 24).isActive = true
        legendRow.addArrangedSubview(info)
    }

    @objc private func explainRating(_ sender: NSButton) {
        if let ratingPopover, ratingPopover.isShown { ratingPopover.performClose(sender); return }
        let width: CGFloat = 262
        let content = column([], spacing: 8)
        content.alignment = .width
        content.wantsLayer = true
        sender.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = Theme.surface.cgColor
        }
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        let title = label("每日额度消耗", size: 16, weight: .semibold)
        title.alignment = .left
        content.addArrangedSubview(title)
        for level in UsageLevel.grades {
            let value = label(level.rangeText, size: 12, color: Theme.secondary)
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            content.addArrangedSubview(row([swatch(level, size: 12), label(level.title, size: 13), NSView(), value], spacing: 7))
        }
        content.addArrangedSubview(separator())
        content.addArrangedSubview(row([swatch(.spent, size: 12), label(UsageLevel.spent.title, size: 12), NSView()], spacing: 7))
        let note = wrappingLabel("订阅按所选周期计算，积分和金额按当天首次余额折算。整体取可计算服务的平均值，包含零消耗。", size: 12, color: Theme.secondary, width: width - 36)
        note.alignment = .left
        content.addArrangedSubview(note)
        for item in content.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36).isActive = true
        }
        content.widthAnchor.constraint(equalToConstant: width).isActive = true
        let controller = NSViewController()
        controller.view = content
        let size = NSSize(width: width, height: ceil(content.fittingSize.height))
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.appearance = sender.effectiveAppearance
        popover.behavior = .transient
        popover.animates = false
        ratingPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func populateProviders() {
        let ids = ["all"] + visibleIDs
        if !ids.contains(providerID) { providerID = "all" }
        scopeMenu.removeAllItems()
        for id in ids {
            let title = id == "all" ? "整体历史" : ProviderStyles.style(for: id).shortName
            let item = scopeMenu.addItem(withTitle: title, action: #selector(providerChanged(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            item.state = id == providerID ? .on : .off
        }
        backButton.isHidden = providerID == "all"
        heading.stringValue = providerID == "all" ? "用量历史" : ProviderStyles.style(for: providerID).shortName + " 用量历史"
        scopeButton.title = providerID == "all" ? "整体历史" : ProviderStyles.style(for: providerID).shortName
        if mainScopeItem.menu != nil { mainScopeItem.submenu = scopeMenu.copy() as? NSMenu }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let menu = NSApp.mainMenu, mainScopeItem.menu == nil else { return }
        mainScopeItem.title = scopeMenu.title
        mainScopeItem.submenu = scopeMenu.copy() as? NSMenu
        menu.addItem(mainScopeItem)
    }

    func windowWillClose(_ notification: Notification) {
        showsZeroServices = false
    }

    func windowDidResignKey(_ notification: Notification) {
        mainScopeItem.menu?.removeItem(mainScopeItem)
    }

    @objc private func showScopeMenu() {
        scopeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopeButton.bounds.height + 4), in: scopeButton)
    }

    @objc private func providerChanged(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectHistory(id)
    }

    @objc private func returnToOverall() { selectHistory("all") }

    private func selectHistory(_ id: String) {
        if providerID == "all", id != "all" { overallLocation = (monthOffset, selectedDay) }
        if id == "all", let location = overallLocation {
            monthOffset = location.month
            selectedDay = location.day
            overallLocation = nil
        }
        providerID = id
        populateProviders()
        refresh()
    }

    @objc private func previousMonth() {
        guard prev.isEnabled else { return }
        monthOffset -= 1
        refresh()
    }

    @objc private func goToToday() {
        monthOffset = 0
        selectedDay = Self.dateFormatter.string(from: Date())
        refresh()
    }

    @objc private func nextMonth() {
        monthOffset = min(0, monthOffset + 1)
        refresh()
    }

    func refreshAppearance() {
        guard let content = window?.contentView else { return }
        ratingPopover?.close()
        Theme.refreshViews(content)
        refresh()
    }

    func refreshForExternalSnapshot() {
        guard isWindowLoaded else { return }
        populateProviders()
        refresh()
    }

    private func refresh() {
        let now = Date()
        guard let monthDate = calendar.date(byAdding: .month, value: monthOffset, to: now) else { return }
        monthLabel.stringValue = "\(calendar.component(.month, from: monthDate))月"
        yearLabel.stringValue = "\(calendar.component(.year, from: monthDate)) 年"

        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate))!
        let range = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<2
        let oldest = calendar.date(byAdding: .day, value: 1 - HistoryStore.retentionDays, to: calendar.startOfDay(for: now))!
        prev.isEnabled = oldest < firstOfMonth
        next.isEnabled = monthOffset < 0
        let ids = providerID == "all" ? visibleIDs : [providerID]
        let entriesByProvider = Dictionary(ids.map { ($0, HistoryStore.shared.entries(provider: $0, now: now)) },
                                           uniquingKeysWith: { first, _ in first })
        let activeDates = Set(entriesByProvider.values.flatMap { $0.filter(\.hasQuotaSpend).map(\.date) })
        let prefix = Self.dateFormatter.string(from: firstOfMonth).prefix(7)
        let activeDays = activeDates.filter { $0.hasPrefix(prefix) }.count
        let streak = Self.currentStreak(activeDates: activeDates, now: now, calendar: calendar)
        activeCount.stringValue = String(activeDays)
        streakCount.stringValue = String(streak)
        currentLabel.stringValue = currentQuotaText()
        statusRow?.isHidden = currentLabel.stringValue.isEmpty
        cardBottom.constant = currentLabel.stringValue.isEmpty ? -14 : -38
        entriesForDay.removeAll(keepingCapacity: true)
        let focusedDay = window?.firstResponder as? HistoryDayCell


        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [HistoryDayCell] = []
        for _ in 0..<leading {
            cells.append(HistoryDayCell(day: nil, level: .unrecorded, tooltip: nil))
        }
        for day in range {
            let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth)!
            let key = Self.dateFormatter.string(from: date)
            var details: [String] = []
            for id in ids {
                guard let entry = entriesByProvider[id]?.first(where: { $0.date == key }) else { continue }
                entriesForDay[key, default: []].append(entry)
                let values = Self.consumptionLines(entry)
                if !values.isEmpty { details.append(ProviderStyles.style(for: id).shortName + " · " + values.joined(separator: " · ")) }
            }
            let dayRecords = entriesForDay[key] ?? []
            let level = UsageLevel.forDay(dayRecords)
            let available = date >= oldest && date <= now
            if let summary = consumptionSummary(dayRecords) { details.insert(summary, at: 0) }
            let tip = key + "\n" + (details.isEmpty ? "当天没有用量记录" : details.joined(separator: "\n"))
            let cell = HistoryDayCell(day: day, level: level, tooltip: available ? tip : nil, isToday: calendar.isDateInToday(date))
            cell.identifier = NSUserInterfaceItemIdentifier(key)
            let accessibleDay = [key, !available ? "不可选" : level.title, calendar.isDateInToday(date) ? "今天" : ""]
            cell.setAccessibilityLabel(accessibleDay.filter { !$0.isEmpty }.joined(separator: "，"))
            cell.setAccessibilityHelp(available ? "选择日期，查看当日明细" : nil)
            cell.isEnabled = available
            cell.alphaValue = available ? 1 : 0.35
            cell.target = self
            cell.action = #selector(showDay(_:))
            cells.append(cell)
        }
        while cells.count % 7 != 0 { cells.append(HistoryDayCell(day: nil, level: .unrecorded, tooltip: nil)) }

        dayButtons = cells.filter(\.isEnabled)
        for (index, cell) in dayButtons.enumerated() {
            cell.onMove = { [weak self] delta in
                guard let self, self.dayButtons.indices.contains(index + delta) else { return }
                let next = self.dayButtons[index + delta]
                self.window?.makeFirstResponder(next)
                self.showDay(next)
            }
        }
        if let initial = dayButtons.first(where: { $0.identifier?.rawValue == selectedDay }) ?? dayButtons.last {
            showDay(initial)
        } else { detailRows.arrangedSubviews.forEach { $0.removeFromSuperview() }; selectedDate.stringValue = ""; weekdayLabel.stringValue = ""; coverageLabel.stringValue = "" }
        calendarStack.replaceDays(cells)
        let revealKey = "\(monthOffset)|\(providerID)|\(selectedDay)"
        if revealKey != lastCalendarRevealKey {
            lastCalendarRevealKey = revealKey
            QuotaMotion.reveal(calendarStack, duration: QuotaMotion.standard, offset: 0)
        }
        if let key = focusedDay?.identifier, let button = dayButtons.first(where: { $0.identifier == key }) { window?.makeFirstResponder(button) }
    }

    private var showsZeroServices = false

    @objc private func showDay(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let date = Self.dateFormatter.date(from: key) else { return }
        let changed = !selectedDay.isEmpty && selectedDay != key
        selectedDay = key
        selectedDate.stringValue = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        selectedDate.identifier = NSUserInterfaceItemIdentifier("selected-history-date")
        weekdayLabel.stringValue = ["星期日","星期一","星期二","星期三","星期四","星期五","星期六"][calendar.component(.weekday, from: date) - 1]
        detailRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let records = entriesForDay[key] ?? []
        coverageLabel.stringValue = consumptionSummary(records) ?? ""
        coverageLabel.isHidden = coverageLabel.stringValue.isEmpty
        coverageLabel.superview?.isHidden = coverageLabel.isHidden && backButton.isHidden
        let displayed = records.filter { !Self.consumptionLines($0).isEmpty }
        if displayed.isEmpty {
            let empty = column([symbol("calendar.badge.clock", color: Theme.secondary, size: 28),
                                label("当天没有用量记录", size: 13, color: Theme.secondary)], spacing: 9)
            empty.alignment = .centerX
            let placeholder = NSView()
            detailRows.addArrangedSubview(placeholder)
            placeholder.addSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                placeholder.widthAnchor.constraint(equalTo: detailRows.widthAnchor),
                placeholder.heightAnchor.constraint(equalToConstant: 156),
                empty.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor)
            ])
        } else {
            let zero = displayed.filter { $0.observedZero }
            let folding = providerID == "all" && !zero.isEmpty
            let visible = folding ? displayed.filter { !$0.observedZero } : displayed
            for (index, entry) in visible.enumerated() {
                if index > 0 { detailRows.addArrangedSubview(separator()) }
                detailRows.addArrangedSubview(serviceRow(entry))
            }
            if folding {
                let opened = showsZeroServices
                let button = ClosureButton(title: (opened ? "收起" : "展开") + "零消耗服务（" + String(zero.count) + "）") { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    self.showsZeroServices.toggle()
                    self.showDay(sender)
                }
                button.alignment = .left
                button.font = .systemFont(ofSize: 13, weight: .medium)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
                detailRows.addArrangedSubview(button)
                if opened { zero.forEach { detailRows.addArrangedSubview(serviceRow($0)) } }
            }
        }
        for item in detailRows.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: detailRows.widthAnchor).isActive = true
        }
        detailRows.enclosingScrollView?.contentView.scroll(to: .zero)
        for day in dayButtons { day.selectedDate = day === sender }
        if changed { QuotaMotion.reveal(detailRows, duration: QuotaMotion.feedback) }
    }

    private func separator() -> NSView {
        let line = ThemedSurfaceView()
        line.wantsLayer = true
        line.surfaceColor = Palette.line
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func serviceRow(_ entry: UsageHistoryEntry) -> NSView {
        let style = ProviderStyles.style(for: entry.provider)
        let mark = ProviderMarkView(provider: entry.provider, size: 23)
        let names = column([label(style.shortName, size: 13, weight: .semibold)], spacing: 3)
        let values = Self.consumptionLines(entry)
        let figures = column(values.enumerated().map { index, value in
            let field = label(value, size: index == 0 ? 13 : 11, weight: index == 0 ? .medium : .regular, color: index == 0 ? Theme.text : Theme.secondary)
            field.font = .monospacedDigitSystemFont(ofSize: index == 0 ? 13 : 11, weight: index == 0 ? .medium : .regular)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingTail
            field.toolTip = value
            return field
        }, spacing: 2)
        figures.alignment = .trailing
        let line = row([mark, names, NSView(), figures], spacing: 8)
        line.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 3)
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        line.toolTip = ([style.shortName] + values).joined(separator: " · ")
        if providerID == "all" {
            let button = ClosureButton(title: "") { [weak self] in self?.selectHistory(entry.provider) }
            button.setAccessibilityLabel("查看 " + style.shortName + " 的历史")
            button.toolTip = line.toolTip
            button.translatesAutoresizingMaskIntoConstraints = false
            line.addSubview(button)
            NSLayoutConstraint.activate([button.topAnchor.constraint(equalTo: line.topAnchor), button.bottomAnchor.constraint(equalTo: line.bottomAnchor), button.leadingAnchor.constraint(equalTo: line.leadingAnchor), button.trailingAnchor.constraint(equalTo: line.trailingAnchor)])
            line.addArrangedSubview(symbol("chevron.right", color: Theme.accent, size: 11))
        }
        return line
    }

    private func currentQuotaText() -> String {
        guard monthOffset == 0, let snapshot = currentSnapshotProvider?() else { return "" }
        if providerID != "all", let p = snapshot.provider(withID: providerID) { return "\(p.name) · \(p.riskDescription)" + (p.cached == true ? "（缓存）" : "") }
        return ""
    }

    static func percentText(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1%" }
        return ((value * 10).rounded(.down) / 10).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    static func displayConsumption(_ amount: Double, unit: String) -> String {
        if unit.hasPrefix("周期：") { return String(unit.dropFirst(3)) + " " + amount.formatted() + "%" }
        if ["CNY", "USD", "EUR", "GBP"].contains(unit) {
            return amount.formatted(.currency(code: unit).locale(Locale(identifier: "zh_CN")))
        }
        return amount.formatted(.number.precision(.fractionLength(0...2))) + " " + unit
    }

    private func consumptionSummary(_ records: [UsageHistoryEntry]) -> String? {
        guard let average = UsageHistoryEntry.averageConsumption(records),
              average > 0 || !records.contains(where: \.hasQuotaSpend) else { return nil }
        let count = records.compactMap(\.consumptionPercent).count
        let label = providerID == "all" ? "\(count) 家平均消耗 " : "消耗 "
        return label + Self.percentText(average)
    }

    static func consumptionLines(_ entry: UsageHistoryEntry) -> [String] {
        let totals = entry.recordedDailyTotals
        let known = totals.filter { $0.key.hasPrefix("周期：") || ["积分", "额度"].contains($0.key) || Locale.commonISOCurrencyCodes.contains($0.key) }
        let positive = known.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        var lines = positive.map { displayConsumption($0.value, unit: $0.key) }
        if lines.isEmpty, entry.observedZero {
            if let unit = entry.balanceUnit, known[unit] != nil { return [displayConsumption(0, unit: unit)] }
            if known.keys.contains(where: { $0.hasPrefix("周期：") }) { return ["0%"] }
            if let unit = known.keys.sorted().first { return [displayConsumption(0, unit: unit)] }
        }
        if let cost = entry.cost, cost > 0, let unit = entry.costCurrency {
            lines.append("花费 " + displayConsumption(cost, unit: unit))
        }
        if let resets = entry.windowResets {
            for (window, count) in resets.sorted(by: { $0.key < $1.key }) where count > 0 {
                lines.append(window + "重置 " + String(count) + " 次")
            }
        }
        return lines.isEmpty && entry.hasQuotaSpend ? ["已使用"] : lines
    }

    static func currentStreak(activeDates: Set<String>, now: Date, calendar: Calendar = .current) -> Int {
        let active = activeDates
        var day = now
        var count = 0
        while true {
            let key = Self.dateFormatter.string(from: day)
            guard active.contains(key) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

private enum Palette {
    static let paper = Theme.background
    static let calendar = Theme.surfaceAlt
    static let line = Theme.separator
    static let forest = Theme.forest
    static let mint = Theme.mint
    static let selection = Theme.accent
}

private final class LedgerStack: NSStackView {
    override var isFlipped: Bool { true }
}

enum UsageLevel {
    case unrecorded, spent, none, light, medium, dark
    static let grades: [Self] = [.none, .light, .medium, .dark]

    static func forDay(_ records: [UsageHistoryEntry]) -> Self {
        if let ratio = UsageHistoryEntry.averageConsumption(records), ratio > 0 {
            return ratio >= 30 ? .dark : ratio >= 10 ? .medium : .light
        }
        if records.contains(where: \.hasQuotaSpend) { return .spent }
        return records.contains { $0.consumptionPercent == 0 || $0.observedZero } ? .none : .unrecorded
    }

    var title: String {
        switch self {
        case .unrecorded: return ""
        case .spent: return "已使用"
        case .none: return "未使用"
        case .light: return "轻轻路过"
        case .medium: return "持续输出"
        case .dark: return "卷王模式"
        }
    }

    var rangeText: String {
        switch self {
        case .none: return "0%"
        case .light: return "大于 0%，不足 10%"
        case .medium: return "10% 至不足 30%"
        case .dark: return "30% 及以上"
        case .spent, .unrecorded: return ""
        }
    }

    var fill: NSColor {
        switch self {
        case .unrecorded: return .clear
        case .none: return Theme.heatIdle
        case .spent, .light: return Theme.heatLight
        case .medium: return Theme.heatMedium
        case .dark: return Theme.heatHigh
        }
    }
}

private final class SpendHatch: NSView {
    static func cover(_ parent: NSView) {
        let hatch = SpendHatch(frame: parent.bounds)
        hatch.autoresizingMask = [.width, .height]
        hatch.setAccessibilityElement(false)
        parent.addSubview(hatch)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let stripes = NSBezierPath()
        for x in stride(from: -bounds.height, to: bounds.width, by: 7) {
            stripes.move(to: NSPoint(x: x, y: 0))
            stripes.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
        }
        Theme.accent.withAlphaComponent(0.25).setStroke()
        stripes.stroke()
    }
}

private final class MonthGrid: NSView {
    private var days: [NSButton] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(days.count / 7) * 38 - (days.isEmpty ? 0 : 5))
    }

    func replaceDays(_ cells: [NSButton]) {
        days.forEach { $0.removeFromSuperview() }
        days = cells
        for cell in cells {
            cell.translatesAutoresizingMaskIntoConstraints = true
            addSubview(cell)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, (bounds.width - 30) / 7)
        for (index, cell) in days.enumerated() {
            cell.frame = NSRect(x: CGFloat(index % 7) * (width + 5), y: CGFloat(index / 7) * 38, width: width, height: 33)
        }
    }
}

private final class HistoryDayCell: NSButton {
    var onMove: ((Int) -> Void)?
    var selectedDate = false { didSet { applyStyle(); setAccessibilitySelected(selectedDate) } }
    private let number = NSTextField(labelWithString: "")
    private let todayMark = ThemedSurfaceView()
    private let level: UsageLevel
    init(day: Int?, level: UsageLevel, tooltip: String?, isToday: Bool = false) {
        self.level = level
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        toolTip = tooltip
        setAccessibilityLabel(tooltip ?? day.map(String.init) ?? "")
        setAccessibilityElement(day != nil)
        isEnabled = day != nil
        if level == .spent { layer?.masksToBounds = true; SpendHatch.cover(self) }
        if let day {
            number.stringValue = String(day)
            number.alignment = .center
            number.setAccessibilityElement(false)
            number.translatesAutoresizingMaskIntoConstraints = false
            addSubview(number)
            number.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            number.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        if isToday {
            todayMark.wantsLayer = true
            todayMark.layer?.cornerRadius = 2
            todayMark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(todayMark)
            NSLayoutConstraint.activate([todayMark.centerXAnchor.constraint(equalTo: centerXAnchor),
                todayMark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                todayMark.widthAnchor.constraint(equalToConstant: 4), todayMark.heightAnchor.constraint(equalToConstant: 4)])
        }
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyStyle() }
    override var acceptsFirstResponder: Bool { isEnabled && !number.stringValue.isEmpty }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 7
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func keyDown(with event: NSEvent) {
        if let delta = [123: -1, 124: 1, 125: 7, 126: -7][Int(event.keyCode)], let onMove { onMove(delta) }
        else { super.keyDown(with: event) }
    }
    private func applyStyle() {
        layer?.cornerRadius = Theme.design == .claude ? 3 : (Theme.design == .glass ? 14 : 7)
        layer?.backgroundColor = level.fill.resolvedCGColor()
        let outline: NSColor = selectedDate ? (level == .dark ? Palette.mint : Palette.selection) : Palette.line
        layer?.borderColor = outline.resolvedCGColor()
        layer?.borderWidth = selectedDate ? 2.5 : (level == .none ? 0.7 : 0)
        number.font = .monospacedDigitSystemFont(ofSize: 14, weight: selectedDate || (level != .unrecorded && level != .none) ? .semibold : .regular)
        let strongFillText = Theme.dynamic(.white, Theme.hex(0x102921))
        number.textColor = level == .dark ? strongFillText : Theme.text
        todayMark.surfaceColor = level == .dark ? strongFillText : Theme.accent
    }
}
