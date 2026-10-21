import AppKit

/// 品牌 logo 加载与着色。simple-icons 提供的单色 SVG，在浅色/深色下都用
/// 对应 ink 重新着色，避免在菜单栏里出现“黑块”。
enum ProviderLogo {
    static func image(for provider: String, size: CGFloat, color: NSColor) -> NSImage? {
        if provider == "workbuddy", let base = loadImage("logo-workbuddy-menu") {
            return render(tint(base, color: color), size: size)
        }
        guard let file = file(for: provider), let base = loadImage(file) else { return nil }
        return render(tint(base, color: color), size: size)
    }

    /// 菜单栏专用：单色标记（WorkBuddy 用“圆角方块 + 脸部镂空”的白色版）。
    static func menuMark(for provider: String, size: CGFloat, color: NSColor) -> NSImage? {
        if provider == "workbuddy", let base = loadImage("logo-workbuddy-menu") {
            return render(tint(base, color: color), size: size)
        }
        return image(for: provider, size: size, color: color)?.tintedTemplate(color: color)
    }

    private static func render(_ image: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        result.unlockFocus()
        return result
    }

    static func file(for provider: String) -> String? {
        switch provider {
        case "codex": return "logo-openai"
        case "deepseek": return "logo-deepseek"
        case "trae": return "logo-trae"
        case "opencode": return "logo-opencode"
        case "workbuddy": return "logo-workbuddy-color"
        default: return nil
        }
    }

    static func loadImage(_ name: String) -> NSImage? {
        for ext in ["svg", "png"] {
            let bundleURL = Bundle.main.url(forResource: name, withExtension: ext)
            let devURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/\(name).\(ext)")
            if let url = bundleURL ?? (FileManager.default.fileExists(atPath: devURL.path) ? devURL : nil),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    static func tint(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        result.unlockFocus()
        return result
    }
}


extension NSImage {
    func tintedTemplate(color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
        result.unlockFocus()
        return result
    }
}
