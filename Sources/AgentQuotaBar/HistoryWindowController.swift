import AppKit

/// 独立的用量历史窗口：按月展示每天的使用强度。
/// 颜色只用一个绿色色相，用深浅表达级别，避免把不同 provider 的额度单位硬凑在一起。
final class HistoryWindowController: NSWindowController {
    private let providerPopup = NSPopUpButton()
    private let monthLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let calendarStack = NSStackView()
    private let legendRow = NSStackView()
    private var providerID: String
    private var monthOffset = 0
    private var calendar: Calendar
    var currentSnapshotProvider: (() -> QuotaSnapshot?)?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    init(providerID: String = "all") {
        self.providerID = providerID
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一开头
        self.calendar = cal

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "用量历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = buildContent()
        populateProviders()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        let root = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 580))
        root.wantsLayer = true
        root.surfaceColor = Theme.background

        let title = label("用量历史", size: 20, weight: .semibold)
        let subtitle = label("按当天消耗强度着色；未使用只保留日期。", size: 11, color: Theme.tertiary)

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        providerPopup.font = .systemFont(ofSize: 12)
        providerPopup.bezelStyle = .rounded
        providerPopup.controlSize = .large
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.focusRingType = .none
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上个月")!,
                            target: self, action: #selector(previousMonth))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下个月")!,
                            target: self, action: #selector(nextMonth))
        for button in [prev, next] {
            button.isBordered = false
            button.contentTintColor = Theme.secondary
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        monthLabel.font = .systemFont(ofSize: 13, weight: .medium)
        monthLabel.textColor = Theme.secondary
        monthLabel.alignment = .right

        let header = NSStackView(views: [titles, NSView(), providerPopup, monthLabel, prev, next])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = Theme.secondary
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(summaryLabel)

        currentLabel.font = .systemFont(ofSize: 11)
        currentLabel.textColor = Theme.secondary
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(currentLabel)

        let weekdayRow = NSStackView()
        weekdayRow.orientation = .horizontal
        weekdayRow.alignment = .centerY
        weekdayRow.distribution = .fillEqually
        weekdayRow.spacing = 6
        for day in ["一", "二", "三", "四", "五", "六", "日"] {
            let l = label(day, size: 10, weight: .medium, color: Theme.tertiary)
            l.alignment = .center
            weekdayRow.addArrangedSubview(l)
        }
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(weekdayRow)

        calendarStack.orientation = .vertical
        calendarStack.alignment = .width
        calendarStack.spacing = 6
        calendarStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(calendarStack)

        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        legendRow.spacing = 8
        legendRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(legendRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            summaryLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            summaryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            currentLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            currentLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            currentLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            weekdayRow.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 10),
            weekdayRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            weekdayRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            calendarStack.topAnchor.constraint(equalTo: weekdayRow.bottomAnchor, constant: 6),
            calendarStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            calendarStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            legendRow.topAnchor.constraint(equalTo: calendarStack.bottomAnchor, constant: 14),
            legendRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            legendRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),
            legendRow.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
        ])
        buildLegend()
        return root
    }

    private func buildLegend() {
        legendRow.arrangedSubviews.forEach { legendRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        let items: [(String, UsageLevel)] = [
            ("未使用", .none), ("轻轻路过", .light), ("持续输出", .medium), ("卷王模式", .dark),
        ]
        for (title, level) in items {
            let swatch = HistoryDayCell.swatch(for: level)
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 14).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let text = label(title, size: 10, color: Theme.tertiary)
            legendRow.addArrangedSubview(swatch)
            legendRow.addArrangedSubview(text)
        }
    }

    private func populateProviders() {
        providerPopup.removeAllItems()
        providerPopup.addItem(withTitle: "整体")
        providerPopup.lastItem?.representedObject = "all"
        for id in ProviderRegistry.ids {
            let style = ProviderStyles.style(for: id)
            providerPopup.addItem(withTitle: style.shortName)
            providerPopup.lastItem?.representedObject = id
        }
        let ids = ["all"] + ProviderRegistry.ids
        if let index = ids.firstIndex(of: providerID) {
            providerPopup.selectItem(at: index)
        } else {
            providerID = "all"
            providerPopup.selectItem(at: 0)
        }
    }

    @objc private func providerChanged() {
        if let id = providerPopup.selectedItem?.representedObject as? String {
            providerID = id
            refresh()
        }
    }

    @objc private func previousMonth() {
        monthOffset -= 1
        refresh()
    }

    @objc private func nextMonth() {
        monthOffset = min(0, monthOffset + 1)
        refresh()
    }

    func refreshForExternalSnapshot() {
        guard isWindowLoaded else { return }
        refresh()
    }

    private func refresh() {
        let now = Date()
        guard let monthDate = calendar.date(byAdding: .month, value: monthOffset, to: now) else { return }
        monthLabel.stringValue = Self.monthFormatter.string(from: monthDate)
        monthLabel.textColor = Theme.secondary

        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate))!
        let range = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<2
        let monthPrefix = Self.monthFormatter.string(from: monthDate)
        let monthEntries = HistoryStore.shared.entries(provider: providerID == "all" ? "codex" : providerID,
                                                       days: 62, now: now)
        let ids = providerID == "all" ? ProviderRegistry.ids : [providerID]
        var entriesByProvider: [String: [UsageHistoryEntry]] = [:]
        var maxByProvider: [String: Double] = [:]
        for id in ids {
            let list = providerID == "all"
                ? HistoryStore.shared.entries(provider: id, days: 62, now: now)
                : monthEntries
            let monthList = list.filter { $0.date.hasPrefix(Self.dateFormatter.string(from: firstOfMonth).prefix(7)) }
            entriesByProvider[id] = monthList
            maxByProvider[id] = max(1, monthList.map { score(for: $0) }.max() ?? 0)
        }

        let allDates = Set(entriesByProvider.values.flatMap { $0.map(\.date) })
        let activeDays = allDates.filter { date in
            entriesByProvider.values.contains { list in
                list.contains { $0.date == date && score(for: $0) > 0 }
            }
        }.count
        let streak = currentStreak(activeDates: allDates.filter { date in
            entriesByProvider.values.contains { list in
                list.contains { $0.date == date && score(for: $0) > 0 }
            }
        }, now: now)
        let providerName = providerID == "all" ? "全部 Agent" : ProviderStyles.style(for: providerID).shortName
        summaryLabel.stringValue = "\(providerName) · 活跃 \(activeDays) 天 · 连续使用 \(streak) 天"
        summaryLabel.textColor = Theme.secondary
        currentLabel.stringValue = currentQuotaText()
        currentLabel.isHidden = currentLabel.stringValue.isEmpty

        calendarStack.arrangedSubviews.forEach { calendarStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [HistoryDayCell] = []
        for _ in 0..<leading {
            cells.append(HistoryDayCell(day: nil, level: .none, tooltip: nil))
        }
        for day in range {
            let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth)!
            let key = Self.dateFormatter.string(from: date)
            var level: UsageLevel = .none
            var activeNames: [String] = []
            var detail: String?
            for id in ids {
                guard let entry = entriesByProvider[id]?.first(where: { $0.date == key }) else { continue }
                let raw = score(for: entry)
                guard raw > 0 else { continue }
                activeNames.append(ProviderStyles.style(for: id).shortName)
                if detail == nil { detail = detailText(for: entry) }
                let ratio = raw / maxByProvider[id, default: 1]
                let itemLevel: UsageLevel = ratio < 0.34 ? .light : (ratio < 0.67 ? .medium : .dark)
                if itemLevel.rank > level.rank { level = itemLevel }
            }
            if activeNames.count >= 2 { level = level.bumped }
            let nameText = activeNames.prefix(3).joined(separator: "、")
            let tip: String? = activeNames.isEmpty
                ? nil
                : "\(key) · \(level.title) · \(nameText)\(detail.map { " · \($0)" } ?? "")"
            cells.append(HistoryDayCell(day: day, level: level, tooltip: tip, isToday: calendar.isDateInToday(date)))
        }
        while cells.count % 7 != 0 { cells.append(HistoryDayCell(day: nil, level: .none, tooltip: nil)) }

        for rowStart in stride(from: 0, to: cells.count, by: 7) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 6
            for cell in cells[rowStart..<min(rowStart + 7, cells.count)] {
                row.addArrangedSubview(cell)
                cell.heightAnchor.constraint(equalToConstant: 52).isActive = true
            }
            calendarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: calendarStack.widthAnchor).isActive = true
        }
    }

    private func currentQuotaText() -> String {
        guard let snapshot = currentSnapshotProvider?() else { return "" }
        let percent = snapshot.providers.compactMap { provider -> (ProviderStatus, QuotaMetric)? in
            guard provider.status != "disabled", let metric = provider.metrics.first(where: { $0.kind == "percent" }) else { return nil }
            return (provider, metric)
        }
        if let (provider, metric) = percent.min(by: { ($0.1.remainingPercent ?? 100) < ($1.1.remainingPercent ?? 100) }) {
            let remaining = Int((metric.remainingPercent ?? 0).rounded())
            let reset = metric.resetAt.flatMap { raw -> String? in
                let date = Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
                let interval = date.timeIntervalSinceNow
                guard interval > 0 else { return nil }
                if interval >= 86_400 { return "\(Int(interval / 86_400)) 天后重置" }
                if interval >= 3_600 { return "\(Int(interval / 3_600)) 小时后重置" }
                return "\(Int(interval / 60)) 分钟后重置"
            }
            return "当前最紧张：\(ProviderStyles.style(for: provider.id).shortName) \(remaining)%\(reset.map { " · \($0)" } ?? "")"
        }
        if let provider = snapshot.providers.first(where: { $0.balance != nil }) {
            return "当前余额：\(ProviderStyles.style(for: provider.id).shortName) \(provider.displayPrimaryValue)"
        }
        return ""
    }

    private func score(for entry: UsageHistoryEntry) -> Double {
        if let cost = entry.cost, cost > 0 { return cost }
        if let consumed = entry.consumed, consumed > 0 { return consumed }
        if let tokens = entry.tokens?.total, tokens > 0 { return Double(tokens) }
        if let used = entry.usedPercent, used > 0 { return used }
        return 0
    }

    private func detailText(for entry: UsageHistoryEntry) -> String {
        if let cost = entry.cost, cost > 0 { return String(format: "花费 ¥%.2f", cost) }
        if let consumed = entry.consumed, consumed > 0 { return "消耗 \(Int(consumed.rounded()))" }
        if let tokens = entry.tokens?.total, tokens > 0 { return "\(tokens) tokens" }
        if let used = entry.usedPercent { return "已用 \(Int(used.rounded()))%" }
        return "有记录"
    }

    private func currentStreak(activeDates: Set<String>, now: Date) -> Int {
        let active = activeDates
        var day = now
        if !active.contains(Self.dateFormatter.string(from: day)),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
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

private enum UsageLevel {
    case none, light, medium, dark
    var rank: Int {
        switch self { case .none: return 0; case .light: return 1; case .medium: return 2; case .dark: return 3 }
    }
    var bumped: UsageLevel {
        switch self { case .none, .light: return .medium; case .medium: return .dark; case .dark: return .dark }
    }
    var title: String {
        switch self {
        case .none: return "未使用"
        case .light: return "轻轻路过"
        case .medium: return "持续输出"
        case .dark: return "卷王模式"
        }
    }
}

private final class HistoryDayCell: NSView {
    private let level: UsageLevel
    private let tooltip: String?

    init(day: Int?, level: UsageLevel, tooltip: String?, isToday: Bool = false) {
        self.level = level
        self.tooltip = tooltip
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 9
        if let day, level == .none {
            // 未使用：不填绿色，只保留一个很轻的日期卡片边界。
            layer?.backgroundColor = Theme.surface.withAlphaComponent(0.55).resolvedForAppearance().cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = Theme.separator.withAlphaComponent(0.22).resolvedForAppearance().cgColor
        } else if day == nil {
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            layer?.backgroundColor = Self.background(for: level).cgColor
        }
        toolTip = tooltip
        if isToday {
            layer?.borderWidth = 1
            layer?.borderColor = Theme.accent.resolvedForAppearance().cgColor
        }
        if let day {
            let text = label("\(day)", size: 11, weight: level == .dark ? .semibold : .regular,
                             color: level == .dark ? .white : Theme.secondary)
            text.alignment = .center
            text.translatesAutoresizingMaskIntoConstraints = false
            addSubview(text)
            NSLayoutConstraint.activate([
                text.centerXAnchor.constraint(equalTo: centerXAnchor),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func background(for level: UsageLevel) -> NSColor {
        switch level {
        case .none: return Theme.surfaceAlt
        case .light: return Theme.success.withAlphaComponent(0.26)
        case .medium: return Theme.success.withAlphaComponent(0.46)
        case .dark: return Theme.success.withAlphaComponent(0.82)
        }
    }

    static func swatch(for level: UsageLevel) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        if level == .none {
            v.layer?.backgroundColor = Theme.surface.withAlphaComponent(0.55).resolvedForAppearance().cgColor
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = Theme.separator.withAlphaComponent(0.28).resolvedForAppearance().cgColor
        } else {
            v.layer?.backgroundColor = background(for: level).cgColor
        }
        return v
    }
}
