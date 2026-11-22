import AppKit

enum DesignTheme: String, CaseIterable {
    case original, glass, claude

    var title: String {
        switch self {
        case .original: return "墨绿"
        case .glass: return "液态玻璃"
        case .claude: return "Claude"
        }
    }

    init(setting: String) { self = Self(rawValue: setting) ?? .original }
}

enum Theme {
    static var design = DesignTheme.original

    static func headingFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if design == .claude, let font = NSFont(name: "Songti SC Bold", size: size) { return font }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// 显式外观优先于 effectiveAppearance。
    /// 切换外观后 effectiveAppearance 可能晚一个 runloop 才更新，旧代码会在同一帧里
    /// 用深色文字配浅色背景（或反过来）。
    static var currentAppearance: NSAppearance {
        NSApp.appearance ?? NSApp.effectiveAppearance
    }

    /// 判断指定外观是否为深色；绘制菜单栏图标时传当前绘制外观。
    static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        let target = appearance ?? currentAppearance
        return target.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

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

    private static func role(_ original: (UInt32, UInt32), _ glass: (UInt32, UInt32), _ claude: (UInt32, UInt32)) -> NSColor {
        NSColor(name: nil) { appearance in
            let pair: (UInt32, UInt32)
            switch design {
            case .original: pair = original
            case .glass: pair = glass
            case .claude: pair = claude
            }
            return hex(isDark(appearance) ? pair.1 : pair.0)
        }
    }

    static func refreshViews(_ node: NSView) {
        (node as? ThemedSurfaceView)?.updateDesignLayout()
        (node as? ThemedSurfaceView)?.applySurface()
        (node as? ProviderMarkView)?.refreshInk()
        (node as? GlidePopUpButton)?.applyColors()
        (node as? SettingsPopUpButton)?.refreshDesign()
        (node as? QuotaTextField)?.refreshDesign()
        if let periods = node as? PeriodSegments {
            periods.selectedSegmentBezelColor = segmentTint
            periods.needsLayout = true
        }
        if let label = node as? ThemedLabel { label.applyRole(label.roleColor) }
        if let label = node as? ThemedWrappingLabel { label.textColor = label.roleColor.resolvedForAppearance() }
        if let toggle = node as? AccentSwitch { toggle.rootView.model.objectWillChange.send() }
        node.needsDisplay = true
        node.subviews.forEach(refreshViews)
    }

    static var segmentTint: NSColor? { design == .glass ? nil : forest.resolvedForAppearance() }

    static let background = role((0xF4F3EF, 0x111917), (0xF0F4F9, 0x161A21), (0xFAF9F5, 0x201F1D))
    static let sidebar = role((0xEBEDE6, 0x17211D), (0xDEE8F3, 0x252D38), (0xEEECE4, 0x282622))
    static let surface = role((0xFFFFFF, 0x1D2823), (0xFBFCFF, 0x202630), (0xFFFEFA, 0x292824))
    static let surfaceAlt = role((0xF9F9F5, 0x243029), (0xF3F6FB, 0x272F3C), (0xF6F4EB, 0x312F2A))
    static let text = role((0x131A1A, 0xE8EEF4), (0x192333, 0xEDF3FC), (0x141413, 0xFAF9F5))
    static let secondary = role((0x4E5F5C, 0x97A6B4), (0x435568, 0xB2C1D1), (0x59564F, 0xC6C2B8))
    static let tertiary = role((0x596B67, 0x93A3B1), (0x566778, 0xA3B3C6), (0x686357, 0xB7B2A7))
    static let separator = role((0xDADDD4, 0x34413B), (0xD6DFEA, 0x394554), (0xE2DFD4, 0x47443E))
    static let hover = role((0xE8EEE6, 0x28372E), (0xE2EAF4, 0x2F3C50), (0xF0EBE1, 0x39342E))
    static let accent = role((0x0B6B5E, 0x86C6BD), (0x245C97, 0x9AC9FF), (0x9B4932, 0xE9A185))
    static let accentSoft = role((0xDDF1ED, 0x103029), (0xDCEBFB, 0x263B51), (0xF6E6DC, 0x442F26))
    static let forest = role((0x0B6B5E, 0x0B6B5E), (0x234D73, 0x294C6E), (0x85432F, 0x693B2D))
    static let historyCaption = role((0xD6F0EB, 0xD6F0EB), (0x435568, 0xB2C1D1), (0x59564F, 0xC6C2B8))
    static let mint = role((0xD6F0EB, 0xD6F0EB), (0xE2F1FF, 0xE2F1FF), (0xFCEBDD, 0xFCEBDD))
    static let heatIdle = role((0xF0F0E9, 0x28332F), (0xECF0F5, 0x2C343F), (0xEFEDE5, 0x302F2B))
    static let heatLight = role((0xCCE7E2, 0x244A43), (0xD1E6FC, 0x304867), (0xF5D9C8, 0x563E32))
    static let heatMedium = role((0x87BDB4, 0x347562), (0x9FC3EC, 0x446183), (0xE9AE90, 0x785741))
    static let heatHigh = role((0x0B6B5E, 0x78BDAA), (0x245C97, 0x9AC9FF), (0x9B4932, 0xE9A185))
    static let quotaHealthy = accent
    static let quotaWarning = role((0xB45309, 0xF5B544), (0x995300, 0xF7BD69), (0x8E5D12, 0xEBC278))
    static let quotaDanger = role((0xB82F37, 0xF87171), (0xBA2548, 0xFF8DA0), (0x9D2935, 0xF09091))
    static let success = accent
    static let warning = quotaWarning
    static let danger = quotaDanger
    static let tile = dynamic(hex(0x152029), hex(0x111A21))
}


/// 记录“语义色角色”的视图：外观变化时重新解析 CALayer 颜色。
/// CALayer 的 backgroundColor / borderColor 是静态 CGColor，一旦写入就不会跟随外观。
class ThemedSurfaceView: NSView {
    var isWindowCanvas = false
    var designLayout: ((DesignTheme) -> Void)? {
        didSet { lastDesign = nil; updateDesignLayout() }
    }
    private var lastDesign: DesignTheme?
    private var backdrop: NSVisualEffectView?
    private let contrastTint = CALayer()

    func updateDesignLayout() {
        guard let designLayout, lastDesign != Theme.design else { return }
        lastDesign = Theme.design
        designLayout(Theme.design)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isWindowCanvas {
            if let window, window.styleMask.contains(.titled) {
                // Keep the window backing stable; the content draws the opaque themes.
                window.isOpaque = false
                window.backgroundColor = .clear
            }
            applySurface()
        }
    }

    private func updateBackdrop(_ enabled: Bool) {
        contrastTint.backgroundColor = (Theme.isDark() ? NSColor.black.withAlphaComponent(0.55)
                                                       : NSColor.white.withAlphaComponent(0.30)).cgColor
        guard enabled != (backdrop != nil) else { return }
        if enabled {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            contrastTint.frame = effect.bounds
            contrastTint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            effect.layer?.addSublayer(contrastTint)
            effect.autoresizingMask = [.width, .height]
            effect.setAccessibilityElement(false)
            addSubview(effect, positioned: .below, relativeTo: nil)
            backdrop = effect
        } else {
            contrastTint.removeFromSuperlayer()
            backdrop?.removeFromSuperview()
            backdrop = nil
        }
    }

    var isNavigationSurface = false
    private var materialView: NSView?

    func updateMaterial(reduceTransparency: Bool, increaseContrast: Bool) {
        guard isNavigationSurface else { return }
        let needsMaterial = Theme.design == .glass && !reduceTransparency && !increaseContrast
        guard needsMaterial != (materialView != nil) else { return }
        guard needsMaterial else {
            materialView?.removeFromSuperview()
            materialView = nil
            return
        }
        let material: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = layer?.cornerRadius ?? 0
            material = glass
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .sidebar
            blur.blendingMode = .withinWindow
            blur.wantsLayer = true
            blur.layer?.cornerRadius = layer?.cornerRadius ?? 0
            blur.layer?.masksToBounds = true
            material = blur
        }
        material.autoresizingMask = [.width, .height]
        material.setAccessibilityElement(false)
        addSubview(material, positioned: .below, relativeTo: nil)
        materialView = material
    }

    var surfaceColor: NSColor? {
        didSet { applySurface() }
    }
    var surfaceBorderColor: NSColor? {
        didSet { applySurface() }
    }
    var surfaceBorderWidth: CGFloat = 0 {
        didSet { applySurface() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurface()
    }

    func applySurface() {
        guard wantsLayer else { return }
        let workspace = NSWorkspace.shared
        if isWindowCanvas {
            updateBackdrop(Theme.design == .glass && !workspace.accessibilityDisplayShouldReduceTransparency
                           && !workspace.accessibilityDisplayShouldIncreaseContrast)
        }
        if isNavigationSurface {
            updateMaterial(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                           increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        }
        // 显式外观优先（NSApp.appearance），避免 effectiveAppearance 晚一拍。
        let appearance = Theme.currentAppearance
        if let surfaceColor {
            layer?.backgroundColor = (backdrop != nil || materialView != nil ? NSColor.clear : surfaceColor).resolvedForAppearance(appearance).cgColor
        }
        if let surfaceBorderColor {
            layer?.borderColor = surfaceBorderColor.resolvedForAppearance(appearance).cgColor
            layer?.borderWidth = surfaceBorderWidth
        }
    }
}

extension NSColor {
    /// 在 app 当前外观下解析动态色，再转 CGColor；避免重建 UI 时拿到旧外观的颜色。
    func resolvedCGColor() -> CGColor {
        var resolved = cgColor
        Theme.currentAppearance.performAsCurrentDrawingAppearance {
            resolved = cgColor
        }
        return resolved
    }

    /// 把动态色固定成指定外观下的具体颜色，避免 NSTextField 缓存了错误外观的颜色。
    func resolvedForAppearance(_ appearance: NSAppearance? = nil) -> NSColor {
        let target = appearance ?? Theme.currentAppearance
        var color = cgColor
        target.performAsCurrentDrawingAppearance {
            color = cgColor
        }
        return NSColor(cgColor: color) ?? self
    }
}
