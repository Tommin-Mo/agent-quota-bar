import AppKit

// MARK: - 弹出面板

final class ThemedRootView: ThemedSurfaceView {
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
    var onSelectServices: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCheckin: (() -> Void)?
    var onHistory: (() -> Void)?
    var onToggleAppearance: (() -> Void)?
    var onReorder: (([String]) -> Void)?

    private let root = ThemedRootView()
    private let titleLabel = NSTextField(labelWithString: "额度概览")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let masthead = ThemedSurfaceView()
    private let footer = NSStackView()
    private let pager = NSStackView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let previousPage = NSButton()
    private let nextPage = NSButton()
    private var pageIndex = 0
    private var pageAnchor: String?
    var availableHeight: CGFloat = 720 { didSet { if isViewLoaded { updatePreferredSize() } } }
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let headerActions = NSStackView()
    private var headerInset: NSLayoutConstraint?
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
    private var expandedID: String?
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: String?
    private var lastRefreshing = false
    private var lastOffline = false
    private var lastReportedPreferredSize: NSSize = .zero
    private let spinner = NSProgressIndicator()
    private var refreshDelay: DispatchWorkItem?
    private var showingRefreshMark = false
    private var panelVisible = false
    private let headerHint = HeaderHint()
    private var draggingRow: ProviderRowView?
    private var lastRowOrderSignature = ""

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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateRefreshMark),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        root.onAppearanceChange = { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.refreshAppearance()
        }
        root.isWindowCanvas = true
        root.wantsLayer = true
        root.surfaceColor = Theme.surface
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 520)

        titleLabel.stringValue = "额度概览"
        titleLabel.font = Theme.headingFont(size: Theme.design == .claude ? 25 : 19, weight: .bold)
        titleLabel.textColor = Theme.text

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.secondary
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
        refreshButton.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 15), spinner.heightAnchor.constraint(equalToConstant: 15),
            spinner.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor)
        ])

        themeButton.target = self
        themeButton.action = #selector(themeTapped)
        themeButton.toolTip = "切换明暗"
        themeButton.setIconAccessibilityLabel("切换明暗外观")

        checkinButton.target = self
        checkinButton.action = #selector(checkinTapped)
        checkinButton.toolTip = "一键签到 Trae / WorkBuddy / 豆包"
        checkinButton.setIconAccessibilityLabel("一键签到 Trae、WorkBuddy 和豆包")

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "立即刷新"
        refreshButton.setIconAccessibilityLabel("立即刷新")
        let history = iconButton("calendar", tooltip: "用量历史", action: #selector(historyTapped))
        let gear = iconButton("gearshape", tooltip: "设置", action: #selector(settingsTapped))

        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 3
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        for button in [checkinButton, history, themeButton, refreshButton, gear] { headerActions.addArrangedSubview(button) }

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        // 刷新状态放在 subtitle；不把空 spinner 留在 header 里，避免静止时出现灰点。
        let actions = ThemedSurfaceView()
        actions.wantsLayer = true
        actions.layer?.cornerRadius = 18
        actions.isNavigationSurface = true
        actions.surfaceColor = .clear
        actions.addSubview(headerActions)
        NSLayoutConstraint.activate([
            headerActions.leadingAnchor.constraint(equalTo: actions.leadingAnchor, constant: 5),
            headerActions.trailingAnchor.constraint(equalTo: actions.trailingAnchor, constant: -5),
            headerActions.topAnchor.constraint(equalTo: actions.topAnchor, constant: 2),
            headerActions.bottomAnchor.constraint(equalTo: actions.bottomAnchor, constant: -2)
        ])
        let header = NSStackView(views: [titles, headerSpacer, actions])
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

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        for (button, title, icon) in [(previousPage, "上一页服务", "chevron.left"), (nextPage, "下一页服务", "chevron.right")] {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(title)
            button.target = self
            button.action = #selector(changePage(_:))
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        [previousPage, pageLabel, nextPage].forEach { pager.addArrangedSubview($0) }
        pager.spacing = 6
        pager.isHidden = true
        [footerLabel, footerSpacer, pager].forEach { footer.addArrangedSubview($0) }
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        masthead.wantsLayer = true
        masthead.layer?.cornerRadius = 12
        masthead.surfaceColor = .clear
        masthead.layer?.cornerCurve = .continuous
        masthead.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(masthead)
        masthead.addSubview(header)
        root.addSubview(insightStack)
        root.addSubview(rowsStack)
        root.addSubview(footer)

        let inset = header.leadingAnchor.constraint(equalTo: masthead.leadingAnchor, constant: 2)
        headerInset = inset
        NSLayoutConstraint.activate([
            masthead.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            masthead.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            masthead.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: masthead.topAnchor, constant: 10),
            header.bottomAnchor.constraint(equalTo: masthead.bottomAnchor, constant: -10),
            inset,
            header.trailingAnchor.constraint(equalTo: masthead.trailingAnchor, constant: -8),

            insightStack.topAnchor.constraint(equalTo: masthead.bottomAnchor, constant: 6),
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

        root.addSubview(headerHint)
        for case let button as HeaderIconButton in headerActions.arrangedSubviews {
            button.hintText = button.toolTip ?? ""
            button.toolTip = nil
            button.onHover = { [weak self] hovered in self?.headerHint.track(hovered) }
        }
        view = root
        preferredContentSize = NSSize(width: 380, height: 520)
        refreshAppearance()
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
        headerInset?.constant = 2
        rowsStack.spacing = Theme.design == .glass ? 5 : 0
        Theme.refreshViews(view)
        titleLabel.font = Theme.headingFont(size: Theme.design == .claude ? 25 : 19, weight: .bold)
        root.surfaceColor = Theme.design == .claude ? Theme.background : Theme.surface
        titleLabel.textColor = Theme.text
        subtitleLabel.textColor = Theme.secondary
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
        let actual = resolved.values.compactMap { $0 }
        // 只有 1～2 天采样不是“趋势”，反而像一条无解释的装饰条；
        // 满 7 天才显示，并改成一个明确的区间标签。
        let hasHistory = actual.count >= 7
        // 不再为缺失日期画灰点；只画真实采样，避免“近 7 天”里出现 5 个空点。
        sparkline.domainMax = resolved.caption.contains("成本") ? nil : 100
        sparkline.values = actual
        historyCaptionLabel.stringValue = resolved.caption
        historyRow.isHidden = true
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
        // Do not rebuild every provider row here: AppDelegate calls this right
        // after update(), and a second synchronous rebuild would cancel the
        // value/expand transitions before the first frame can paint.
    }

    @objc private func checkinTapped() {
        onCheckin?()
    }

    @objc private func themeTapped() {
        onToggleAppearance?()
    }

    func update(snapshot: QuotaSnapshot?, error: String?, isRefreshing: Bool, isOffline: Bool = false) {
        let previousSnapshot = lastSnapshot
        let snapshot = snapshot ?? (isRefreshing && !isOffline ? lastSnapshot : nil)
        lastSnapshot = snapshot
        lastError = error
        lastRefreshing = isRefreshing
        lastOffline = isOffline
        updateInsightContent()
        subtitleLabel.textColor = Theme.secondary
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        refreshButton.isEnabled = !isRefreshing
        refreshButton.hintText = isRefreshing ? "正在刷新…" : "立即刷新"
        refreshButton.setAccessibilityLabel(refreshButton.hintText)
        updateRefreshMark()

        guard let snapshot else {
            subtitleLabel.isHidden = false
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
                footerLabel.textColor = Theme.warning
            } else {
                footerLabel.stringValue = isRefreshing ? "正在查询…" : "尚未刷新"
                footerLabel.textColor = Theme.tertiary
            }
            updatePreferredSize()
            return
        }


        let ordered = orderedProviders(snapshot)
        if ordered.isEmpty {
            let empty = wrappingLabel(
                "当前没有可显示的服务。",
                size: 11,
                color: Theme.secondary,
                width: 310
            )
            rowsStack.addArrangedSubview(empty)
            rowsStack.addArrangedSubview(NSButton(title: "选择显示的服务…", target: self, action: #selector(selectServices)))
            empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        let rowSignature = ordered.map(\.id).joined(separator: "|")
        let structureChanged = !lastRowOrderSignature.isEmpty && lastRowOrderSignature != rowSignature
        lastRowOrderSignature = rowSignature
        for (index, provider) in ordered.enumerated() {
            let row = ProviderRowView(
                provider: provider,
                expanded: expandedID == provider.id && provider.hasExpandableWindows,
                preferredWindow: service.config.string("panelWindow." + provider.id),
                onToggle: { [weak self] in
                    guard let self else { return }
                    self.pageIndex = 0
                    self.pageAnchor = provider.id
                    self.expandedID = self.expandedID == provider.id ? nil : provider.id
                    for case let row as ProviderRowView in self.rowsStack.arrangedSubviews {
                        row.setExpanded(row.providerID == self.expandedID, animated: true)
                    }
                    self.updatePreferredSize()
                    let button = self.rowsStack.arrangedSubviews.compactMap { $0 as? ProviderRowView }.first { $0.providerID == provider.id }?.toggleButton
                    if let button { button.window?.makeFirstResponder(button) }
                },
                todaySpent: UsageTracker.shared.todaySpent(for: provider.id),
                checkinDone: CheckinService.result(for: provider.id, in: service.config) == "已签到",
                checkinStreak: service.config.int("checkin.workbuddyStreak", default: 0),
                costText: resolvedCostText(for: provider),
                onConfigure: { [weak self] in
                    self?.onConfigure?(provider.id)
                },
                onCheckin: { [weak self] in
                    self?.onCheckin?()
                },
                onStatus: { [weak self] in
                    self?.openServiceStatus(provider.id)
                },
                animateValue: previousSnapshot?.provider(withID: provider.id).map {
                    snapshot.signature(for: $0) != snapshot.signature(for: provider)
                } ?? false
            )
            row.showsSeparator = Theme.design != .glass && index < ordered.count - 1
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleRowPan(_:)))
            pan.delegate = row
            row.addGestureRecognizer(pan)
        }

        if structureChanged {
            QuotaMotion.reveal(rowsStack, duration: QuotaMotion.standard, offset: 3)
        }
        let headers = rowsStack.arrangedSubviews.compactMap { ($0 as? ProviderRowView)?.summaryHeader }
        if let height = headers.map({ ceil($0.fittingSize.height) }).max() {
            for header in headers {
                header.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
        }

        if isOffline {
            subtitleLabel.stringValue = "离线 · 显示上次数据"
        } else if isRefreshing {
            subtitleLabel.stringValue = "正在刷新…"
        } else if let urgent = snapshot.mostUrgent.first, urgent.riskTier <= 2 {
            // 首屏先回答“谁最紧张”，而不是只报数量；不改变用户固定排序。
            let urgentCount = snapshot.mostUrgent.count
            subtitleLabel.stringValue = urgentCount == 1
                ? snapshot.riskSummary
                : "\(urgentCount) 家服务需关注 · 已显示 \(ordered.count) 项服务"
            subtitleLabel.textColor = urgent.riskTier <= 1 ? Theme.danger : Theme.warning
        } else {
            subtitleLabel.stringValue = ordered.isEmpty ? "" : "已显示 \(ordered.count) 项服务"
            subtitleLabel.textColor = Theme.secondary
        }
        subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
        subtitleLabel.toolTip = subtitleLabel.stringValue

        if isOffline {
            footerLabel.stringValue = "⚠︎ 网络未连接，联网后自动刷新"
            footerLabel.textColor = Theme.warning
        } else if let error {
            footerLabel.stringValue = "⚠︎ " + error
            footerLabel.textColor = Theme.warning
        } else {
            footerLabel.stringValue = snapshot.updatedDate.map { "更新于 " + timeText($0) } ?? ""
            footerLabel.textColor = Theme.tertiary
        }

        updatePreferredSize()
    }

    private static func category(for provider: ProviderStatus) -> String {
        provider.category
    }

    static func serviceStatusURL(_ providerID: String) -> URL? {
        let urls = [
            "codex": "https://status.openai.com",
            "opencode": "https://status.opencode.ai",
            "deepseek": "https://status.deepseek.com",
        ]
        return urls[providerID].flatMap(URL.init(string:))
    }

    private func openServiceStatus(_ providerID: String) {
        if let url = Self.serviceStatusURL(providerID) {
            NSWorkspace.shared.open(url)
        }
    }

    func expandForSnapshot(_ id: String) {
        guard expandedID != id else { return }
        rowsStack.arrangedSubviews.compactMap { $0 as? ProviderRowView }.first { $0.providerID == id }?.toggleButton.performClick(nil)
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
            color: Theme.warning,
            width: 310
        )
        rowsStack.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    @objc private func changePage(_ sender: NSButton) {
        let old = pageIndex
        pageAnchor = nil
        pageIndex += sender === nextPage ? 1 : -1
        updatePreferredSize()
        if pageIndex != old {
            QuotaMotion.settle(rowsStack)
        }
    }

    private func updatePreferredSize() {
        let rows = rowsStack.arrangedSubviews
        for row in rows {
            row.isHidden = false
            (row as? ProviderRowView)?.showDetailRange(nil)
        }
        view.layoutSubtreeIfNeeded()
        let heights = rows.map { ceil($0.fittingSize.height) }
        let total = heights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowsStack.spacing
        let fixed = ceil(masthead.fittingSize.height + insightStack.fittingSize.height) + 40
        let fullHeight = fixed + ceil(footerLabel.fittingSize.height) + total
        pager.isHidden = fullHeight <= availableHeight || rows.isEmpty
        if !pager.isHidden {
            let budget = availableHeight - fixed - ceil(pager.fittingSize.height)
            var pages: [(rows: [NSView], details: Range<Int>?)] = []
            var used: CGFloat = 0
            for (row, height) in zip(rows, heights) {
                if height > budget, let provider = row as? ProviderRowView,
                   let parts = provider.detailPages(availableHeight: budget, rowHeight: height) {
                    for part in parts { pages.append(([row], part)) }
                    used = budget
                    continue
                }
                if pages.isEmpty || used + rowsStack.spacing + height > budget {
                    pages.append(([], nil))
                    used = 0
                }
                if !pages[pages.count - 1].rows.isEmpty { used += rowsStack.spacing }
                pages[pages.count - 1].rows.append(row)
                used += height
            }
            pageIndex = min(max(0, pageIndex), pages.count - 1)
            if let pageAnchor, !pages[pageIndex].rows.contains(where: { ($0 as? ProviderRowView)?.providerID == pageAnchor }) {
                pageIndex = pages.firstIndex { page in
                    page.rows.contains { ($0 as? ProviderRowView)?.providerID == pageAnchor }
                } ?? 0
            }
            let page = pages[pageIndex]
            pageAnchor = (page.rows.first as? ProviderRowView)?.providerID
            for row in rows {
                row.isHidden = !page.rows.contains(row)
                if !row.isHidden { (row as? ProviderRowView)?.showDetailRange(page.details) }
            }
            pageLabel.stringValue = "\(pageIndex + 1) / \(pages.count)"
            previousPage.isEnabled = pageIndex > 0
            nextPage.isEnabled = pageIndex + 1 < pages.count
        } else {
            pageIndex = 0
            pageAnchor = nil
        }
        let size = NSSize(width: 380, height: pager.isHidden ? min(availableHeight, max(150, fullHeight)) : availableHeight)
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

    private func timeText(_ date: Date) -> String {
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
        case .cancelled, .failed:
            row.setDragging(false)
            draggingRow = nil
        case .ended:
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
        // Drag reorder is a direct manipulation: follow the pointer immediately,
        // do not put a layout animation between the hand and the row.
        rowsStack.layoutSubtreeIfNeeded()
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if !visible { headerHint.reset() }
        updateRefreshMark()
    }

    @objc private func updateRefreshMark() {
        guard panelVisible && lastRefreshing else {
            refreshDelay?.cancel()
            refreshDelay = nil
            showingRefreshMark = false
            spinner.stopAnimation(nil)
            refreshButton.symbolName = "arrow.clockwise"
            return
        }
        if showingRefreshMark {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spinner.stopAnimation(nil)
                refreshButton.symbolName = "hourglass"
            } else {
                refreshButton.image = nil
                spinner.startAnimation(nil)
            }
        } else if refreshDelay == nil {
            let delay = DispatchWorkItem { [weak self] in
                guard let self, self.panelVisible, self.lastRefreshing else { return }
                self.refreshDelay = nil
                self.showingRefreshMark = true
                self.updateRefreshMark()
            }
            refreshDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: delay)
        }
    }

    @objc private func refreshTapped() { if !lastRefreshing { onRefresh?() } }
    @objc private func selectServices() { onSelectServices?() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func historyTapped() { onHistory?() }
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

final class ProviderRowView: NSView, NSGestureRecognizerDelegate {
    let toggleButton = NSButton()
    private let stack = NSStackView()
    private let detail = NSStackView()
    private var collapsedWarning: NSTextField?
    private var isExpanded = false
    private let onToggle: () -> Void
    let providerID: String
    fileprivate let summaryHeader = NSView()
    private let provider: ProviderStatus
    private let todaySpent: Double?
    private let checkinDone: Bool
    private let checkinStreak: Int
    private let costText: String?
    private let onConfigure: () -> Void
    private let onCheckin: () -> Void
    private let onStatus: (() -> Void)?
    private let animateValue: Bool
    private weak var primaryValueLabel: NSTextField?
    private var pendingValueSettle = false
    private var hovered = false
    private var dragging = false
    private let separator = NSView()
    private var trackingAreaRef: NSTrackingArea?

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(
        provider: ProviderStatus,
        expanded: Bool = false,
        preferredWindow: String = "",
        onToggle: @escaping () -> Void = {},
        todaySpent: Double?,
        checkinDone: Bool,
        checkinStreak: Int,
        costText: String? = nil,
        onConfigure: @escaping () -> Void,
        onCheckin: @escaping () -> Void,
        onStatus: (() -> Void)? = nil,
        animateValue: Bool = false
    ) {
        self.onToggle = onToggle
        self.providerID = provider.id
        self.provider = provider
        self.todaySpent = todaySpent
        self.checkinDone = checkinDone
        self.checkinStreak = checkinStreak
        self.costText = costText
        self.onConfigure = onConfigure
        self.onCheckin = onCheckin
        self.onStatus = onStatus
        self.animateValue = animateValue
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let style = ProviderStyles.style(for: provider.id)
        detail.orientation = .vertical
        detail.alignment = .width
        detail.spacing = 6
        detail.wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.design == .glass ? 9 : 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Theme.design == .glass ? -6 : 0),
        ])

        let ledger = Theme.design == .claude
        let badge = ProviderMarkView(provider: provider.id, size: ledger ? 21 : 24)

        let name = label(style.shortName, size: 15, weight: .semibold)
        let statusDot = StatusDotView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.color = provider.cached == true ? Theme.tertiary : provider.connection.color
        statusDot.toolTip = provider.cacheDescription ?? (provider.connection == .online
            ? "已连接"
            : (provider.error ?? provider.detail ?? provider.connection.title))
        statusDot.setAccessibilityElement(true)
        statusDot.setAccessibilityRole(.image)
        statusDot.setAccessibilityLabel(statusDot.toolTip)
        let nameRow = NSStackView(views: [name, statusDot])
        nameRow.orientation = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .centerY
        if let plan = provider.displayPlan {
            nameRow.addArrangedSubview(label(plan, size: 10, color: Theme.tertiary))
        }
        if provider.id == "trae" || provider.id == "workbuddy" || provider.id == "doubao" {
            if checkinDone {
                let badge = CheckinBadgeView()
                badge.toolTip = "今日已签到"
                badge.setAccessibilityLabel("今日已签到")
                nameRow.addArrangedSubview(badge)
            } else if CheckinService.result(for: provider.id, in: ConfigStore()) == "签到失败" {
                let failed = label("签到失败", size: 10, weight: .medium, color: Theme.danger)
                failed.toolTip = "签到请求已执行，但服务端没有返回成功；可在设置 → 运行与签到查看原因"
                failed.setAccessibilityLabel("签到失败")
                nameRow.addArrangedSubview(failed)
            } else if CheckinService.result(for: provider.id, in: ConfigStore()) == "无签到" {
                let inactive = label("无签到", size: 10, color: Theme.tertiary)
                inactive.toolTip = "工作/企业账号没有每日签到；个人账号才有"
                inactive.setAccessibilityLabel("无每日签到")
                nameRow.addArrangedSubview(inactive)
            }
        }
        if let serviceStatus = provider.serviceStatus, serviceStatus != "ok" {
            let title = serviceStatus == "outage" ? "官方故障" : "官方降级"
            if QuotaPopoverViewController.serviceStatusURL(provider.id) != nil {
                let statusButton = NSButton(
                    title: title + " ↗",
                    target: self,
                    action: #selector(statusTapped)
                )
                statusButton.isBordered = false
                statusButton.font = .systemFont(ofSize: 10, weight: .medium)
                statusButton.contentTintColor = serviceStatus == "outage" ? Theme.danger : Theme.warning
                statusButton.toolTip = provider.serviceStatusDescription
                statusButton.setAccessibilityLabel("查看 \(style.shortName) 官方服务状态")
                nameRow.addArrangedSubview(statusButton)
            } else {
                let status = label(title, size: 10, weight: .medium,
                                   color: serviceStatus == "outage" ? Theme.danger : Theme.warning)
                status.toolTip = provider.serviceStatusDescription
                nameRow.addArrangedSubview(status)
            }
        }
        if provider.status == "warn" && isExhausted(provider) {
            nameRow.addArrangedSubview(label("已用尽", size: 10, weight: .medium, color: Theme.danger))
        }
        if provider.status == "error" {
            nameRow.addArrangedSubview(label("出错", size: 10, weight: .medium, color: Theme.danger))
        }
        if provider.status == "unconfigured" {
            nameRow.addArrangedSubview(label("待配置", size: 10, weight: .medium, color: Theme.warning))
        }

        let subText = provider.quotaSubtitle
        let headline = provider.metrics.first { $0.label == preferredWindow && $0.kind == "percent" && $0.remainingPercent != nil } ?? provider.primaryMetric
        let ink = headline?.remainingPercent.map { $0 > QuotaStyle.warningPercent ? Theme.text : QuotaSeverity.from(remaining: $0).color } ?? valueColor(provider)
        let value = label(headline.map(provider.valueText) ?? provider.displayPrimaryValue, size: ledger ? 25 : 22, weight: .semibold, color: ink, monospaced: true)
        value.alignment = .right
        value.identifier = NSUserInterfaceItemIdentifier("primary-quota")
        if ledger { value.font = NSFont(name: "Georgia", size: 26) ?? value.font }
        primaryValueLabel = value
        pendingValueSettle = animateValue

        let valueRow = NSStackView()
        valueRow.orientation = .horizontal
        valueRow.alignment = .firstBaseline
        valueRow.spacing = 4
        valueRow.addArrangedSubview(value)
        if let window = headline, window.kind == "percent" {
            valueRow.insertArrangedSubview(label(window.label + "剩余", size: 11, color: Theme.secondary), at: 0)
        }
        let body = NSStackView(views: [nameRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2
        if !subText.isEmpty {
            let subtitle = label(subText, size: 11, color: Theme.secondary)
            subtitle.toolTip = subText
            subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.addArrangedSubview(subtitle)
        }

        var captions: [String] = []
        if headline?.kind != "percent", let unit = provider.unitSuffix { captions.append(unit) }
        if let headline, headline.kind == "percent", let reset = headline.detail, !reset.isEmpty { captions.append(reset) }
        if let spent = valueCaption(provider, todaySpent: todaySpent) { captions.append(spent) }
        else if provider.id == "deepseek", let detail = compactDetail(provider.creditMetric?.detail ?? provider.metrics.first(where: { $0.kind == "text" })?.detail) {
            captions.append(detail)
        }

        toggleButton.isBordered = false
        toggleButton.title = ""
        toggleButton.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        toggleButton.setAccessibilityLabel((expanded ? "收起 " : "展开 ") + style.shortName)
        toggleButton.setAccessibilityExpanded(expanded)
        toggleButton.identifier = NSUserInterfaceItemIdentifier("toggle-" + provider.id)
        toggleButton.target = self
        toggleButton.action = #selector(toggleDetails)
        toggleButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggleButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let canExpand = provider.hasExpandableWindows
        toggleButton.contentTintColor = Theme.accent
        let header = summaryHeader
        let metricColumn = NSStackView(views: [valueRow])
        metricColumn.orientation = .vertical
        metricColumn.alignment = .trailing
        metricColumn.spacing = 1
        if !captions.isEmpty {
            metricColumn.addArrangedSubview(label(captions.joined(separator: " · "), size: 11, color: Theme.secondary))
        }
        let rightInset: CGFloat = 28
        for child in [badge as NSView, body, metricColumn] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            body.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            body.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            body.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor, constant: 3)
        ])
        NSLayoutConstraint.activate([
            metricColumn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -rightInset),
            captions.isEmpty
                ? metricColumn.centerYAnchor.constraint(equalTo: header.centerYAnchor)
                : metricColumn.topAnchor.constraint(equalTo: header.topAnchor, constant: 3),
            metricColumn.leadingAnchor.constraint(greaterThanOrEqualTo: body.trailingAnchor, constant: 6),
            header.heightAnchor.constraint(greaterThanOrEqualTo: metricColumn.heightAnchor, constant: 6)
        ])
        if canExpand {
            header.addSubview(toggleButton)
            toggleButton.translatesAutoresizingMaskIntoConstraints = false
            toggleButton.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
            toggleButton.centerYAnchor.constraint(equalTo: name.centerYAnchor).isActive = true
            let click = NSClickGestureRecognizer(target: self, action: #selector(toggleDetails))
            click.delegate = self
            header.addGestureRecognizer(click)
        }
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 可选成本行（如 OpenCode）；数据来自 ProviderStatus 的嵌套 cost，缺省不占位。
        let hasCostLine = !(costText?.isEmpty ?? true)
        if canExpand, let costText, hasCostLine {
            let cost = label(costText, size: 10, color: Theme.tertiary)
            cost.lineBreakMode = .byTruncatingTail
            cost.setAccessibilityLabel("成本")
            detail.addArrangedSubview(cost)
        }

        var percentMetrics = provider.metrics.filter { $0.kind == "percent" && $0.remainingPercent != nil }
        if let headline, let index = percentMetrics.firstIndex(where: { $0.id == headline.id }), index != 0 {
            percentMetrics.insert(percentMetrics.remove(at: index), at: 0)
        }
        if let limiting = provider.riskMetric, limiting.id != headline?.id, provider.riskTier <= 1 {
            let warning = label(provider.riskDescription, size: 12, color: Theme.danger)
            collapsedWarning = warning
            stack.addArrangedSubview(warning)
        }
        if canExpand, let credit = provider.creditMetric {
            let title = credit.currency?.isEmpty == false ? "账户余额" : "剩余积分"
            let caption = compactDetail(credit.detail) ?? provider.connection.title
            detail.addArrangedSubview(label(title + " · " + caption, size: 13, color: Theme.secondary))
            if headline?.id != credit.id { detail.addArrangedSubview(label(provider.valueText(credit) + (credit.currency?.isEmpty == false ? "" : " 积分"), size: 14)) }
        }
        for metric in canExpand ? percentMetrics : [] where metric.id != headline?.id {
            guard let remaining = metric.remainingPercent else { continue }
            let title = label(metric.label, size: 12, weight: .semibold)
            let reset = label(metric.detail ?? "", size: 11, color: Theme.secondary)
            reset.lineBreakMode = .byTruncatingTail
            let figureText = "剩 " + quotaPercentText(remaining) + "%"
            let figure = label(figureText, size: 13, weight: .semibold, monospaced: true)
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
            let meta = NSStackView(views: [title, reset, NSView(), figure])
            meta.alignment = .firstBaseline
            meta.spacing = 6
            let color = remaining <= QuotaStyle.warningPercent ? QuotaSeverity.from(remaining: remaining).color : QuotaStyle.healthyColor
            let bar = BarView(progress: remaining / 100, color: color)
            bar.setAccessibilityLabel(metric.label + "剩余额度")
            let period = NSStackView(views: [meta, bar])
            period.orientation = .vertical
            period.alignment = .width
            period.spacing = 4
            period.edgeInsets = NSEdgeInsets(top: 0, left: ledger ? 0 : 33, bottom: 3, right: rightInset)
            detail.addArrangedSubview(period)
            bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        }

        if canExpand {
            for metric in provider.metrics where metric.kind == "text" {
                let line = NSStackView(views: [
                    label(metric.label, size: 12, weight: .semibold),
                    NSView(),
                    label(provider.valueText(metric) + (metric.detail.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""), size: 12, color: Theme.secondary)
                ])
                line.orientation = .horizontal
                line.alignment = .firstBaseline
                line.spacing = 6
                line.edgeInsets = NSEdgeInsets(top: 0, left: ledger ? 0 : 33, bottom: 3, right: rightInset)
                detail.addArrangedSubview(line)
            }
        }

        if canExpand, !["deepseek", "trae", "workbuddy"].contains(provider.id),
           let supporting = compactDetail(
                    provider.metrics.first(where: { $0.kind == "credit" })?.detail
                    ?? provider.metrics.first(where: { $0.kind == "text" })?.detail
                  ) {
            let detailLabel = label(supporting, size: 10, color: Theme.tertiary)
            detailLabel.lineBreakMode = .byTruncatingTail
            detail.addArrangedSubview(detailLabel)
        }

        setExpanded(expanded, animated: false)

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
                color: provider.status == "error" ? Theme.warning : Theme.secondary,
                width: 310
            )
            actionRow.addArrangedSubview(messageLabel)
            let actionSpacer = NSView()
            actionSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            actionRow.addArrangedSubview(actionSpacer)
            if ProviderRegistry.provider(withID: provider.id)?.supportsMultipleAccounts == true {
                actionRow.addArrangedSubview(ClosureButton(title: "配置", onTap: onConfigure))
            } else if provider.id == "doubao", provider.error?.contains("屏幕录制") == true {
                actionRow.addArrangedSubview(ClosureButton(title: "读取权限…", onTap: DoubaoQuota.openPermissions))
                actionRow.addArrangedSubview(ClosureButton(title: "重启 App", onTap: DoubaoQuota.relaunch))
            }
            stack.addArrangedSubview(actionRow)
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -54).isActive = true
        }

        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10).isActive = true

        layer?.cornerRadius = Theme.design == .glass ? 12 : 0
        applyBackground()
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

    func showDetailRange(_ range: Range<Int>?) {
        for (index, item) in detail.arrangedSubviews.enumerated() {
            item.isHidden = range.map { !$0.contains(index) } ?? false
        }
    }

    func detailPages(availableHeight: CGFloat, rowHeight: CGFloat) -> [Range<Int>]? {
        let items = detail.arrangedSubviews
        guard isExpanded, items.count > 1 else { return nil }
        let room = availableHeight - (rowHeight - detail.fittingSize.height)
        var start = 0
        var used: CGFloat = 0
        var parts: [Range<Int>] = []
        for (i, item) in items.enumerated() {
            let height = ceil(item.fittingSize.height)
            if i > start && used + detail.spacing + height > room {
                parts.append(start..<i)
                start = i
                used = 0
            }
            used += (i == start ? 0 : detail.spacing) + height
        }
        parts.append(start..<items.count)
        return parts
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard pendingValueSettle, window != nil, let value = primaryValueLabel else { return }
        pendingValueSettle = false
        DispatchQueue.main.async { [weak self, weak value] in
            guard let self, self.window != nil, let value, value.superview != nil else { return }
            QuotaMotion.settle(value, duration: QuotaMotion.feedback)
        }
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded, provider.hasExpandableWindows else { return }
        isExpanded = expanded
        toggleButton.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        toggleButton.setAccessibilityLabel((expanded ? "收起 " : "展开 ") + ProviderStyles.style(for: providerID).shortName)
        collapsedWarning?.isHidden = expanded
        toggleButton.setAccessibilityExpanded(expanded)
        if expanded {
            detail.alphaValue = 1
            stack.insertArrangedSubview(detail, at: 1)
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if animated { QuotaMotion.reveal(detail, duration: QuotaMotion.standard, offset: 3) }
        } else {
            // Collapse is an exit: remove immediately so the next layout is
            // deterministic; the chevron and the disappearing detail are
            // enough feedback, and this avoids a stale row blocking a re-tap.
            detail.layer?.removeAllAnimations()
            detail.removeFromSuperview()
            detail.alphaValue = 1
        }
    }

    @objc private func toggleDetails() { onToggle() }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let header = gestureRecognizer.view else { return false }
        var hit = header.hitTest(header.superview?.convert(event.locationInWindow, from: nil) ?? .zero)
        while let view = hit, view !== header {
            if view is NSButton { return false }
            hit = view.superview
        }
        return true
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
            color = Theme.hover
        } else {
            color = Theme.design == .glass ? Theme.surface : .clear
        }
        layer?.backgroundColor = color.resolvedCGColor()
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
        provider.riskScore == 0
    }

    private func errorSummary(for provider: ProviderStatus) -> String {
        ProviderErrorText.summary(provider.error)
    }

    private func errorHint(for provider: ProviderStatus) -> String {
        if ProviderRegistry.provider(withID: provider.id)?.supportsMultipleAccounts == false,
           let reason = provider.error { return reason }
        return ProviderErrorText.hint(for: errorSummary(for: provider))
    }

    private func valueCaption(_ provider: ProviderStatus, todaySpent: Double?) -> String? {
        guard provider.metrics.contains(where: { $0.kind == "credit" }),
              let spent = todaySpent, spent > 0.0001 else { return nil }
        if case .currency = provider.unit {
            return String(format: "今日 -%@%.2f", provider.currencySymbol, spent)
        }
        return "今日 -\(Int(spent.rounded()))"
    }

    private func valueColor(_ provider: ProviderStatus) -> NSColor {
        if provider.status == "error" { return Theme.text }
        if let remaining = provider.primaryMetric?.remainingPercent {
            return QuotaSeverity.from(remaining: remaining).color
        }
        if let creditColor = QuotaStyle.creditColor(for: provider) {
            return creditColor
        }
        return Theme.text
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
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("剩余额度")
        setAccessibilityValue(NSNumber(value: Double(self.progress * 100)))
        setAccessibilityValueDescription(quotaPercentText(Double(self.progress * 100)) + "%")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.text.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let width = bounds.width * progress
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: 2, yRadius: 2
        ).fill()
    }
}


final class HeaderIconButton: NSButton {
    var hintText = ""
    var onHover: ((HeaderIconButton?) -> Void)?
    var symbolName: String {
        didSet { applySymbol() }
    }

    init(symbol: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        applySymbol()
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.55 }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applySymbol() {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let description = accessibilityLabel() ?? toolTip
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        contentTintColor = Theme.accent
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
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(self)
        layer?.backgroundColor = Theme.hover.resolvedCGColor()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
        layer?.backgroundColor = NSColor.clear.cgColor
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
