import AppKit
import WebKit

/// 内置浏览器登录：登录完成后自动抓取 token / cookie，省掉 F12 和手动复制。
final class WebLoginWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    enum Kind {
        case workbuddy
        case opencode
    }

    private let kind: Kind
    private let service: QuotaService
    private let onCredential: (String, String?) -> Void
    var onClose: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var captured = false
    private var rejectedToken: String?
    private var startedAt = Date()

    init(kind: Kind, service: QuotaService, onCredential: @escaping (String, String?) -> Void) {
        self.kind = kind
        self.service = service
        self.onCredential = onCredential

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = kind == .workbuddy ? "登录 WorkBuddy（个人版）" : "登录 OpenCode"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 界面

    private func buildContent() {
        guard let window else { return }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: kind == .workbuddy ? "登录 WorkBuddy（个人版）" : "登录 OpenCode")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "登录后自动关闭。"

        let titles = NSStackView(views: [title, statusLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let header = NSStackView(views: [titles, spinner])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let openBrowser = NSButton(title: "用默认浏览器打开", target: self, action: #selector(openInBrowser))
        openBrowser.bezelStyle = .inline
        openBrowser.isBordered = false
        openBrowser.font = .systemFont(ofSize: 10.5)
        openBrowser.contentTintColor = .secondaryLabelColor

        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let footer = NSStackView(views: [openBrowser, footerSpacer, close])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(separator)
        container.addSubview(webView)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])

        window.contentView = container

        let urlString = kind == .workbuddy
            ? "https://www.workbuddy.cn/login/"
            : "https://opencode.ai/auth"
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        spinner.startAnimation(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 登录完成检测

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startPolling()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel.stringValue = "页面加载失败：\(error.localizedDescription)"
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        startedAt = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func probe() {
        guard !captured, let webView else { return }
        if Date().timeIntervalSince(startedAt) > 300 {
            pollTimer?.invalidate()
            statusLabel.stringValue = "等待登录超时，请重新打开登录窗口。"
            return
        }

        switch kind {
        case .workbuddy:
            probeWorkBuddy(webView)
        case .opencode:
            probeOpenCode(webView)
        }
    }

    private func probeWorkBuddy(_ webView: WKWebView) {
        let script = """
        (() => {
          const out = {};
          const stores = [['l', window.localStorage], ['s', window.sessionStorage]];
          for (const [tag, store] of stores) {
            try {
              for (let i = 0; i < store.length; i++) {
                const k = store.key(i);
                const v = store.getItem(k) || '';
                if (/token|uid|userid|uin|account/i.test(k) || v.startsWith('eyJ')) {
                  out[tag + ':' + k] = v;
                }
              }
            } catch (e) {}
          }
          return JSON.stringify(out);
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let text = result as? String, !text.isEmpty else { return }
            guard let token = Self.extractToken(from: text), token != self.rejectedToken else { return }
            let uid = Self.extractUID(from: text)
            self.capture(credential: token, secondary: uid)
        }
    }

    private func probeOpenCode(_ webView: WKWebView) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let session = cookies.first {
                $0.name == "__Host-console_session" && $0.domain.contains("opencode.ai")
            }
            let legacy = cookies.first {
                $0.name == "auth" && $0.domain.contains("opencode.ai")
            }
            guard let cookie = session ?? legacy else { return }

            let script = """
            fetch('/console/api/orgs', {credentials: 'include'})
              .then(r => r.json())
              .then(j => JSON.stringify(j))
              .catch(() => '');
            """
            webView.evaluateJavaScript(script) { result, _ in
                var workspace = ""
                if let text = result as? String,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    workspace = Self.firstOrgID(from: object)
                }
                self.capture(credential: cookie.value, secondary: workspace)
            }
        }
    }

    private func capture(credential: String, secondary: String?) {
        guard !captured else { return }
        captured = true
        pollTimer?.invalidate()
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "已获取凭证，正在验证…"

        let config = service.config
        switch kind {
        case .workbuddy:
            config.set("providers.workbuddy.token", credential)
            if let secondary, !secondary.isEmpty {
                config.set("providers.workbuddy.uid", secondary)
            }
        case .opencode:
            config.set("providers.opencode.cookie", credential)
            config.set("providers.opencode.workspaceId", secondary ?? "")
            config.set("providers.opencode.mode", "zen")
        }
        try? config.save()

        let provider = kind == .workbuddy ? "workbuddy" : "opencode"
        service.verify(provider: provider) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let status):
                if status.status == "ok" || status.status == "warn" {
                    self.statusLabel.stringValue = "✓ 已验证：\(status.headline ?? status.detail ?? "已连接")，窗口即将关闭"
                    self.statusLabel.textColor = .systemGreen
                    self.onCredential(credential, secondary)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        self.close()
                    }
                } else {
                    self.statusLabel.stringValue = "✗ \(status.error ?? status.detail ?? "验证失败")，请确认已登录后重试"
                    self.statusLabel.textColor = .systemRed
                    self.captured = false
                    self.rejectedToken = credential
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.startPolling()
                }
            case .failure(let error):
                self.statusLabel.stringValue = "✗ \(error.localizedDescription)"
                self.statusLabel.textColor = .systemRed
            }
        }
    }

    // MARK: - 解析

    private static func extractToken(from jsonText: String) -> String? {
        guard let data = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        var direct: [String] = []
        var nested: [String] = []
        for (_, value) in dict {
            if value.hasPrefix("eyJ"), value.count > 80, value.filter({ $0 == "." }).count >= 2 {
                direct.append(value)
            }
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, item) in object where key.lowercased().contains("token") {
                    if let string = item as? String, string.count > 40 {
                        nested.append(string)
                    }
                }
            }
        }
        return (nested + direct).max(by: { $0.count < $1.count })
    }

    private static func extractUID(from jsonText: String) -> String? {
        guard let data = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        for (key, value) in dict {
            let lower = key.lowercased()
            if (lower.contains("uid") || lower.contains("userid") || lower.contains("uin")),
               !value.contains("eyJ"), value.count < 40, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstOrgID(from object: Any) -> String {
        if let dict = object as? [String: Any] {
            if let id = dict["id"] as? String { return id }
            if let data = dict["data"] as? [Any] {
                for item in data {
                    if let dict = item as? [String: Any],
                       let id = (dict["id"] as? String) ?? (dict["orgId"] as? String) {
                        return id
                    }
                }
            }
            for value in dict.values {
                let found = firstOrgID(from: value)
                if !found.isEmpty { return found }
            }
        }
        if let array = object as? [Any] {
            for item in array {
                let found = firstOrgID(from: item)
                if !found.isEmpty { return found }
            }
        }
        return ""
    }

    // MARK: - 动作

    @objc private func openInBrowser() {
        let urlString = kind == .workbuddy ? "https://www.workbuddy.cn/login/" : "https://opencode.ai/auth"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    @objc private func closeWindow() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        onClose?()
    }
}
