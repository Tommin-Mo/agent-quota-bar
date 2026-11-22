import AppKit

struct MenuBarIcon {
    let foreground: NSImage
    let progress: NSImage?
    var size: NSSize { foreground.size }

    static func make(provider: String, value: String, remaining: Double?, scale: CGFloat = 1.25) -> Self {
        let s = max(0.3, scale)
        let logoSize = 12 * s
        let ringSize = 15.4 * s
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10 * s, weight: .medium)
        let text = value as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let hasRing = remaining != nil
        let padding = hasRing ? 0 : 4 * s
        let valueX = padding + logoSize + (hasRing ? 2.5 : 2) * s
        let size = NSSize(width: valueX + (hasRing ? ringSize : textSize.width) + padding, height: ringSize + 2)
        let ring = NSRect(x: valueX, y: (size.height - ringSize) / 2, width: ringSize, height: ringSize)
        let foreground = NSImage(size: size, flipped: false) { _ in
            let logo = NSRect(x: padding, y: (size.height - logoSize) / 2, width: logoSize, height: logoSize)
            drawLogo(provider: provider, in: logo, ink: .black)
            if hasRing {
                NSColor.black.withAlphaComponent(0.27).setStroke()
                arc(in: ring, fraction: 1).stroke()
                let digits = NSFont.monospacedDigitSystemFont(ofSize: ringSize * (value.count > 2 ? 0.32 : 0.40), weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: NSColor.black]
                let measured = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: ring.midX - measured.width / 2, y: ring.midY - measured.height / 2), withAttributes: attrs)
            } else {
                text.draw(at: NSPoint(x: valueX, y: (size.height - textSize.height) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        foreground.isTemplate = true
        let progress = remaining.flatMap { remaining -> NSImage? in
            guard remaining > 0 else { return nil }
            let image = NSImage(size: size, flipped: false) { _ in
                let green = Theme.isDark(NSAppearance.currentDrawing()) ? Theme.hex(0x53D883) : Theme.hex(0x178544)
                green.setStroke()
                let stroke = arc(in: ring, fraction: min(1, remaining / 100))
                stroke.lineCapStyle = .round
                stroke.stroke()
                return true
            }
            image.cacheMode = .never
            return image
        }
        return Self(foreground: foreground, progress: progress)
    }

    private static func arc(in rect: NSRect, fraction: Double) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = max(1.25, rect.width * 0.085)
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                       radius: (rect.width - path.lineWidth) / 2,
                       startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        return path
    }

    func draw(in rect: NSRect) {
        foreground.tintedTemplate(color: .labelColor).draw(in: rect)
        progress?.draw(in: rect)
    }

    // MARK: - Logo

    private static func drawLogo(provider: String, in rect: NSRect, ink: NSColor) {
        if provider == "quota" {
            ink.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: rect.midX, y: rect.midY))
            needle.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            needle.stroke()
            return
        }
        if let logo = ProviderLogo.image(for: provider, size: rect.width, color: ink) {
            logo.draw(in: rect)
            return
        }
        let letter = ProviderStyles.style(for: provider).letter
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let text = letter as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

}

// Only the arc needs a color of its own. AppKit draws the template underneath
// with the same foreground and highlight treatment as adjacent status items.
final class MenuBarProgressView: NSView {
    var progress: NSImage? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let button = superview as? NSStatusBarButton, let cell = button.cell else { return }
        let rect = convert(cell.imageRect(forBounds: button.bounds), from: button)
        progress?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
