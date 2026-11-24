import AppKit
import QuartzCore

/// One motion language for AgentQuotaBar.
///
/// Fast feedback (120 ms), routine state changes (180 ms), spatial/layout
/// transitions (240 ms), exits (100 ms). Movement explains where a thing came
/// from or where it went; opacity is used when no spatial relationship exists.
enum QuotaMotion {
    static let feedback: TimeInterval = 0.12
    static let standard: TimeInterval = 0.18
    static let layout: TimeInterval = 0.24
    static let exit: TimeInterval = 0.10

    /// A confident, natural deceleration; not a bounce and not a linear slide.
    static let enterEase = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let exitEase = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func reveal(_ view: NSView, duration: TimeInterval = standard, offset: CGFloat = 0) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        // Interrupting a page/row/value change should continue from where it
        // is. Removing and re-adding from 0 causes a one-frame flash.
        if layer.animation(forKey: "reveal") != nil, currentOpacity > 0.01 {
            return
        }
        layer.removeAnimation(forKey: "reveal")
        guard !reducesMotion else {
            layer.opacity = 1
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        if offset != 0 {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = offset
            slide.toValue = 0
            group.animations = [fade, slide]
        } else {
            group.animations = [fade]
        }
        group.duration = duration
        group.timingFunction = enterEase
        layer.add(group, forKey: "reveal")
    }

    /// Animate an unhidden view in. The model stays visible even if the
    /// animation is interrupted or Reduce Motion is enabled.
    static func show(_ view: NSView, offset: CGFloat = 3) {
        view.isHidden = false
        view.alphaValue = 1
        reveal(view, duration: standard, offset: offset)
    }

    /// Animate a value/label-only change without moving layout.
    static func settle(_ view: NSView, duration: TimeInterval = feedback) {
        reveal(view, duration: duration, offset: 2)
    }
}

/// A short-lived caption shared by the header icons; it never intercepts a click.
final class HeaderHint: NSView {
    private let text = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private var warmUntil: TimeInterval = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.alignment = .center
        addSubview(text)
        setAccessibilityElement(false)
        text.setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func reset() {
        pending?.cancel()
        pending = nil
        isHidden = true
        warmUntil = 0
    }

    func track(_ button: HeaderIconButton?) {
        pending?.cancel()
        isHidden = true
        guard let button, let root = superview else { return }
        let show = DispatchWorkItem { [weak self, weak button, weak root] in
            guard let self, let button, let root, root.window?.isVisible == true else { return }
            let anchor = button.convert(button.bounds, to: root)
            self.text.stringValue = button.hintText
            self.text.textColor = .labelColor
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                self.layer?.borderColor = NSColor.separatorColor.cgColor
            }
            self.layer?.borderWidth = 1
            let width = ceil(self.text.fittingSize.width) + 14
            self.frame = NSRect(x: min(max(4, anchor.midX - width / 2), root.bounds.width - width - 4),
                                y: anchor.minY - 23, width: width, height: 21).integral
            self.text.frame = self.bounds.insetBy(dx: 4, dy: 3)
            self.isHidden = false
            QuotaMotion.reveal(self, duration: QuotaMotion.feedback, offset: 2)
        }
        pending = show
        let warm = ProcessInfo.processInfo.systemUptime <= warmUntil
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0.04 : 0.45), execute: show)
    }

    override var isHidden: Bool {
        willSet {
            if newValue && !isHidden { warmUntil = ProcessInfo.processInfo.systemUptime + 0.4 }
        }
    }
}

/// The segmented control owns tracking, selection, focus and accessibility in
/// both designs. The paper theme draws its choices on a common writing line.
class ThemeSegments: NSSegmentedControl {
    private var showsKeyboardFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRingType = .none
    }

    func showKeyboardFocus() {
        showsKeyboardFocus = true
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            showsKeyboardFocus = NSApp.currentEvent?.type != .leftMouseDown && NSApp.currentEvent?.type != .leftMouseUp
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showsKeyboardFocus = false; needsDisplay = true }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        showsKeyboardFocus = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        showKeyboardFocus()
        super.keyDown(with: event)
    }

    private func drawKeyboardFocus() {
        guard showsKeyboardFocus, window?.firstResponder === self, window?.isKeyWindow == true else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 2
        Theme.accent.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawKeyboardFocus() }
        guard Theme.design == .claude, segmentCount > 0 else { super.draw(dirtyRect); return }
        let slot = bounds.width / CGFloat(segmentCount)
        let bottom = isFlipped ? bounds.maxY - 2 : bounds.minY
        Theme.separator.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bottom, width: bounds.width, height: 1)).fill()
        for index in 0..<segmentCount {
            let visual = userInterfaceLayoutDirection == .rightToLeft ? segmentCount - 1 - index : index
            let x = CGFloat(visual) * slot
            let selected = isSelected(forSegment: index)
            let active = isEnabled && isEnabled(forSegment: index)
            let text = (label(forSegment: index) ?? "") as NSString
            let ink = active ? (selected ? Theme.accent : Theme.secondary) : NSColor.disabledControlTextColor
            let style: [NSAttributedString.Key: Any] = [.foregroundColor: ink,
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)]
            let size = text.size(withAttributes: style)
            text.draw(at: NSPoint(x: x + (slot - size.width) / 2, y: bounds.midY - size.height / 2), withAttributes: style)
            if selected {
                ink.setFill()
                NSBezierPath(rect: NSRect(x: x + 4, y: bottom, width: slot - 8, height: 2)).fill()
            }
        }
    }
}

/// Keeps native selection, hit testing, keyboard navigation and accessibility.
final class PeriodSegments: ThemeSegments {
    private let selectionLine = CALayer()
    private var displayedSegment = -1

    override func layout() {
        super.layout()
        selectionLine.isHidden = Theme.design == .claude
        if selectionLine.superlayer == nil {
            wantsLayer = true
            layer?.addSublayer(selectionLine)
        }
        positionLine(animated: false)
    }

    func moveSelection() { positionLine(animated: true) }

    private func positionLine(animated: Bool) {
        guard selectedSegment >= 0, segmentCount > 0, bounds.width > 0 else { return }
        let slot = bounds.width / CGFloat(segmentCount)
        let visual = userInterfaceLayoutDirection == .rightToLeft ? segmentCount - 1 - selectedSegment : selectedSegment
        let center = slot * (CGFloat(visual) + 0.5)
        let old = selectionLine.presentation()?.position.x ?? selectionLine.position.x
        let shouldSlide = animated && displayedSegment >= 0 && selectedSegment != displayedSegment
        displayedSegment = selectedSegment
        if !animated { selectionLine.removeAnimation(forKey: "period") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLine.backgroundColor = Theme.accent.resolvedCGColor()
        selectionLine.cornerRadius = 1
        selectionLine.bounds = CGRect(x: 0, y: 0, width: max(2, slot - 12), height: 2)
        selectionLine.position = CGPoint(x: center, y: isFlipped ? bounds.height - 3 : 3)
        CATransaction.commit()
        if shouldSlide && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = old
            slide.toValue = center
            slide.duration = QuotaMotion.feedback
            slide.timingFunction = QuotaMotion.enterEase
            selectionLine.add(slide, forKey: "period")
        }
    }
}
