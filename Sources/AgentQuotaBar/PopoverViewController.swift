import AppKit

// MARK: - 弹出面板

final class ThemedRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class QuotaPopoverViewController: NSViewController {
    private let service: QuotaService
    var onConfigure: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCheckin: (() -> Void)?
    var onToggleAppearance: (() -> Void)?
    var onReorder: (([String]) -> Void)?

    private let root = ThemedRootView()
    private let titleLabel = NSTextField(labelWithString: "Agent 额度")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let summaryCard = NSView()
    private let headerActions = NSStackView()
    private let themeButton = HeaderIconButton(symbol: "moon")
    private let checkinButton = HeaderIconButton(symbol: "checkmark.circle")
    private var summaryService = NSTextField(labelWithString: "—")
    private var summaryLowest = NSTextField(labelWithString: "—")
    private var summaryCheckin = NSTextField(labelWithString: "待签")
    private var checkinDone = false
    private var checkinDetailText = ""
    private var checkinRunning = false
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: String?
    private var lastRefreshing = false
    private var lastOffline = false
    private let spinner = NSProgressIndicator()
    private var draggingRow: ProviderRowView?

    init(service: QuotaService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        root.onAppearanceChange = { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.refreshAppearance()
        }
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.resolvedCGColor()
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 520)

        titleLabel.stringValue = "额度概览"
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.resolvedForAppearance()

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.tertiary
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true

        themeButton.target = self
        themeButton.action = #selector(themeTapped)
        themeButton.toolTip = "切换明暗"

        checkinButton.target = self
        checkinButton.action = #selector(checkinTapped)
        checkinButton.toolTip = "一键签到 Trae + WorkBuddy"
        checkinButton.setAccessibilityLabel("一键签到 Trae 和 WorkBuddy")

        let refresh = iconButton("arrow.clockwise", tooltip: "立即刷新", action: #selector(refreshTapped))
        let gear = iconButton("gearshape", tooltip: "设置", action: #selector(settingsTapped))

        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 3
        headerActions.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        headerActions.wantsLayer = true
        headerActions.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        headerActions.layer?.cornerRadius = 10
        headerActions.layer?.cornerCurve = .continuous
        headerActions.layer?.borderWidth = 1
        headerActions.layer?.borderColor = Theme.separator.resolvedCGColor()
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        for button in [checkinButton, themeButton, refresh, gear] { headerActions.addArrangedSubview(button) }

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let header = NSStackView(views: [titles, headerSpacer, spinner, headerActions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        summaryService = label("—", size: 14, weight: .semibold, color: .labelColor, monospaced: true)
        summaryLowest = label("—", size: 14, weight: .semibold, color: .labelColor, monospaced: true)
        summaryCheckin = label("待签", size: 14, weight: .semibold, color: .labelColor)

        let stats = NSStackView(views: [
            summaryStat("服务", value: summaryService),
            summaryStat("最低额度", value: summaryLowest),
            summaryStat("签到", value: summaryCheckin),
        ])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.alignment = .centerY
        stats.spacing = 0
        stats.translatesAutoresizingMaskIntoConstraints = false

        summaryCard.wantsLayer = true
        summaryCard.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        summaryCard.layer?.cornerRadius = 10
        summaryCard.layer?.cornerCurve = .continuous
        summaryCard.layer?.borderWidth = 1
        summaryCard.layer?.borderColor = Theme.separator.resolvedCGColor()
        headerActions.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        headerActions.layer?.borderColor = Theme.separator.resolvedCGColor()
        summaryCard.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.addSubview(stats)
        NSLayoutConstraint.activate([
            stats.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 8),
            stats.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: -8),
            stats.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 12),
            stats.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -12),
        ])

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = Theme.tertiary
        footerLabel.lineBreakMode = .byTruncatingTail

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let quit = NSButton(title: "退出", target: self, action: #selector(quitTapped))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 10)
        quit.contentTintColor = Theme.tertiary

        let footer = NSStackView(views: [footerLabel, footerSpacer, quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(summaryCard)
        root.addSubview(rowsStack)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            summaryCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            summaryCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            summaryCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            rowsStack.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 10),
            rowsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            rowsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            footer.topAnchor.constraint(greaterThanOrEqualTo: rowsStack.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        view = root
        preferredContentSize = NSSize(width: 380, height: 520)
        refreshAppearance()
    }

    private func applyAppearanceRecursively(to node: NSView) {
        if let label = node as? ThemedLabel {
            label.applyRole(label.roleColor)
            label.needsDisplay = true
        } else if let logo = node as? LogoBadgeView {
            logo.refreshInk()
            logo.needsDisplay = true
        }
        node.needsDisplay = true
        node.layer?.setNeedsDisplay()
        node.subviews.forEach { applyAppearanceRecursively(to: $0) }
    }

    private func setThemedColor(_ field: NSTextField, _ color: NSColor) {
        if let themed = field as? ThemedLabel {
            themed.applyRole(color)
        } else {
            field.textColor = color.resolvedForAppearance()
        }
    }

    private func summaryStat(_ title: String, value: NSTextField) -> NSView {
        let titleLabel = label(title, size: 10, weight: .medium, color: Theme.tertiary)
        titleLabel.alignment = .center
        value.alignment = .center
        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        return stack
    }

    private func summaryDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.separator.resolvedCGColor()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return line
    }

    func refreshAppearance() {
        if let target = NSApp.appearance {
            if view.window?.appearance?.name != target.name {
                view.window?.appearance = target
            }
        } else if view.window?.appearance != nil {
            view.window?.appearance = nil
        }
        if let snapshot = lastSnapshot {
            update(
                snapshot: snapshot,
                error: lastError,
                isRefreshing: lastRefreshing,
                isOffline: lastOffline
            )
        }
        applyAppearanceRecursively(to: view)
        root.layer?.backgroundColor = Theme.background.resolvedCGColor()
        summaryCard.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        summaryCard.layer?.borderColor = Theme.separator.resolvedCGColor()
        headerActions.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        headerActions.layer?.borderColor = Theme.separator.resolvedCGColor()
        titleLabel.textColor = .labelColor.resolvedForAppearance()
        subtitleLabel.textColor = Theme.tertiary.resolvedForAppearance()
        footerLabel.textColor = Theme.tertiary.resolvedForAppearance()
        let dark = Theme.currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        themeButton.symbolName = dark ? "sun.max" : "moon"
        view.needsDisplay = true
    }

    func updateCheckin(status: String, detail: String, done: Bool, running: Bool) {
        checkinDone = done
        checkinDetailText = detail
        checkinRunning = running
        // 两个都签完就自动隐藏；运行中保留但禁用，避免重复点击。
        checkinButton.isHidden = done
        checkinButton.isEnabled = !running
        summaryCheckin.stringValue = done ? "已签" : (running ? "签到中" : "待签")
        setThemedColor(summaryCheckin, done ? QuotaStyle.healthyColor : .labelColor)
        if let snapshot = lastSnapshot {
            update(
                snapshot: snapshot,
                error: lastError,
                isRefreshing: lastRefreshing,
                isOffline: lastOffline
            )
        }
    }

    @objc private func checkinTapped() {
        onCheckin?()
    }

    @objc private func themeTapped() {
        onToggleAppearance?()
    }

    func update(snapshot: QuotaSnapshot?, error: String?, isRefreshing: Bool, isOffline: Bool = false) {
        lastSnapshot = snapshot
        lastError = error
        lastRefreshing = isRefreshing
        lastOffline = isOffline
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        guard let snapshot else {
            subtitleLabel.stringValue = isOffline
                ? "网络未连接"
                : (error == nil ? "正在查询…" : "查询失败")
            if isOffline {
                addOfflineBanner()
            } else if let error {
                let label = wrappingLabel(error, size: 11, color: Theme.secondary, width: 310)
                rowsStack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
            summaryService.stringValue = "—"
            summaryLowest.stringValue = "—"
            summaryCheckin.stringValue = checkinDone ? "已签" : "待签"
            setThemedColor(summaryCheckin, checkinDone ? QuotaStyle.healthyColor : .labelColor)
            if isOffline {
                footerLabel.stringValue = "⚠︎ 网络未连接，联网后自动刷新"
                footerLabel.textColor = .systemOrange
            } else {
                footerLabel.stringValue = isRefreshing ? "正在查询…" : "尚未刷新"
                footerLabel.textColor = Theme.tertiary
            }
            updatePreferredSize()
            return
        }

        if isOffline { addOfflineBanner() }
        let ordered = orderedProviders(snapshot)
        for (index, provider) in ordered.enumerated() {
            let row = ProviderRowView(
                provider: provider,
                checkinDone: checkinDone,
                checkinStreak: service.config.int("checkin.workbuddyStreak", default: 0),
                onConfigure: { [weak self] in
                    self?.onConfigure?(provider.id)
                },
                onCheckin: { [weak self] in
                    self?.onCheckin?()
                }
            )
            row.showsSeparator = index < ordered.count - 1
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleRowPan(_:)))
            row.addGestureRecognizer(pan)
        }

        subtitleLabel.stringValue = isOffline
            ? "网络未连接 · 显示 \(timeText(snapshot.updatedDate)) 的数据"
            : "\(snapshot.usableCount)/\(snapshot.enabledCount) 个服务 · \(timeText(snapshot.updatedDate))"

        let percents = snapshot.providers.compactMap { provider in
            provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent
        }
        summaryService.stringValue = "\(snapshot.usableCount)/\(snapshot.enabledCount)"
        setThemedColor(summaryService, .labelColor)
        if let lowest = percents.min() {
            summaryLowest.stringValue = "\(Int(lowest.rounded()))%"
            setThemedColor(
                summaryLowest,
                lowest <= 45 ? QuotaSeverity.from(remaining: lowest).color : .labelColor
            )
        } else {
            summaryLowest.stringValue = "—"
            setThemedColor(summaryLowest, .labelColor)
        }
        summaryCheckin.stringValue = checkinDone ? "已签" : (checkinRunning ? "签到中" : "待签")
        setThemedColor(summaryCheckin, checkinDone ? QuotaStyle.healthyColor : .labelColor)

        if isOffline {
            footerLabel.stringValue = "⚠︎ 网络未连接，联网后自动刷新"
            footerLabel.textColor = .systemOrange
        } else if let error {
            footerLabel.stringValue = "⚠︎ " + error
            footerLabel.textColor = .systemOrange
        } else {
            footerLabel.stringValue = "更新于 \(timeText(snapshot.updatedDate))"
            footerLabel.textColor = Theme.tertiary
        }

        updatePreferredSize()
    }

    private func orderedProviders(_ snapshot: QuotaSnapshot) -> [ProviderStatus] {
        let stored = service.config.stringArray("providerOrder")
        let defaultOrder = ["codex", "deepseek", "opencode", "trae", "workbuddy"]
        let order = stored.isEmpty ? defaultOrder : stored
        var result: [ProviderStatus] = []
        for id in order {
            if let provider = snapshot.providers.first(where: { $0.id == id }), provider.status != "disabled" {
                result.append(provider)
            }
        }
        for provider in snapshot.providers where provider.status != "disabled" && !result.contains(where: { $0.id == provider.id }) {
            result.append(provider)
        }
        return result
    }

    private func addOfflineBanner() {
        let banner = wrappingLabel(
            "网络未连接，显示上次数据，联网后自动刷新",
            size: 11,
            color: .systemOrange,
            width: 310
        )
        rowsStack.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func updatePreferredSize() {
        view.layoutSubtreeIfNeeded()
        let rowsHeight = rowsStack.fittingSize.height
        let height = min(840, max(180, rowsHeight + 150))
        preferredContentSize = NSSize(width: 380, height: height)
        view.setFrameSize(preferredContentSize)
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = HeaderIconButton(symbol: symbol)
        button.target = self
        button.action = action
        button.toolTip = tooltip
        return button
    }

    // MARK: 拖动排序

    @objc private func handleRowPan(_ recognizer: NSPanGestureRecognizer) {
        guard let row = recognizer.view as? ProviderRowView else { return }
        switch recognizer.state {
        case .began:
            draggingRow = row
            row.setDragging(true)
        case .changed:
            reorderIfNeeded(row: row, location: recognizer.location(in: rowsStack))
        case .ended, .cancelled, .failed:
            row.setDragging(false)
            draggingRow = nil
            let order = rowsStack.arrangedSubviews.compactMap { ($0 as? ProviderRowView)?.providerID }
            if !order.isEmpty { onReorder?(order) }
            updatePreferredSize()
        default:
            break
        }
    }

    private func reorderIfNeeded(row: ProviderRowView, location: NSPoint) {
        let height = rowsStack.bounds.height
        let y = rowsStack.isFlipped ? location.y : height - location.y
        let others = rowsStack.arrangedSubviews.compactMap { $0 as? ProviderRowView }.filter { $0 !== row }
        let target = others.filter { other in
            let mid = rowsStack.isFlipped ? other.frame.midY : height - other.frame.midY
            return mid < y
        }.count
        guard let current = rowsStack.arrangedSubviews.firstIndex(of: row), target != current else { return }
        rowsStack.removeArrangedSubview(row)
        rowsStack.insertArrangedSubview(row, at: min(target, rowsStack.arrangedSubviews.count))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            rowsStack.layoutSubtreeIfNeeded()
        }
    }

    @objc private func refreshTapped() { service.refresh() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func quitTapped() { NSApplication.shared.terminate(nil) }
}

// MARK: - 单行

final class ProviderRowView: NSView {
    let providerID: String
    private let provider: ProviderStatus
    private let checkinDone: Bool
    private let checkinStreak: Int
    private let onConfigure: () -> Void
    private let onCheckin: () -> Void
    private var hovered = false
    private var dragging = false
    private let separator = NSView()
    private var trackingAreaRef: NSTrackingArea?

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(
        provider: ProviderStatus,
        checkinDone: Bool,
        checkinStreak: Int,
        onConfigure: @escaping () -> Void,
        onCheckin: @escaping () -> Void
    ) {
        self.providerID = provider.id
        self.provider = provider
        self.checkinDone = checkinDone
        self.checkinStreak = checkinStreak
        self.onConfigure = onConfigure
        self.onCheckin = onCheckin
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let style = ProviderStyles.style(for: provider.id)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let badge = LogoBadgeView(provider: provider.id, color: style.color, size: 22)

        let name = label(style.shortName, size: 14, weight: .semibold)
        let nameRow = NSStackView(views: [name])
        nameRow.orientation = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .centerY
        if let plan = provider.plan, !plan.isEmpty {
            nameRow.addArrangedSubview(label(plan, size: 10, color: Theme.tertiary))
        }
        if provider.status == "warn" && isExhausted(provider) {
            nameRow.addArrangedSubview(label("已用尽", size: 10, weight: .medium, color: .systemRed))
        }
        if provider.status == "error" {
            nameRow.addArrangedSubview(label("出错", size: 10, weight: .medium, color: .systemRed))
        }
        if provider.status == "unconfigured" {
            nameRow.addArrangedSubview(label("待配置", size: 10, weight: .medium, color: .systemOrange))
        }

        let sub = label(subtitle(for: provider), size: 12, color: Theme.tertiary)
        let info = NSStackView(views: [nameRow, sub])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let value = label(valueText(provider), size: 20, weight: .semibold, color: valueColor(provider), monospaced: true)
        value.alignment = .right
        let caption = label(valueCaption(provider), size: 10, color: Theme.tertiary)
        caption.alignment = .right
        let valueStack = NSStackView(views: [value, caption])
        valueStack.orientation = .vertical
        valueStack.alignment = .trailing
        valueStack.spacing = 0

        let header = NSStackView(views: [badge, info, spacer, valueStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let percentMetrics = provider.metrics.filter { $0.kind == "percent" }
        for metric in percentMetrics.prefix(3) {
            let remaining = metric.remainingPercent ?? 0
            let severity = QuotaSeverity.from(remaining: remaining)

            let meta = NSStackView()
            meta.orientation = .horizontal
            meta.spacing = 8
            meta.alignment = .centerY
            meta.addArrangedSubview(label(metric.label, size: 12, weight: .medium, color: Theme.secondary))
            let metaSpacer = NSView()
            metaSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            meta.addArrangedSubview(metaSpacer)
            if let detail = metric.detail, !detail.isEmpty {
                meta.addArrangedSubview(label(detail, size: 10, color: Theme.tertiary))
            }
            meta.addArrangedSubview(label(
                "剩 \(Int(remaining.rounded()))%",
                size: 12,
                weight: .semibold,
                color: remaining <= QuotaStyle.warningPercent ? severity.color : Theme.secondary
            ))
            stack.addArrangedSubview(meta)
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            let barColor = remaining <= QuotaStyle.warningPercent ? severity.color : QuotaStyle.healthyColor
            let bar = BarView(progress: remaining / 100, color: barColor)
            bar.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(bar)
            bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if provider.id == "trae" || provider.id == "workbuddy" {
            var detail = "每日 +100 积分"
            if provider.id == "workbuddy" && checkinStreak > 0 {
                detail += " · 连续 \(checkinStreak) 天"
            }
            let checkinRow = NSStackView()
            checkinRow.orientation = .horizontal
            checkinRow.alignment = .centerY
            checkinRow.spacing = 8
            checkinRow.addArrangedSubview(label(detail, size: 10, color: Theme.tertiary))
            let checkinSpacer = NSView()
            checkinSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            checkinRow.addArrangedSubview(checkinSpacer)
            if checkinDone {
                checkinRow.addArrangedSubview(label("✓ 今日已签", size: 10, weight: .medium, color: QuotaStyle.healthyColor))
            } else {
                let button = NSButton(title: "签到", target: self, action: #selector(checkinTapped))
                button.isBordered = false
                button.bezelStyle = .inline
                button.font = .systemFont(ofSize: 10, weight: .medium)
                button.contentTintColor = Theme.accent
                checkinRow.addArrangedSubview(button)
            }
            stack.addArrangedSubview(checkinRow)
            checkinRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if let supporting = provider.metrics.first(where: { $0.kind == "credit" })?.detail
                    ?? provider.metrics.first(where: { $0.kind == "text" })?.detail,
                  !supporting.isEmpty {
            let detailLabel = label(supporting, size: 10, color: Theme.tertiary)
            detailLabel.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if provider.status == "unconfigured" || provider.status == "error" {
            let actionRow = NSStackView()
            actionRow.orientation = .horizontal
            actionRow.alignment = .top
            actionRow.spacing = 8

            let message = provider.status == "error"
                ? errorHint(for: provider)
                : (provider.error ?? provider.detail ?? "需要补充凭证")
            let messageLabel = wrappingLabel(
                message,
                size: 10,
                color: provider.status == "error" ? .systemOrange : Theme.secondary,
                width: 310
            )
            actionRow.addArrangedSubview(messageLabel)
            let actionSpacer = NSView()
            actionSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            actionRow.addArrangedSubview(actionSpacer)
            actionRow.addArrangedSubview(ClosureButton(title: "配置", onTap: onConfigure))
            stack.addArrangedSubview(actionRow)
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -54).isActive = true
        }

        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12).isActive = true

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.separator.resolvedCGColor()
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func checkinTapped() {
        onCheckin()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyBackground()
    }

    func setDragging(_ value: Bool) {
        dragging = value
        alphaValue = value ? 0.92 : 1
        applyBackground()
    }

    private func applyBackground() {
        let color: NSColor
        if dragging {
            color = Theme.text.withAlphaComponent(0.08)
        } else if hovered {
            color = Theme.text.withAlphaComponent(0.04)
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    private func isExhausted(_ provider: ProviderStatus) -> Bool {
        provider.metrics.contains { ($0.remainingPercent ?? 100) <= 20 }
    }

    private func subtitle(for provider: ProviderStatus) -> String {
        switch provider.status {
        case "ok", "warn":
            if provider.id == "trae" || provider.id == "workbuddy" { return "积分余额" }
            if provider.id == "codex" { return "ChatGPT 订阅" }
            if provider.id == "deepseek" { return "API 余额（按量计费）" }
            return provider.detail ?? "已连接"
        case "error":
            return errorSummary(for: provider)
        case "unconfigured":
            return "还未连接"
        default:
            return ""
        }
    }

    private func errorSummary(for provider: ProviderStatus) -> String {
        let text = (provider.error ?? "").lowercased()
        if text.contains("ssl_") || text.contains("ssl_connect") || text.contains("curl: (35)") {
            return "SSL 连接失败"
        }
        if text.contains("could not resolve host") || text.contains("curl: (6)") {
            return "DNS 解析失败"
        }
        if text.contains("timed out") || text.contains("curl: (28)") || text.contains("timeout") {
            return "连接超时"
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return "网络不可达"
        }
        if text.contains("connection refused") || text.contains("failed to connect") || text.contains("curl: (7)") {
            return "无法连接服务器"
        }
        if text.contains("401") || text.contains("unauthorized") || text.contains("登录态") {
            return "登录态失效"
        }
        if text.contains("403") || text.contains("forbidden") {
            return "无权限访问"
        }
        return "连接失败"
    }

    private func errorHint(for provider: ProviderStatus) -> String {
        switch errorSummary(for: provider) {
        case "SSL 连接失败": return "检查代理或网络后重试"
        case "DNS 解析失败", "网络不可达", "连接超时", "无法连接服务器": return "检查网络后重试"
        case "登录态失效": return "重新登录后重试"
        case "无权限访问": return "检查账号权限"
        default: return "检查配置后重试"
        }
    }

    private func valueText(_ provider: ProviderStatus) -> String {
        if let percent = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
            return "\(Int(percent.rounded()))%"
        }
        if let credit = provider.metrics.first(where: { $0.kind == "credit" }) {
            if let text = credit.headlineValue, (credit.currency ?? "").isEmpty,
               let number = Int(text) {
                return NumberFormatter.grouped.string(from: NSNumber(value: number)) ?? text
            }
            return credit.headlineValue ?? "—"
        }
        if let text = provider.metrics.first(where: { $0.kind == "text" }) {
            return text.headlineValue ?? "—"
        }
        return "—"
    }

    private func valueCaption(_ provider: ProviderStatus) -> String {
        if provider.metrics.contains(where: { $0.kind == "percent" }) { return "" }
        if provider.metrics.contains(where: { $0.kind == "credit" }) {
            return (provider.id == "workbuddy" || provider.id == "trae") ? "积分" : "余额"
        }
        if provider.metrics.contains(where: { $0.kind == "text" }) { return "积分" }
        return ""
    }

    private func valueColor(_ provider: ProviderStatus) -> NSColor {
        if provider.status == "error" { return .labelColor }
        if let percent = provider.metrics.first(where: { $0.kind == "percent" })?.remainingPercent {
            return QuotaSeverity.from(remaining: percent).color
        }
        if let creditColor = QuotaStyle.creditColor(for: provider) {
            return creditColor
        }
        return .labelColor
    }
}

private extension NumberFormatter {
    static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

final class BarView: NSView {
    private let progress: CGFloat
    private let color: NSColor

    init(progress: CGFloat, color: NSColor) {
        self.progress = min(1, max(0, progress))
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.text.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let width = progress > 0.001 ? max(4, bounds.width * progress) : 2
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: 2, yRadius: 2
        ).fill()
    }
}


final class HeaderIconButton: NSButton {
    private var hovering = false
    var symbolName: String {
        didSet { applySymbol() }
    }

    init(symbol: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        applySymbol()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applySymbol() {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        contentTintColor = Theme.secondary
    }

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
        layer?.backgroundColor = Theme.hover.resolvedCGColor()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class LogoBadgeView: NSView {
    private let size: CGFloat
    private let imageView = NSImageView()

    init(provider: String, color: NSColor, size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let image = ProviderLogo.image(for: provider, size: size, color: .black) {
            image.isTemplate = true
            imageView.image = image
        } else {
            imageView.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
        }
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateInk()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInk()
    }

    func refreshInk() {
        updateInk()
    }

    private func updateInk() {
        imageView.contentTintColor = NSColor.labelColor.resolvedForAppearance()
    }
}
