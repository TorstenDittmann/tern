import AppKit

/// Shared look: spacing, radii and appearance-aware colors.
@MainActor
enum Theme {
    static let gutter: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 8
    static let rowHeight: CGFloat = 34

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// Selected tab: a raised "chip", like Arc.
    static let selectedFill = dynamic(light: NSColor.white.withAlphaComponent(0.92), dark: NSColor.white.withAlphaComponent(0.12))
    static let hoverFill = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.06))
    static let fieldFill = dynamic(light: NSColor.black.withAlphaComponent(0.055), dark: NSColor.white.withAlphaComponent(0.075))
    static let fieldFocusedFill = dynamic(light: NSColor.white.withAlphaComponent(0.95), dark: NSColor.white.withAlphaComponent(0.13))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.white.withAlphaComponent(0.10))
    static let keycapFill = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.09))
    /// Laid over the palette's material so it reads as a solid surface over bright pages.
    static let paletteTint = dynamic(light: NSColor.white.withAlphaComponent(0.55), dark: NSColor(white: 0.12, alpha: 0.6))
    static let paletteSelection = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.10))

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// Compact address-bar text: host without `www.`, filename for files.
    static func displayString(for url: URL?) -> String {
        guard let url else { return "" }
        switch url.scheme {
        case "file": return url.lastPathComponent
        case "webkit-extension": return "Extension"
        case "about", "data": return ""
        default:
            guard var host = url.host else { return url.absoluteString }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if let port = url.port { host += ":\(port)" }
            return host
        }
    }
}

/// Letter tile used until (or instead of) a site's favicon, colored per host.
@MainActor
enum Monogram {
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL?, title: String) -> NSImage {
        var host = url?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let source = host.isEmpty ? title : host
        let letter = source.first.map { String($0).uppercased() } ?? "•"
        let key = "\(letter)|\(host)"
        if let img = cache[key] { return img }

        // Stable across launches (String.hashValue is seeded per process).
        let hash = source.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = CGFloat(hash % 360) / 360
        let color = NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.72, alpha: 1)
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let s = letter as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5), withAttributes: attrs)
            return true
        }
        cache[key] = img
        return img
    }
}

/// Keyboard shortcut drawn as little keycaps: ⇧ ⌘ T
final class KeycapView: NSStackView {
    init(glyphs: [String]) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        for g in glyphs {
            let label = NSTextField(labelWithString: g)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let cap = KeycapBox()
            cap.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                cap.heightAnchor.constraint(equalToConstant: 20),
                cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
                // Hug the glyph; a bare NSView has no intrinsic width and would stretch.
                cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 10).withPriority(.defaultHigh),
            ])
            addArrangedSubview(cap)
        }
        setHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class KeycapBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = Theme.keycapFill.cgColor
    }
}

/// A view whose layer background follows light/dark appearance.
class FilledView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
    }
}

/// Borderless icon button with a rounded hover background.
final class HoverButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String, size: CGFloat = 13, label: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = Theme.symbol(symbol, size: size)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
        self.target = target
        self.action = action
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 26)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = (hovering && isEnabled) ? Theme.hoverFill.cgColor : .clear
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
