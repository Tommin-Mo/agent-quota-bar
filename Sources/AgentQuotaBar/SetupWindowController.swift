import AppKit

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let providerID: String
    private let service: QuotaService
    private let onSaved: () -> Void
    var onClose: (() -> Void)?

    private var fields: [String: NSTextField] = [:]
    private var loginWindows: [WebLoginWindowController] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton()
    private let container = NSView()
    private let stack = NSStackView()
    private var segmented: NSSegmentedControl?
    private var goGroup: NSView?
    private var zenGroup: NSView?
    private var manualGroup: NSView?
    private var manualToggle: NSButton?
    private var traePopup: NSPopUpButton?
    private var startZen = false

    private var style: ProviderStyle { ProviderStyles.style(for: providerID) }

    private let openURLs: [String: String] = [
        "deepseek": "https://platform.deepseek.com/api_keys",
        "opencode": "https://opencode.ai/auth",
        "workbuddy": "https://www.workbuddy.cn/login/",
        "codex": "https://chatgpt.com/",
        "trae": "https://www.trae.cn/",
    ]

    init(provider: String, service: QuotaService, onSaved: @escaping () -> Void) {
        self.providerID = provider
        self.service = service
        self.onSaved = onSaved
        self.startZen = service.config.string("providers.opencode.mode", default: "go") == "zen"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "配置 \(ProviderStyles.style(for: provider).shortName)"
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .white
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.contentView = container
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 构建

    private func buildContent() {
        container.frame = NSRect(x: 0, y: 0, width: 560, height: 520)

        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.background.resolvedCGColor()

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])

        stack.addArrangedSubview(header())

        if isAutomaticProvider {
            let info = infoCard()
            stack.addArrangedSubview(info)
            info.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            let action = actionPanel()
            stack.addArrangedSubview(action)
            action.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let fields = fieldsCard()
            stack.addArrangedSubview(fields)
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let foot = footer()
        stack.addArrangedSubview(foot)
        foot.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        container.layoutSubtreeIfNeeded()
        resizeWindowToFit()
    }

    private var isAutomaticProvider: Bool {
        providerID == "codex" || providerID == "trae" || providerID == "workbuddy"
    }

    private func header() -> NSView {
        let badge = AvatarView(letter: style.letter, color: style.color, size: 36, provider: providerID)
        let title = label(style.shortName, size: 20, weight: .bold)
        let subtitle = label(headerSubtitle(), size: 11, color: Theme.secondary)
        let info = NSStackView(views: [title, subtitle])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        let row = NSStackView(views: [badge, info])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    private func headerSubtitle() -> String {
        switch providerID {
        case "deepseek": return "API Key · 查询账户余额"
        case "workbuddy": return "积分余额 · 自动读取"
        case "opencode": return "Go 订阅用量，或 Zen 预付余额"
        case "codex": return "自动读取本机 Codex 登录态"
        case "trae": return "自动读取并解密本机 Trae 登录态"
        default: return ""
        }
    }

    private func actionPanel() -> NSView {
        let card = makePaperPanel(cornerRadius: 14)
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .centerX
        panel.spacing = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            panel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            panel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            panel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])

        let desc = wrappingLabel(actionDescription(), size: 11.5, color: Theme.secondary, width: 450)
        desc.alignment = .center
        panel.addArrangedSubview(desc)

        let primary = NSButton(title: primaryActionTitle(), target: self, action: #selector(primaryAction))
        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.bezelColor = Theme.accent
        primary.keyEquivalent = "\r"

        let browser = NSButton(title: "用浏览器打开", target: self, action: #selector(openPage))
        browser.bezelStyle = .inline
        browser.isBordered = false
        browser.contentTintColor = Theme.secondary
        browser.font = .systemFont(ofSize: 11)

        let copy = NSButton(title: "复制步骤", target: self, action: #selector(copySteps))
        copy.bezelStyle = .inline
        copy.isBordered = false
        copy.contentTintColor = Theme.secondary
        copy.font = .systemFont(ofSize: 11)

        let actions = NSStackView(views: providerID == "workbuddy" ? [primary, copy] : [primary, browser, copy])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12
        panel.addArrangedSubview(actions)
        return card
    }

    private func fieldsCard() -> NSView {
        var rows: [NSView] = []

        switch providerID {
        case "deepseek":
            rows.append(fieldGroup(title: "API Key", key: "providers.deepseek.apiKey",
                                   placeholder: "sk-...", secure: true))
        case "opencode":
            let control = NSSegmentedControl(
                labels: ["Go 订阅", "Zen 余额"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(openCodeModeChanged)
            )
            control.selectedSegment = startZen ? 1 : 0
            control.translatesAutoresizingMaskIntoConstraints = false
            rows.append(control)
            segmented = control

            let go = NSStackView()
            go.orientation = .vertical
            go.alignment = .leading
            go.spacing = 12
            go.addArrangedSubview(fieldGroup(title: "Go API Key", key: "providers.opencode.apiKey",
                                             placeholder: "sk-...", secure: true))
            goGroup = go
            go.isHidden = startZen
            rows.append(go)

            let zen = NSStackView()
            zen.orientation = .vertical
            zen.alignment = .leading
            zen.spacing = 12
            zen.addArrangedSubview(fieldGroup(title: "Console Cookie（__Host-console_session）",
                                              key: "providers.opencode.cookie",
                                              placeholder: "登录后自动写入", secure: false))
            zen.addArrangedSubview(fieldGroup(title: "Workspace ID（可选）", key: "providers.opencode.workspaceId",
                                              placeholder: "wrk_...，留空自动获取", secure: false))
            zenGroup = zen
            zen.isHidden = !startZen
            rows.append(zen)
        case "workbuddy":
            let tokenField = fieldGroup(title: "Access Token", key: "providers.workbuddy.token",
                                        placeholder: "eyJ... 或 Bearer eyJ...", secure: true)
            let uidField = fieldGroup(title: "UID（可选）", key: "providers.workbuddy.uid",
                                      placeholder: "留空自动识别", secure: false)
            let steps = wrappingLabel(workbuddyManualSteps(), size: 10.5, color: Theme.tertiary, width: 450)
            return card([tokenField, uidField, steps])
        default:
            break
        }

        return card(rows)
    }

    private func infoCard() -> NSView {
        var rows: [NSView] = []
        let status = label(automaticDescription(), size: 11.5, color: Theme.secondary)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 450
        rows.append(status)

        if providerID == "trae" {
            let popup = NSPopUpButton()
            for (code, title) in [("cn", "Trae CN（国内版）"), ("solo", "TRAE SOLO CN"),
                                  ("sg", "Trae（国际版）"), ("solo-sg", "TRAE SOLO（国际版）")] {
                popup.addItem(withTitle: title)
                popup.lastItem?.representedObject = code
            }
            let current = service.config.string("providers.trae.edition", default: "cn")
            if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
                popup.selectItem(at: index)
            }
            popup.font = .systemFont(ofSize: 12)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
            traePopup = popup
            let row = NSStackView(views: [label("版本", size: 10.5, color: Theme.secondary), popup])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            rows.append(row)
        }

        return card(rows)
    }

    private func footer() -> NSView {
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = Theme.secondary
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isHidden = true

        let paste = NSButton(title: "从剪贴板粘贴", target: self, action: #selector(pasteFromClipboard))
        paste.bezelStyle = .inline
        paste.isBordered = false
        paste.font = .systemFont(ofSize: 10.5)
        paste.contentTintColor = Theme.secondary

        saveButton.title = isAutomaticProvider ? "重新检测" : "保存并验证"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.bezelColor = Theme.accent
        saveButton.target = self
        saveButton.action = #selector(saveAndVerify)

        let buttons = NSStackView(views: isAutomaticProvider ? [saveButton] : [paste, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 16

        let column = NSStackView(views: [statusLabel, buttons])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        return column
    }

    private func fieldGroup(title: String, key: String, placeholder: String, secure: Bool) -> NSView {
        let titleLabel = label(title, size: 10.5, color: Theme.secondary)
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.placeholderString = placeholder
        field.stringValue = service.config.string(key)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        fields[key] = field

        let group = NSStackView(views: [titleLabel, field])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 5
        group.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func card(_ rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.surface.resolvedCGColor()
        box.layer?.cornerRadius = 12
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 14
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return box
    }

    private func resizeWindowToFit() {
        guard let window else { return }
        container.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let height = min(720, max(280, stack.fittingSize.height + 48))
        window.setContentSize(NSSize(width: 560, height: height))
        container.setFrameSize(NSSize(width: 560, height: height))
        container.layoutSubtreeIfNeeded()
    }

    // MARK: - 文案

    private func actionDescription() -> String {
        switch providerID {
        case "deepseek":
            return "在 DeepSeek 开放平台创建一个 API key，粘贴到下方即可查询余额。"
        case "workbuddy":
            return "在 WorkBuddy 中获取 access token 后粘贴到下方。"
        case "opencode":
            return startZen
                ? "Zen 余额：点「登录并自动获取」→ 登录 opencode.ai，自动抓取 __Host-console_session 和 workspaceId。"
                : "Go 订阅：在 opencode.ai 创建 API Key 填到下方；也可以切到 Zen 余额用网页登录自动抓取。"
        default:
            return ""
        }
    }

    private func primaryActionTitle() -> String {
        switch providerID {
        case "deepseek": return "打开 API Keys 页面"
        case "workbuddy": return "打开 WorkBuddy"
        case "opencode": return startZen ? "登录并自动获取" : "打开 opencode.ai"
        default: return "打开页面"
        }
    }

    private func automaticDescription() -> String {
        switch providerID {
        case "codex":
            return "读取本机 Codex 登录态。"
        case "trae":
            return "读取本机 Trae 登录态。"
        case "workbuddy":
            return "读取 WorkBuddy 本机登录态。"
        default:
            return ""
        }
    }

    private func workbuddyManualSteps() -> String {
        """
        在 WorkBuddy 中复制 access token 后粘贴；网页版可在 F12 → 网络（Network）→ 请求头里找到 Authorization。
        """
    }

    // MARK: - 动作

    @objc private func primaryAction() {
        switch providerID {
        case "workbuddy":
            openWorkBuddyApp()
        case "opencode":
            if startZen { startAutoLogin() } else { openPage() }
        default:
            openPage()
        }
    }

    @objc private func startAutoLogin() {
        let kind: WebLoginWindowController.Kind = providerID == "workbuddy" ? .workbuddy : .opencode
        let controller = WebLoginWindowController(kind: kind, service: service) { [weak self] credential, secondary in
            self?.applyCredential(credential, secondary: secondary)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.loginWindows.removeAll { $0 === controller }
        }
        loginWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyCredential(_ credential: String, secondary: String?) {
        if providerID == "workbuddy" {
            fields["providers.workbuddy.token"]?.stringValue = credential
            if let secondary { fields["providers.workbuddy.uid"]?.stringValue = secondary }
        } else {
            fields["providers.opencode.cookie"]?.stringValue = credential
            if let secondary { fields["providers.opencode.workspaceId"]?.stringValue = secondary }
            segmented?.selectedSegment = 1
            openCodeModeChanged()
        }
        showStatus("✓ 已自动获取并保存", color: .systemGreen)
        onSaved()
    }

    private func openWorkBuddyApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.workbuddy.mac") else {
            openPage()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openPage() {
        guard let urlString = openURLs[providerID], let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copySteps() {
        let url = openURLs[providerID] ?? ""
        let text = stepsText() + "\n\n页面：\(url)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showStatus("步骤已复制", color: Theme.secondary)
    }

    private func stepsText() -> String {
        switch providerID {
        case "deepseek":
            return "1. 打开 DeepSeek 开放平台并登录。\n2. API keys → 创建 API key，复制 sk- 开头的字符串。\n3. 粘贴到下方，点「保存并验证」。"
        case "workbuddy":
            return workbuddyManualSteps()
        case "opencode":
            return "Go 订阅：在 opencode.ai 创建 API Key 填入。\nZen 余额：登录 opencode.ai 后点「登录并自动获取」。"
        case "codex":
            return "自动读取 ~/.codex/auth.json；过期后打开 ChatGPT 重登。"
        case "trae":
            return "自动读取本机 Trae 登录态；失败时确认 Trae 已登录或切换版本。"
        default:
            return ""
        }
    }

    @objc private func toggleManual() {
        guard let manualGroup else { return }
        manualGroup.isHidden.toggle()
        manualToggle?.title = manualGroup.isHidden ? "手动填写 Token / 查看 F12 步骤" : "收起手动填写"
        resizeWindowToFit()
    }

    @objc private func pasteFromClipboard() {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        let key: String
        switch providerID {
        case "deepseek": key = "providers.deepseek.apiKey"
        case "workbuddy": key = "providers.workbuddy.token"
        case "opencode":
            key = (segmented?.selectedSegment ?? 0) == 0
                ? "providers.opencode.apiKey"
                : "providers.opencode.cookie"
        default: return
        }
        if providerID == "workbuddy", manualGroup?.isHidden == true {
            manualGroup?.isHidden = false
            manualToggle?.title = "收起手动填写"
            resizeWindowToFit()
        }
        fields[key]?.stringValue = text
        showStatus(text.isEmpty ? "剪贴板是空的" : "已从剪贴板粘贴", color: Theme.secondary)
    }

    @objc private func openCodeModeChanged() {
        let goMode = (segmented?.selectedSegment ?? 0) == 0
        goGroup?.isHidden = !goMode
        zenGroup?.isHidden = goMode
        resizeWindowToFit()
    }

    private func showStatus(_ text: String, color: NSColor) {
        statusLabel.isHidden = false
        statusLabel.stringValue = text
        statusLabel.textColor = color
        resizeWindowToFit()
    }

    @objc private func saveAndVerify() {
        let config = service.config
        for (key, field) in fields {
            config.set(key, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if providerID == "opencode" {
            config.set("providers.opencode.mode", (segmented?.selectedSegment ?? 0) == 0 ? "go" : "zen")
        }
        if providerID == "trae", let popup = traePopup {
            config.set("providers.trae.edition", popup.selectedItem?.representedObject as? String ?? "cn")
        }
        do {
            try config.save()
        } catch {
            showStatus("保存失败：\(error.localizedDescription)", color: .systemRed)
            return
        }

        showStatus("正在验证…", color: Theme.secondary)
        saveButton.isEnabled = false
        service.verify(provider: providerID) { [weak self] result in
            guard let self else { return }
            self.saveButton.isEnabled = true
            switch result {
            case .success(let status):
                if status.status == "ok" || status.status == "warn" {
                    let value = status.headline ?? status.detail ?? "已连接"
                    self.showStatus("✓ 已连接 · \(value)", color: status.status == "warn" ? .systemOrange : .systemGreen)
                    self.onSaved()
                } else {
                    self.showStatus("✗ " + (status.error ?? status.detail ?? "验证失败"), color: .systemRed)
                }
            case .failure(let error):
                self.showStatus("✗ " + error.localizedDescription, color: .systemRed)
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        let currentStatus = service.snapshot?.providers.first(where: { $0.id == providerID })?.status
        _ = currentStatus
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
