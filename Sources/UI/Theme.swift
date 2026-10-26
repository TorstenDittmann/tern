import AppKit

/// Shared look: spacing, radii and appearance-aware colors.
@MainActor
enum Theme {
    static let gutter: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 7
    static let rowHeight: CGFloat = 30

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    // Graphite: a near-black (or cool light gray) ground, slightly raised surfaces, hairlines, and
    // one accent for focus, progress and the active split pane.

    /// Window background behind the sidebar and the pages.
    static let ground = dynamic(light: hex(0xECEDEF), dark: hex(0x0B0C0E))
    /// Panels that sit on the ground: the palette, pinned tab tiles.
    static let surface = dynamic(light: hex(0xFFFFFF), dark: hex(0x15171A))
    /// A strip set into a surface, like the palette's footer.
    static let recessedFill = dynamic(light: hex(0xF5F6F7), dark: hex(0x121417))
    /// The one accent: lime in dark mode, a deeper green that reads on light backgrounds.
    static let accent = dynamic(light: hex(0x2E8B4A), dark: hex(0x9BE8A6))
    static let accentWash = dynamic(light: hex(0x2E8B4A, 0.12), dark: hex(0x9BE8A6, 0.12))

    /// Selected tab: a raised chip.
    static let selectedFill = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E2126))
    static let hoverFill = dynamic(light: NSColor.black.withAlphaComponent(0.045), dark: NSColor.white.withAlphaComponent(0.045))
    static let fieldFill = dynamic(light: hex(0xFFFFFF, 0.75), dark: hex(0x15171A))
    static let fieldFocusedFill = dynamic(light: hex(0xFFFFFF), dark: hex(0x1A1D21))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.09), dark: hex(0x24272C))
    static let keycapFill = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.07))
    static let paletteSelection = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: hex(0x22262C))

    /// URLs, shortcuts and section labels.
    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Small uppercase section label ("TABS", "COMMANDS"), tracked out a little.
    static func sectionTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: monoFont(10.5, weight: .medium), .kern: 0.6, .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// The address bar's text: the whole URL, with the host in full color and the rest dimmed, so the
    /// domain still stands out the way it did when the bar showed only the host.
    static func addressString(for url: URL?, font: NSFont) -> NSAttributedString {
        guard let url else { return NSAttributedString() }
        let text = url.scheme == "about" && url.absoluteString == "about:blank" ? "" : url.absoluteString
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        if let host = url.host, !host.isEmpty, let schemeEnd = text.range(of: "://"),
           let range = text.range(of: host, options: .caseInsensitive, range: schemeEnd.upperBound..<text.endIndex) {
            string.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(range, in: text))
            string.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(text.startIndex..<schemeEnd.upperBound, in: text))
        }
        return string
    }

    /// Compact text for a URL where space is short (the palette, link peek): host without `www.`, filename for files.
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
            label.font = Theme.monoFont(11, weight: .medium)
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
        Motion.setBackground(layer, (hovering && isEnabled) ? Theme.hoverFill.cgColor : .clear)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
