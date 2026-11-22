import AppKit

import CryptoKit

/// The six built-in marks and user-imported theSVG marks share the same template renderer.
enum ProviderLogo {
    private static let assets: URL = {
        if let url = Bundle.main.url(forResource: "TheSVG", withExtension: nil) { return url }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/TheSVG")
    }()

    private static let catalog: Set<String> = {
        let text = try? String(contentsOf: assets.appendingPathComponent("asset-hashes.txt"), encoding: .utf8)
        return Set((text ?? "").split(separator: "\n").map(String.init))
    }()

    static func image(for provider: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard provider.range(of: #"^[a-z][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else { return nil }
        let name = provider + ".svg"
        let bundled = assets.appendingPathComponent(name)
        let source: Data
        if let data = try? Data(contentsOf: bundled) {
            source = data
        } else {
            let local = ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("agents").appendingPathComponent(name)
            guard let info = try? local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? .max) <= 524288,
                  let file = try? FileHandle(forReadingFrom: local) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: 524289), data.count <= 524288 else { return nil }
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(data.count)\0".utf8))
            hash.update(data: data)
            guard catalog.contains(hash.finalize().map { String(format: "%02x", $0) }.joined()) else { return nil }
            source = data
        }

        let data = provider == "workbuddy" ? workBuddyForeground(source) : source
        guard let data, let base = NSImage(data: data), base.size.width > 0, base.size.height > 0 else { return nil }
        let scale = size / max(base.size.width, base.size.height)
        let width = base.size.width * scale, height = base.size.height * scale
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        base.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
        color.set()
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceIn)
        result.unlockFocus()
        return result
    }

    // Upstream supplies a single app icon. Preserve the cat and both eyes as drawn.
    private static func workBuddyForeground(_ data: Data) -> Data? {
        guard let source = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
              let root = source.rootElement(), let group = root.elements(forName: "g").first else { return nil }
        let shapes = group.elements(forName: "path") + group.elements(forName: "rect").filter { $0.attribute(forName: "transform") != nil }
        guard shapes.count == 3 else { return nil }
        for element in shapes {
            element.detach()
            element.attribute(forName: "fill")?.stringValue = "#000"
        }
        root.setChildren(shapes)
        return source.xmlData
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

final class ProviderMarkView: NSView {
    private weak var logoView: NSImageView?

    init(provider: String, size: CGFloat) {
        let style = ProviderStyles.style(for: provider)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        if let logo = ProviderLogo.image(for: provider, size: size, color: .black) {
            logo.isTemplate = true
            let view = NSImageView(image: logo)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = Theme.dynamic(Theme.accent, .white).resolvedForAppearance(effectiveAppearance)
            self.logoView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }

        let label = NSTextField(labelWithString: style.letter)
        label.font = .systemFont(ofSize: size * 0.46, weight: .bold)
        label.textColor = Theme.dynamic(Theme.accent, .white)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInk()
    }

    func refreshInk() {
        logoView?.contentTintColor = Theme.dynamic(Theme.accent, .white).resolvedForAppearance(effectiveAppearance)
        logoView?.needsDisplay = true
    }
}
