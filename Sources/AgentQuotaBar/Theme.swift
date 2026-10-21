import AppKit

enum Theme {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        // 每个颜色用唯一 name，避免 AppKit 按 name 缓存动态色时串色/固定在某一种外观。
        NSColor(name: NSColor.Name("theme-\(UUID().uuidString)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let background = dynamic(hex(0xEEF3F2), hex(0x0C1217))
    static let sidebar = dynamic(hex(0xFAFBFC), hex(0x0A0F14))
    static let surface = dynamic(hex(0xFFFFFF), hex(0x141D24))
    static let surfaceAlt = dynamic(hex(0xF4F8F7), hex(0x18232B))
    static let text = dynamic(hex(0x131A1A), hex(0xE8EEF4))
    static let secondary = dynamic(hex(0x4E5F5C), hex(0x97A6B4))
    static let tertiary = dynamic(hex(0x7C8D89), hex(0x6F7F8D))
    static let separator = dynamic(hex(0xDDE7E4), hex(0x26333D))
    static let hover = dynamic(hex(0xE4EFEC), hex(0x1A252E))
    static let accent = dynamic(hex(0x0B6B5E), hex(0x2DD4BF))
    static let accentSoft = dynamic(hex(0xDDF1ED), hex(0x103029))
    static let success = accent
    static let warning = dynamic(hex(0xB45309), hex(0xF5B544))
    static let danger = dynamic(hex(0xDC2626), hex(0xF87171))
    static let tile = dynamic(hex(0x152029), hex(0x111A21))
}


extension NSColor {
    /// 在 app 当前外观下解析动态色，再转 CGColor；避免重建 UI 时拿到旧外观的颜色。
    func resolvedCGColor() -> CGColor {
        var resolved = cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = cgColor
        }
        return resolved
    }

    /// 把动态色固定成当前外观下的具体颜色，避免 NSTextField 缓存了错误外观的颜色。
    func resolvedForAppearance() -> NSColor {
        NSColor(cgColor: resolvedCGColor()) ?? self
    }
}
