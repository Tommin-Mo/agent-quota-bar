import AppKit

/// Scrub Field：阈值用“拖动数字 + 点击输入”，不再用系统滑块。
/// 原生 AppKit 实现，只借 ReactBits Scrub Field 的交互，不嵌入 Web。
final class ScrubValueField: NSView, NSTextFieldDelegate {
    var minValue: Double = 1
    var maxValue: Double = 99
    var step: Double = 1
    var suffix: String = "%"
    var onChange: ((Double) -> Void)?

    var value: Double = 45 {
        didSet {
            value = min(maxValue, max(minValue, value))
            needsDisplay = true
            setAccessibilityValue("\(Int(value.rounded()))\(suffix)")
        }
    }

    private var startX: CGFloat = 0
    private var startValue: Double = 0
    private var moved = false
    private var editor: NSTextField?

    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 28) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue("\(Int(value))\(suffix)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = Theme.surfaceAlt.resolvedForAppearance()
        let border = Theme.separator.withAlphaComponent(0.45).resolvedForAppearance()
        bg.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        border.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        path.lineWidth = 1
        path.stroke()

        let text = "\(Int(value.rounded()))\(suffix)"
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
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
        field.stringValue = "\(Int(value.rounded()))"
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
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func commitEditor() {
        guard let editor else { return }
        let parsed = Double(editor.stringValue.filter { $0.isNumber || $0 == "." }) ?? value
        self.editor = nil
        editor.removeFromSuperview()
        value = parsed
        onChange?(value)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditor()
    }
}

/// Wake Slider（去掉 wake 动效）：细条轨道 + 无圆点把手，圆环只负责连续范围。
final class WakeSlider: NSView {
    var minValue: Double = 0.8
    var maxValue: Double = 1.6
    var onChange: ((Double) -> Void)?

    var value: Double = 1.25 {
        didSet {
            value = min(maxValue, max(minValue, value))
            needsDisplay = true
            setAccessibilityValue("\(Int((value * 100).rounded()))%")
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 24) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue("\(Int((value * 100).rounded()))%")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 2, y: bounds.midY - 2, width: bounds.width - 4, height: 4)
        Theme.surfaceAlt.resolvedForAppearance().setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let range = maxValue - minValue
        let fraction = range > 0 ? (value - minValue) / range : 0
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(fraction), height: track.height)
        Theme.accent.resolvedForAppearance().setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()

        // 无圆点：用一条 2pt 的竖线标出当前位置。
        let headX = track.minX + track.width * CGFloat(fraction)
        let head = NSRect(x: headX - 1, y: track.midY - 7, width: 2, height: 14)
        Theme.accent.resolvedForAppearance().setFill()
        NSBezierPath(roundedRect: head, xRadius: 1, yRadius: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        updateValue(at: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(at: event)
    }

    private func updateValue(at event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let fraction = min(1, max(0, x / max(1, bounds.width)))
        let newValue = minValue + Double(fraction) * (maxValue - minValue)
        if abs(newValue - value) > 0.001 {
            value = newValue
            onChange?(value)
        }
    }
}

/// 自定义下拉触发器：去掉系统蓝色 bezel，保留原生菜单行为。
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

    private func applyColors() {
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

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let color: NSColor
        switch state {
        case .idle: color = Theme.tertiary
        case .authorized: color = Theme.success
        case .denied: color = Theme.danger
        case .working: color = Theme.accent
        }
        color.setStroke()
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
