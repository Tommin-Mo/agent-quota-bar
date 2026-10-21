import AppKit

/// 菜单栏小图标：一段环形 gauge，长度 = 剩余额度，颜色 = 严重程度。
enum GaugeIcon {
    static func make(remaining: Double?, severity: QuotaSeverity, size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = 2.2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (size - lineWidth) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -270, clockwise: true)
            track.lineWidth = lineWidth
            track.lineCapStyle = .round
            NSColor.secondaryLabelColor.withAlphaComponent(0.28).setStroke()
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
                    progress.lineWidth = lineWidth
                    progress.lineCapStyle = .round
                    severity.color.setStroke()
                    progress.stroke()
                } else {
                    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2))
                    severity.color.setFill()
                    dot.fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
