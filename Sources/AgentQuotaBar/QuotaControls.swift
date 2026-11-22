import AppKit

/// Scrub Field：阈值用“拖动数字 + 点击输入”，不再用系统滑块。
/// 原生 AppKit 实现，只借 ReactBits Scrub Field 的交互，不嵌入 Web。
final class ScrubValueField: NSView, NSTextFieldDelegate {
    var minValue: Double = 1
    var maxValue: Double = 99
    var step: Double = 1
    var suffix: String = "%"
    var onChange: ((Double) -> Void)?
    var onInvalidInput: (() -> Void)?

    var value: Double = 45 {
        didSet {
            value = min(maxValue, max(minValue, value))
            needsDisplay = true
            setAccessibilityValue(NSNumber(value: value))
            setAccessibilityValueDescription(displayNumber + suffix)
        }
    }

    private var startX: CGFloat = 0
    private var startValue: Double = 0
    private var moved = false
    private var editor: NSTextField?
    private var displayNumber: String { value == value.rounded() ? String(Int(value)) : String(value) }

    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 28) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue(NSNumber(value: value))
        setAccessibilityValueDescription(displayNumber + suffix)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = Theme.surfaceAlt.resolvedForAppearance()
        let focused = editor != nil || window?.firstResponder === self
        let border = (focused ? Theme.accent : Theme.separator).resolvedForAppearance()
        bg.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        border.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        path.lineWidth = focused ? 2 : 1
        path.stroke()

        guard editor == nil else { return }
        let text = displayNumber + suffix
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Theme.text.resolvedForAppearance(),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func accessibilityPerformIncrement() -> Bool { value += step; onChange?(value); return true }
    override func accessibilityPerformDecrement() -> Bool { value -= step; onChange?(value); return true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: _ = accessibilityPerformDecrement()
        case 124, 126: _ = accessibilityPerformIncrement()
        case 36, 49: beginEditing()
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startX = event.locationInWindow.x
        startValue = value
        moved = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - startX
        guard abs(dx) > 2 else { return }
        moved = true
        let units = Double(dx / 6)
        let newValue = (startValue + units * step).rounded()
        if newValue != value {
            value = newValue
            onChange?(value)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !moved { beginEditing() }
    }

    private func beginEditing() {
        guard editor == nil else { return }
        let field = NSTextField(frame: bounds.insetBy(dx: 4, dy: 3))
        field.stringValue = displayNumber
        field.setAccessibilityLabel(accessibilityLabel())
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(commitEditor)
        addSubview(field)
        editor = field
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func commitEditor() {
        guard let editor else { return }
        let parsed = Double(editor.stringValue)
        self.editor = nil
        editor.removeFromSuperview()
        needsDisplay = true
        guard let parsed, parsed.isFinite, (minValue...maxValue).contains(parsed) else { onInvalidInput?(); return }
        value = parsed
        onChange?(value)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditor()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = editor, let window else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            editor = nil
            window.makeFirstResponder(self)
            field.removeFromSuperview()
            needsDisplay = true
        case #selector(NSResponder.insertNewline(_:)):
            commitEditor()
            window.makeFirstResponder(self)
        case #selector(NSResponder.insertTab(_:)):
            commitEditor()
            window.selectKeyView(following: self)
        case #selector(NSResponder.insertBacktab(_:)):
            commitEditor()
            window.selectKeyView(preceding: self)
        default: return false
        }
        return true
    }
}

final class SettingsPopUpButton: NSPopUpButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshDesign()
    }

    func refreshDesign() {
        isBordered = Theme.design != .claude
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard Theme.design == .claude else { return }
        (isEnabled ? Theme.secondary : NSColor.disabledControlTextColor).setFill()
        let y = isFlipped ? bounds.maxY - 1 : bounds.minY
        NSBezierPath(rect: NSRect(x: 1, y: y, width: max(0, bounds.width - 2), height: 1)).fill()
    }
}

final class GlidePopUpButton: NSPopUpButton {
    private let chevron = PassthroughImageView()
    private let border = PopupBorderView()

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        style()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        style()
    }

    private func style() {
        // 原生 bezel 先保证可点击区域的边界可见；自定义 chevron 只作为辅助。
        isBordered = true
        bezelStyle = .rounded
        focusRingType = .none
        controlSize = .large
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .medium)
        chevron.isHidden = true
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = Theme.secondary
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        border.isHidden = true
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.surface.resolvedForAppearance().cgColor
        layer?.borderWidth = 0
        chevron.contentTintColor = Theme.secondary.resolvedForAppearance()
        chevron.needsDisplay = true
        border.needsDisplay = true
    }
}

final class PopupBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.separator.withAlphaComponent(0.5).resolvedForAppearance().setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Status Mark：环 → 进度弧 → 勾 / 断环。用于权限与连接状态。
final class StatusMarkView: NSView {
    enum State { case idle, authorized, denied, working }

    var state: State = .idle {
        didSet { needsDisplay = true; setAccessibilityValue(accessibilityText) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("状态")
    }

    required init?(coder: NSCoder) { fatalError() }

    var ink: NSColor {
        switch state {
        case .idle: return Theme.tertiary
        case .authorized: return Theme.success
        case .denied: return Theme.warning
        case .working: return Theme.accent
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        ink.resolvedForAppearance().setStroke()
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 1.5
        ring.stroke()

        if state == .authorized {
            let check = NSBezierPath()
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.move(to: NSPoint(x: rect.minX + 3.2, y: rect.midY))
            check.line(to: NSPoint(x: rect.midX - 0.5, y: rect.minY + 3.2))
            check.line(to: NSPoint(x: rect.maxX - 2.8, y: rect.maxY - 3.8))
            check.stroke()
        } else if state == .denied {
            let x = NSBezierPath()
            x.lineWidth = 1.7
            x.lineCapStyle = .round
            x.move(to: NSPoint(x: rect.minX + 3.7, y: rect.minY + 3.7))
            x.line(to: NSPoint(x: rect.maxX - 3.7, y: rect.maxY - 3.7))
            x.move(to: NSPoint(x: rect.maxX - 3.7, y: rect.minY + 3.7))
            x.line(to: NSPoint(x: rect.minX + 3.7, y: rect.maxY - 3.7))
            x.stroke()
        }
    }

    private var accessibilityText: String {
        switch state {
        case .idle: return "未设置"
        case .authorized: return "已授权"
        case .denied: return "未授权"
        case .working: return "处理中"
        }
    }
}

// MARK: - Glide Select / custom text field

final class QuotaTextField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 30)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureField()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureField()
    }

    private func configureField() {
        isBordered = true
        bezelStyle = .roundedBezel
        controlSize = .large
        focusRingType = .none
        font = .systemFont(ofSize: 14)
        isEditable = true
        isSelectable = true
        isEnabled = true
        wantsLayer = true
        refreshDesign()
    }

    private let rule = CALayer()

    func refreshDesign() {
        let paper = Theme.design == .claude
        if isBezeled == paper { isBezeled = !paper }
        if paper && isBordered { isBordered = false }
        drawsBackground = !paper
        if rule.superlayer == nil { layer?.addSublayer(rule) }
        rule.isHidden = !paper
        layer?.cornerRadius = paper ? 0 : 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateFocus(currentEditor() != nil || window?.firstResponder === self)
    }

    private func updateFocus(_ focused: Bool) {
        let paper = Theme.design == .claude
        rule.backgroundColor = (focused ? Theme.accent : Theme.secondary).resolvedCGColor()
        layer?.borderWidth = paper ? 0 : (focused ? 1.5 : 1)
        layer?.borderColor = (focused ? Theme.accent : Theme.separator.withAlphaComponent(0.55)).resolvedCGColor()
    }

    override func layout() {
        super.layout()
        rule.frame = CGRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { updateFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { updateFocus(false) }
        return ok
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDesign()
    }
}
