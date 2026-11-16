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
    var onRefresh: (() -> Void)?
    var onCheckin: (() -> Void)?
    var onToggleAppearance: (() -> Void)?
    var onReorder: (([String]) -> Void)?

    private let root = ThemedRootView()
    private let titleLabel = NSTextField(labelWithString: "Agent 额度")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let headerActions = NSStackView()
    private let themeButton = HeaderIconButton(symbol: "moon")
    private let refreshButton = HeaderIconButton(symbol: "arrow.clockwise")
    private let checkinButton = HeaderIconButton(symbol: "checkmark.circle")
    private let insightStack = NSStackView()
    private let costLabel = NSTextField(labelWithString: "")
    private let historyRow = NSStackView()
    private let historyCaptionLabel = NSTextField(labelWithString: "近 7 天")
    private let sparkline = HistorySparklineView()
    private var checkinDone = false
    private var checkinDetailText = ""
    private var checkinRunning = false
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: String?
    private var lastRefreshing = false
    private var lastOffline = false
    private var lastReportedPreferredSize: NSSize = .zero
    private let spinner = NSProgressIndicator()
    private var draggingRow: ProviderRowView?

    // MARK: - 可选数据钩子（优先用注入值；缺省时读 CostStore/HistoryStore）
    /// 成本汇总行，例如 "今日 $0.42 · 近 7 天 $2.10"；返回 nil/空串则隐藏。
    var costTextProvider: (() -> String?)? {
        didSet { refreshInsights() }
    }
    /// 近 7 天历史值（从旧到新）；nil 表示当天无数据。
    var historyProvider: (() -> [Double?])? {
        didSet { refreshInsights() }
    }
    /// 历史小图的标题，默认「近 7 天」。
    var historyCaption: String = "近 7 天" {
        didSet { refreshInsights() }
    }
    /// 单个服务卡片的成本行（如 OpenCode）：由 AppDelegate/CostStore 读取
    /// `ProviderStatus` 的可选嵌套 `cost` 后返回文本；nil 表示该卡片不显示成本行。
    var providerCostTextProvider: ((ProviderStatus) -> String?)? {
        didSet {
            if let snapshot = lastSnapshot {
                update(
                    snapshot: snapshot,
                    error: lastError,
                    isRefreshing: lastRefreshing,
                    isOffline: lastOffline
                )
            }
        }
    }

    /// NSPopover 不会持续跟随 preferredContentSize；AppDelegate 可消费此回调/通知，
    /// 在面板已展开且内容高度变化时同步 popover.contentSize。
    var onPreferredContentSizeChange: ((NSSize) -> Void)?
    static let preferredContentSizeChanged = Notification.Name("AgentQuotaBar.popoverPreferredSizeChanged")

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

        titleLabel.stringValue = "额度"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.resolvedForAppearance()

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.tertiary
        subtitleLabel.isHidden = true
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.detachesHiddenViews = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true

        themeButton.target = self
        themeButton.action = #selector(themeTapped)
        themeButton.toolTip = "切换明暗"
        themeButton.setIconAccessibilityLabel("切换明暗外观")

        checkinButton.target = self
        checkinButton.action = #selector(checkinTapped)
        checkinButton.toolTip = "一键签到 Trae + WorkBuddy"
        checkinButton.setIconAccessibilityLabel("一键签到 Trae 和 WorkBuddy")

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "立即刷新"
        refreshButton.setIconAccessibilityLabel("立即刷新")
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
        for button in [checkinButton, themeButton, refreshButton, gear] { headerActions.addArrangedSubview(button) }

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        // 刷新状态放在 subtitle；不把空 spinner 留在 header 里，避免静止时出现灰点。
        let header = NSStackView(views: [titles, headerSpacer, headerActions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.detachesHiddenViews = true
        header.translatesAutoresizingMaskIntoConstraints = false

        // 成本行 + 近 7 天小图：有数据才出现，空状态不占高度。
        costLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        costLabel.textColor = Theme.secondary
        costLabel.lineBreakMode = .byTruncatingTail
        costLabel.isHidden = true
        costLabel.setAccessibilityLabel("成本汇总")

        historyCaptionLabel.font = .systemFont(ofSize: 10)
        historyCaptionLabel.textColor = Theme.tertiary
        historyCaptionLabel.setAccessibilityLabel("历史区间")
        historyCaptionLabel.stringValue = historyCaption

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        sparkline.setAccessibilityElement(true)
        sparkline.setAccessibilityRole(.image)
        sparkline.setAccessibilityLabel("近 7 天历史")
        sparkline.widthAnchor.constraint(equalToConstant: 132).isActive = true
        sparkline.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let historySpacer = NSView()
        historySpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        historyRow.orientation = .horizontal
        historyRow.alignment = .centerY
        historyRow.spacing = 8
        historyRow.detachesHiddenViews = true
        historyRow.addArrangedSubview(historyCaptionLabel)
        historyRow.addArrangedSubview(historySpacer)
        historyRow.addArrangedSubview(sparkline)
        historyRow.translatesAutoresizingMaskIntoConstraints = false
        historyRow.isHidden = true

        insightStack.orientation = .vertical
        insightStack.alignment = .leading
        insightStack.spacing = 4
        insightStack.detachesHiddenViews = true
        insightStack.setContentHuggingPriority(.required, for: .vertical)
        insightStack.setContentCompressionResistancePriority(.required, for: .vertical)
        insightStack.translatesAutoresizingMaskIntoConstraints = false
        insightStack.addArrangedSubview(costLabel)
        insightStack.addArrangedSubview(historyRow)
        costLabel.widthAnchor.constraint(equalTo: insightStack.widthAnchor).isActive = true
        historyRow.widthAnchor.constraint(equalTo: insightStack.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = Theme.tertiary
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.toolTip = "颜色按剩余比例：≥\(QuotaStyle.warningPercent)% 绿，\(QuotaStyle.dangerPercent)%–\(QuotaStyle.warningPercent)% 橙，<\(QuotaStyle.dangerPercent)% 红"

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
        root.addSubview(insightStack)
        root.addSubview(rowsStack)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            insightStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            insightStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            insightStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            rowsStack.topAnchor.constraint(equalTo: insightStack.bottomAnchor, constant: 6),
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
        headerActions.layer?.backgroundColor = Theme.surfaceAlt.resolvedCGColor()
        headerActions.layer?.borderColor = Theme.separator.resolvedCGColor()
        titleLabel.textColor = .labelColor.resolvedForAppearance()
        subtitleLabel.textColor = Theme.tertiary.resolvedForAppearance()
        footerLabel.textColor = Theme.tertiary.resolvedForAppearance()
        costLabel.textColor = Theme.secondary.resolvedForAppearance()
        historyCaptionLabel.textColor = Theme.tertiary.resolvedForAppearance()
        sparkline.needsDisplay = true
        let dark = Theme.currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        themeButton.symbolName = dark ? "sun.max" : "moon"
        view.needsDisplay = true
    }

    // MARK: - 成本 / 历史

    /// 后端成本/历史数据更新后调用；会同步内容与 popover 高度。
    func refreshInsights() {
        updateInsightContent()
        updatePreferredSize()
    }

    private func updateInsightContent() {
        guard isViewLoaded else { return }
        let cost = costTextProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCost = !(cost?.isEmpty ?? true)
        costLabel.stringValue = hasCost ? cost! : ""
        costLabel.isHidden = !hasCost
        costLabel.setAccessibilityValue(hasCost ? cost! : "无数据")

        let resolved = resolvedHistory()
        // 只有 1 天数据时不画一根孤零零的柱子；至少 2 天才构成“趋势”。
        let hasHistory = resolved.values.compactMap { $0 }.count >= 2
        // 剩余百分比固定 0–100 域，避免“只有一天/数值很小”被归一化成满格。
        sparkline.domainMax = resolved.caption.contains("成本") ? nil : 100
        sparkline.values = resolved.values
        historyCaptionLabel.stringValue = resolved.caption
        historyRow.isHidden = !hasHistory
    }

    /// 优先用外部注入的历史；未注入时先用 HistoryStore 的额度历史，再退回
    /// CostStore 的 OpenCode 7 天成本（都有本地缓存，缺失则隐藏）。
    private func resolvedHistory() -> (values: [Double?], caption: String) {
        if let historyProvider {
            return (historyProvider(), historyCaption)
        }
        if let snapshot = lastSnapshot {
            let target = snapshot.worstProviderID() ?? snapshot.providers.first?.id
            if let target {
                let values = HistoryStore.shared.remainingValues(provider: target)
                if values.contains(where: { $0 != nil }) {
                    let name = ProviderStyles.style(for: target).shortName
                    return (values, "\(name) · 近 7 天剩余")
                }
            }
        }
        let days = CostStore.shared.daily()
        let hasData = days.contains { $0.cost > 0 || $0.tokens.total > 0 || $0.sessions > 0 }
        guard hasData else { return ([], historyCaption) }
        return (days.map { Optional($0.cost) }, "OpenCode · 近 7 天成本")
    }

    /// 单个服务卡片的成本行：优先外部注入，否则 OpenCode 直接读 CostStore
    /// （嵌套 `ProviderStatus.cost` 优先，缺失时回退本地库）。
    private func resolvedCostText(for provider: ProviderStatus) -> String? {
        if let providerCostTextProvider {
            return providerCostTextProvider(provider)
        }
        guard provider.cost != nil || provider.id == CostStore.openCodeProviderID else { return nil }
        return CostStore.shared.summaryText(for: provider, config: service.config)
    }

    func updateCheckin(status: String, detail: String, done: Bool, running: Bool) {
        checkinDone = done
        checkinDetailText = detail
        checkinRunning = running
        // 两个都签完就自动隐藏；运行中保留但禁用，避免重复点击。
        checkinButton.isHidden = done
        checkinButton.isEnabled = !running
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
        updateInsightContent()
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshButton.isEnabled = !isRefreshing
        refreshButton.toolTip = isRefreshing ? "正在刷新…" : "立即刷新"

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
        if ordered.isEmpty {
            let empty = wrappingLabel(
                "还没有启用服务。打开设置 → 服务，选择要显示的 Agent。",
                size: 11,
                color: Theme.secondary,
                width: 310
            )
            rowsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        for (index, provider) in ordered.enumerated() {
            let category = Self.category(for: provider)
            let showsCategory = index == 0 || Self.category(for: ordered[index - 1]) != category
            let row = ProviderRowView(
                provider: provider,
                todaySpent: UsageTracker.shared.todaySpent(for: provider.id),
                checkinDone: checkinDone,
                checkinStreak: service.config.int("checkin.workbuddyStreak", default: 0),
                costText: resolvedCostText(for: provider),
                category: category,
                showsCategory: showsCategory,
                onConfigure: { [weak self] in
                    self?.onConfigure?(provider.id)
                },
                onCheckin: { [weak self] in
                    self?.onCheckin?()
                },
                onStatus: { [weak self] in
                    self?.openServiceStatus(provider.id)
                }
            )
            row.showsSeparator = index < ordered.count - 1
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleRowPan(_:)))
            row.addGestureRecognizer(pan)
        }

        let subtitle = isOffline ? "网络未连接 · 显示上次数据" : (isRefreshing ? "正在刷新…" : "")
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        if isOffline {
            footerLabel.stringValue = "⚠︎ 网络未连接，联网后自动刷新"
            footerLabel.textColor = .systemOrange
        } else if let error {
            footerLabel.stringValue = "⚠︎ " + error
            footerLabel.textColor = .systemOrange
        } else {
            footerLabel.stringValue = "更新 \(timeText(snapshot.updatedDate))"
            footerLabel.textColor = Theme.tertiary
        }

        updatePreferredSize()
    }

    private static func category(for provider: ProviderStatus) -> String {
        if provider.metrics.contains(where: { $0.kind == "percent" }) { return "订阅额度" }
        if provider.id == "deepseek" { return "现金余额" }
        return "积分"
    }

    private func openServiceStatus(_ providerID: String) {
        let URLs = [
            "codex": "https://status.openai.com",
            "opencode": "https://status.opencode.ai",
            "deepseek": "https://status.deepseek.com",
        ]
        if let raw = URLs[providerID], let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
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
        var insightsHeight: CGFloat = 0
        if !costLabel.isHidden {
            insightsHeight += costLabel.fittingSize.height
        }
        if !historyRow.isHidden {
            if insightsHeight > 0 { insightsHeight += insightStack.spacing }
            insightsHeight += historyRow.fittingSize.height
        }
        // 顶部 14 + header 约 31 + 间距 12 + rows + 间距 8 + footer 约 16 + 底部 10
        let height = min(840, max(160, rowsHeight + 92 + insightsHeight))
        let size = NSSize(width: 380, height: height)
        preferredContentSize = size
        view.invalidateIntrinsicContentSize()
        view.setFrameSize(size)
        // NSPopover 在 show 之后不会持续同步 preferredContentSize，这里主动通知一次。
        if abs(size.height - lastReportedPreferredSize.height) > 0.5 {
            lastReportedPreferredSize = size
            onPreferredContentSizeChange?(size)
            NotificationCenter.default.post(
                name: Self.preferredContentSizeChanged,
                object: self,
                userInfo: ["size": NSValue(size: size)]
            )
        }
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
        button.setIconAccessibilityLabel(tooltip)
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

    @objc private func refreshTapped() { onRefresh?() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func quitTapped() { NSApplication.shared.terminate(nil) }
}

// MARK: - 单行

/// 实心绿色圆圈 + 白色对勾：用于 WorkBuddy / Trae 今日已签到。
final class CheckinBadgeView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 15, height: 15) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("今日已签到")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height)
        let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - diameter) / 2,
                                                 width: diameter, height: diameter))
        QuotaStyle.healthyColor.setFill()
        circle.fill()

        let check = NSBezierPath()
        check.lineWidth = 1.7
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: diameter * 0.28, y: diameter * 0.53))
        check.line(to: NSPoint(x: diameter * 0.44, y: diameter * 0.36))
        check.line(to: NSPoint(x: diameter * 0.73, y: diameter * 0.67))
        NSColor.white.setStroke()
        check.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class StatusDotView: NSView {
    var color: NSColor = QuotaStyle.healthyColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class ProviderRowView: NSView {
    let providerID: String
    private let provider: ProviderStatus
    private let todaySpent: Double?
    private let checkinDone: Bool
    private let checkinStreak: Int
    private let costText: String?
    private let category: String
    private let showsCategory: Bool
    private let onConfigure: () -> Void
    private let onCheckin: () -> Void
    private let onStatus: (() -> Void)?
    private var hovered = false
    private var dragging = false
    private let separator = NSView()
    private var trackingAreaRef: NSTrackingArea?

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(
        provider: ProviderStatus,
        todaySpent: Double?,
        checkinDone: Bool,
        checkinStreak: Int,
        costText: String? = nil,
        category: String,
        showsCategory: Bool,
        onConfigure: @escaping () -> Void,
        onCheckin: @escaping () -> Void,
        onStatus: (() -> Void)? = nil
    ) {
        self.providerID = provider.id
        self.provider = provider
        self.todaySpent = todaySpent
        self.checkinDone = checkinDone
        self.checkinStreak = checkinStreak
        self.costText = costText
        self.category = category
        self.showsCategory = showsCategory
        self.onConfigure = onConfigure
        self.onCheckin = onCheckin
        self.onStatus = onStatus
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let style = ProviderStyles.style(for: provider.id)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let badge = LogoBadgeView(provider: provider.id, color: style.color, size: 24)

        let name = label(style.shortName, size: 15, weight: .semibold)
        let statusDot = StatusDotView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let statusColor: NSColor
        switch provider.status {
        case "ok", "warn": statusColor = QuotaStyle.healthyColor
        case "unconfigured": statusColor = .systemOrange
        case "error": statusColor = .systemRed
        default: statusColor = Theme.tertiary
        }
        statusDot.color = statusColor
        statusDot.toolTip = provider.status == "ok" ? "已连接" : (provider.error ?? provider.detail ?? provider.status)
        let nameRow = NSStackView(views: [name, statusDot])
        nameRow.orientation = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .centerY
        if let plan = provider.plan, !plan.isEmpty {
            nameRow.addArrangedSubview(label(Self.displayPlan(plan), size: 10, color: Theme.tertiary))
        }
        if provider.id == "trae" || provider.id == "workbuddy" {
            if checkinDone {
                let badge = CheckinBadgeView()
                badge.toolTip = "今日已签到"
                badge.setAccessibilityLabel("今日已签到")
                nameRow.addArrangedSubview(badge)
            } else {
                let checkin = NSButton(title: "签到", target: self, action: #selector(checkinTapped))
                checkin.isBordered = false
                checkin.bezelStyle = .inline
                checkin.font = .systemFont(ofSize: 10.5, weight: .medium)
                checkin.contentTintColor = Theme.accent
                checkin.setAccessibilityLabel("签到 \(style.shortName)")
                nameRow.addArrangedSubview(checkin)
            }
        }
        if let serviceStatus = provider.serviceStatus, serviceStatus != "ok" {
            let statusButton = NSButton(
                title: serviceStatus == "outage" ? "服务故障" : "服务降级",
                target: self,
                action: #selector(statusTapped)
            )
            statusButton.isBordered = false
            statusButton.font = .systemFont(ofSize: 10, weight: .medium)
            statusButton.contentTintColor = serviceStatus == "outage" ? .systemRed : .systemOrange
            statusButton.toolTip = provider.serviceStatusDescription
            statusButton.setAccessibilityLabel("查看 \(style.shortName) 服务状态")
            nameRow.addArrangedSubview(statusButton)
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

        let subText = subtitle(for: provider)
        let info = NSStackView(views: subText.isEmpty ? [nameRow] : [nameRow, label(subText, size: 12, color: Theme.tertiary)])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let value = label(valueText(provider), size: 22, weight: .semibold, color: valueColor(provider), monospaced: true)
        value.alignment = .right

        let valueRow = NSStackView()
        valueRow.orientation = .horizontal
        valueRow.alignment = .firstBaseline
        valueRow.spacing = 4
        valueRow.addArrangedSubview(value)
        if provider.id == "trae" || provider.id == "workbuddy" {
            valueRow.addArrangedSubview(label("积分", size: 11, color: Theme.tertiary))
        }
        let valueStack = NSStackView()
        valueStack.orientation = .vertical
        valueStack.alignment = .trailing
        valueStack.spacing = 2
        valueStack.addArrangedSubview(valueRow)
        if let captionText = valueCaption(provider, todaySpent: todaySpent), !captionText.isEmpty {
            let caption = label(captionText, size: 10, color: Theme.secondary)
            caption.alignment = .right
            valueStack.addArrangedSubview(caption)
        }

        if valueCaption(provider, todaySpent: todaySpent) == nil,
           provider.id == "deepseek",
           let supporting = compactDetail(
               provider.metrics.first(where: { $0.kind == "credit" })?.detail
               ?? provider.metrics.first(where: { $0.kind == "text" })?.detail
           ) {
            let caption = label(supporting, size: 10, color: Theme.tertiary)
            caption.alignment = .right
            valueStack.addArrangedSubview(caption)
        }

        if showsCategory {
            let categoryLabel = label(category, size: 11, weight: .semibold, color: Theme.secondary)
            categoryLabel.setAccessibilityLabel("分组：\(category)")
            stack.addArrangedSubview(categoryLabel)
            categoryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let header = NSStackView(views: [badge, info, spacer, valueStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: 46).isActive = true

        // 可选成本行（如 OpenCode）；数据来自 ProviderStatus 的嵌套 cost，缺省不占位。
        let hasCostLine = !(costText?.isEmpty ?? true)
        if let costText, hasCostLine {
            let cost = label(costText, size: 10, color: Theme.tertiary)
            cost.lineBreakMode = .byTruncatingTail
            cost.setAccessibilityLabel("成本")
            stack.addArrangedSubview(cost)
            cost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let percentMetrics = provider.metrics.filter { $0.kind == "percent" }
        for (index, metric) in percentMetrics.prefix(3).enumerated() {
            let remaining = metric.remainingPercent ?? 0
            let used = metric.usedPercent ?? max(0, 100 - remaining)
            let severity = QuotaSeverity.from(remaining: remaining)
            let primary = index == 0
            let titleSize: CGFloat = primary ? 13 : 12

            // 维度名在左，剩余在右；重置时间放到进度条下方，避免左右来回找对应关系。
            let meta = NSStackView()
            meta.orientation = .horizontal
            meta.spacing = 8
            meta.alignment = .centerY
            meta.addArrangedSubview(label(
                metric.label,
                size: titleSize,
                weight: .medium,
                color: Theme.secondary
            ))
            let metaSpacer = NSView()
            metaSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            meta.addArrangedSubview(metaSpacer)
            if percentMetrics.count > 1, !primary {
                meta.addArrangedSubview(label(
                    "剩 \(Int(remaining.rounded()))%",
                    size: titleSize,
                    weight: .semibold,
                    color: remaining <= QuotaStyle.warningPercent ? severity.color : Theme.secondary
                ))
            }
            if let detail = metric.detail, !detail.isEmpty {
                let detailText = primary ? "已用 \(Int(used.rounded()))% · \(detail)" : "· \(detail)"
                meta.addArrangedSubview(label(detailText, size: 9, color: Theme.tertiary))
            }
            stack.addArrangedSubview(meta)
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            // 行业语义：填充 = 已使用，不再用“剩余”填充。
            let barColor = remaining <= QuotaStyle.warningPercent ? severity.color : QuotaStyle.healthyColor
            let visualProgress = used > 0 ? max(0.03, used / 100) : 0
            let bar = BarView(progress: visualProgress, color: barColor)
            bar.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(bar)
            bar.heightAnchor.constraint(equalToConstant: primary ? 4 : 3).isActive = true
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        }

        if !["deepseek", "trae", "workbuddy"].contains(provider.id),
           let supporting = compactDetail(
                    provider.metrics.first(where: { $0.kind == "credit" })?.detail
                    ?? provider.metrics.first(where: { $0.kind == "text" })?.detail
                  ) {
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

        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10).isActive = true

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

    @objc private func statusTapped() {
        onStatus?()
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

    /// 去掉 “赠金 ¥0.00 ·” 这类没有参考价值的零值片段，避免底部一行被零占据。
    private static func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "free": return "免费"
        default: return plan
        }
    }

    private func compactDetail(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                !part.isEmpty
                && !part.contains("¥0.00")
                && !part.contains("0.00 元")
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func isExhausted(_ provider: ProviderStatus) -> Bool {
        provider.metrics.contains { ($0.remainingPercent ?? 100) <= 20 }
    }

    private func subtitle(for provider: ProviderStatus) -> String {
        switch provider.status {
        case "ok", "warn":
            if provider.id == "codex" {
                if let raw = provider.subscriptionUntil,
                   let date = ISO8601DateFormatter.flexible.date(from: raw)
                    ?? ISO8601DateFormatter().date(from: raw) {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "zh_CN")
                    formatter.dateFormat = "M/d"
                    let renew = provider.subscriptionWillRenew == true ? " · 自动续费" : ""
                    return "ChatGPT 订阅 · \(formatter.string(from: date)) 到期\(renew)"
                }
                return "ChatGPT 订阅"
            }
            if provider.id == "deepseek" { return "API 余额（按量计费）" }
            if provider.id == "trae" || provider.id == "workbuddy" { return "" }
            let detail = provider.detail ?? "已连接"
            return detail.replacingOccurrences(of: " 订阅额度", with: "")
        case "error":
            return errorSummary(for: provider)
        case "unconfigured":
            return "还未连接"
        default:
            return ""
        }
    }

    private func errorSummary(for provider: ProviderStatus) -> String {
        ProviderErrorText.summary(provider.error)
    }

    private func errorHint(for provider: ProviderStatus) -> String {
        ProviderErrorText.hint(for: errorSummary(for: provider))
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

    private func valueCaption(_ provider: ProviderStatus, todaySpent: Double?) -> String? {
        guard provider.metrics.contains(where: { $0.kind == "credit" }),
              let spent = todaySpent, spent > 0.0001 else { return nil }
        if provider.id == "deepseek" {
            return String(format: "今日 -¥%.2f", spent)
        }
        return "今日 -\(Int(spent.rounded()))"
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
        let description = accessibilityLabel() ?? toolTip
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        contentTintColor = Theme.secondary
    }

    /// 供调用方在设置 tooltip/label 后刷新图像的无障碍描述。
    func setIconAccessibilityLabel(_ value: String) {
        setAccessibilityLabel(value)
        applySymbol()
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

// MARK: - 近 7 天历史小图

/// 7 天消耗柱状小图。只负责绘制，数据由 `historyProvider` 注入；
/// 缺失值画成小点，避免误显示为 0。
final class HistorySparklineView: NSView {
    /// nil 表示按数据最大值归一化（成本曲线）；设置后按固定 0...domainMax（剩余百分比）。
    var domainMax: Double? {
        didSet { needsDisplay = true }
    }
    var values: [Double?] = [] {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.separator.withAlphaComponent(0.10).setFill()
        track.fill()

        let count = max(values.count, 1)
        guard !values.isEmpty else { return }
        let maxValue = domainMax ?? (values.compactMap({ $0 }).max() ?? 0)
        let gap: CGFloat = 2
        let cellWidth = max(1, (bounds.width - 2 - gap * CGFloat(count - 1)) / CGFloat(count))
        let baseline: CGFloat = 3
        let available = max(2, bounds.height - baseline * 2)

        for (index, value) in values.enumerated() {
            let x = 1 + CGFloat(index) * (cellWidth + gap)
            guard let value else {
                // 缺失值：居中一个小点，和“数值为 0”区分开。
                Theme.tertiary.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + cellWidth / 2 - 1, y: bounds.midY - 1, width: 2, height: 2)).fill()
                continue
            }
            let fraction = maxValue > 0 ? CGFloat(max(0, min(1, value / maxValue))) : 0
            let barHeight = max(value == 0 ? 1.5 : 2, available * fraction)
            let bar = NSRect(x: x, y: baseline, width: cellWidth, height: barHeight)
            // 最后一天（今天）更醒目。
            let alpha: CGFloat = index == values.count - 1 ? 0.95 : 0.55
            (value == 0 ? QuotaStyle.dangerColor : Theme.accent).withAlphaComponent(alpha).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: min(2, cellWidth / 2),
                yRadius: min(2, cellWidth / 2)
            ).fill()
        }
    }

    private func updateAccessibilityValue() {
        guard !values.isEmpty else {
            setAccessibilityValue("无数据")
            return
        }
        let text = values.map { value in
            value.map { String(format: "%.2f", $0) } ?? "无数据"
        }.joined(separator: "，")
        setAccessibilityValue(text)
    }
}
