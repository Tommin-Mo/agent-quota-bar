import AppKit

/// 菜单栏图标：品牌 logo（单色）+ 圆环（圆环内是额度数字）。
/// 总宽度 28pt，比文字标签省一大截。
enum MenuBarIcon {
    private static let baseLogo: CGFloat = 12
    private static let baseRing: CGFloat = 15.4
    private static let baseGap: CGFloat = 2.5

    static func make(
        provider: String,
        value: String,
        remaining: Double?,
        severity: QuotaSeverity,
        scale: CGFloat = 1.25,
        ink: NSColor = .white
    ) -> NSImage {
        let s = max(0.8, min(1.6, scale))
        let logoSize = baseLogo * s
        let ringSize = baseRing * s
        let drawsRing = remaining != nil || severity == .critical
        let gap = (drawsRing ? baseGap : 2) * s
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10 * s, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textSize = drawsRing ? .zero : (value as NSString).size(withAttributes: attrs)
        let height = max(logoSize, ringSize) + 2
        // 圆环不留白；积分/余额数字与 logo 居中对齐，只留很小的左右边距，避免贴隔壁图标。
        let padLeft: CGFloat = drawsRing ? 0 : 4 * s
        let padRight: CGFloat = drawsRing ? 0 : 4 * s
        let contentWidth = logoSize + gap + (drawsRing ? ringSize : textSize.width)
        let width = padLeft + contentWidth + padRight

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 1.4
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()

            let logoRect = NSRect(x: padLeft, y: (height - logoSize) / 2, width: logoSize, height: logoSize)
            drawLogo(provider: provider, in: logoRect, ink: ink)

            if drawsRing {
                let ringRect = NSRect(x: padLeft + logoSize + gap, y: (height - ringSize) / 2, width: ringSize, height: ringSize)
                drawRing(in: ringRect, value: value, remaining: remaining, severity: severity, ink: ink, scale: s)
            } else {
                NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                let origin = NSPoint(
                    x: padLeft + logoSize + gap,
                    y: (height - textSize.height) / 2
                )
                (value as NSString).draw(at: origin, withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Logo

    private static func drawLogo(provider: String, in rect: NSRect, ink: NSColor) {
        if let logo = ProviderLogo.menuMark(for: provider, size: rect.width, color: ink) {
            logo.draw(in: rect)
            return
        }
        let letter = provider == "workbuddy" ? "W" : "?"
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let text = letter as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Ring

    private static func drawRing(
        in rect: NSRect,
        value: String,
        remaining: Double?,
        severity: QuotaSeverity,
        ink: NSColor,
        scale: CGFloat
    ) {
        let line: CGFloat = max(1.25, rect.width * 0.085)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (rect.width - line) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -270, clockwise: true)
        track.lineWidth = line
        let trackColor: NSColor = severity == .neutral
            ? ink.withAlphaComponent(0.32)
            : severity.color.withAlphaComponent(0.30)
        trackColor.setStroke()
        track.stroke()

        if let remaining {
            let fraction = CGFloat(min(100, max(0, remaining)) / 100)
            if fraction > 0.01 {
                let progress = NSBezierPath()
                progress.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                progress.lineWidth = line
                progress.lineCapStyle = .round
                severity.color.setStroke()
                progress.stroke()
            }
        }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: rect.width * (value.count > 2 ? 0.32 : 0.40),
            weight: .semibold
        )
        let textColor: NSColor = ink
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
        let text = value as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attrs
        )
    }
}
