import AppKit
import WebKit

/// Responsive design mode (⌃⌘R): the tab's page is laid out at a device's size, centered in its card,
/// with that device's user agent and pixel density. A bar above it picks the device, rotates it,
/// and overrides the user agent.
struct DevicePreview: Equatable {
    struct Preset: Equatable {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let userAgent: UserAgent
    }

    enum UserAgent: String, CaseIterable {
        case standard, safariMac, chromeMac, firefoxMac, safariIPhone, safariIPad, chromeAndroid

        var title: String {
            switch self {
            case .standard: "Tern (Default)"
            case .safariMac: "Safari · Mac"
            case .chromeMac: "Chrome · Mac"
            case .firefoxMac: "Firefox · Mac"
            case .safariIPhone: "Safari · iPhone"
            case .safariIPad: "Safari · iPad"
            case .chromeAndroid: "Chrome · Android"
            }
        }

        /// nil: WebKit's own user agent, with Tern's Safari suffix.
        var string: String? {
            switch self {
            case .standard: nil
            case .safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            case .chromeMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
            case .firefoxMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
            case .safariIPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            case .safariIPad: "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            case .chromeAndroid: "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36"
            }
        }
    }

    static let presets: [Preset] = [
        Preset(name: "iPhone SE", width: 375, height: 667, scale: 2, userAgent: .safariIPhone),
        Preset(name: "iPhone 17", width: 402, height: 874, scale: 3, userAgent: .safariIPhone),
        Preset(name: "iPhone 17 Pro Max", width: 440, height: 956, scale: 3, userAgent: .safariIPhone),
        Preset(name: "Pixel 9", width: 412, height: 915, scale: 2.625, userAgent: .chromeAndroid),
        Preset(name: "iPad mini", width: 744, height: 1133, scale: 2, userAgent: .safariIPad),
        Preset(name: "iPad Pro 11″", width: 834, height: 1210, scale: 2, userAgent: .safariIPad),
        Preset(name: "Laptop", width: 1280, height: 800, scale: 2, userAgent: .standard),
        Preset(name: "Desktop HD", width: 1920, height: 1080, scale: 1, userAgent: .standard),
    ]

    /// The preset responsive design mode starts with: the last one used, else the second (a current iPhone).
    @MainActor static var lastPreset = 1

    var preset: Int
    var landscape = false
    /// Overrides the preset's own user agent.
    var userAgent: UserAgent?

    var device: Preset { Self.presets[max(0, min(preset, Self.presets.count - 1))] }
    var effectiveUserAgent: UserAgent { userAgent ?? device.userAgent }

    /// CSS pixels.
    var size: CGSize {
        landscape ? CGSize(width: device.height, height: device.width) : CGSize(width: device.width, height: device.height)
    }
}

/// Applies a preview's user agent and pixel density to a web view.
@MainActor
enum DeviceEmulation {
    static func apply(_ preview: DevicePreview?, to webView: WKWebView) {
        let agent = preview?.effectiveUserAgent.string
        if webView.customUserAgent != agent {
            webView.customUserAgent = agent
            if webView.url != nil { webView.reload() }
        }
        setScale(preview?.device.scale ?? 0, on: webView)
    }

    /// `_setOverrideDeviceScaleFactor:` is the SPI Safari's responsive design mode uses for
    /// `devicePixelRatio`; 0 goes back to the screen's own. Skipped where it doesn't exist.
    private static func setScale(_ scale: CGFloat, on webView: WKWebView) {
        let sel = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        guard let method = class_getInstanceMethod(type(of: webView), sel) else { return }
        typealias SetScale = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetScale.self)(webView, sel, scale)
    }
}

/// The strip above a previewed page: device, size, rotate, user agent, and close.
final class DeviceBar: FilledView {
    static let height: CGFloat = 30
    var onChange: ((DevicePreview?) -> Void)?
    private var preview: DevicePreview?

    private let devicePopup = NSPopUpButton()
    private let agentPopup = NSPopUpButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private lazy var rotate = HoverButton(symbol: "rotate.right", size: 12, label: "Rotate", target: self, action: #selector(rotateClicked))
    private lazy var close = HoverButton(symbol: "xmark", size: 10, label: "Leave Responsive Design Mode", target: self, action: #selector(closeClicked))

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = Theme.ground
        for popup in [devicePopup, agentPopup] {
            popup.isBordered = false
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11.5, weight: .medium)
            popup.target = self
        }
        devicePopup.addItems(withTitles: DevicePreview.presets.map(\.name))
        devicePopup.action = #selector(deviceChanged)
        agentPopup.addItems(withTitles: DevicePreview.UserAgent.allCases.map(\.title))
        agentPopup.action = #selector(agentChanged)
        agentPopup.toolTip = "User agent"
        sizeLabel.font = Theme.monoFont(11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentPopup.setContentCompressionResistancePriority(.init(240), for: .horizontal)

        let icon = NSImageView(image: Theme.symbol("iphone", size: 11)!)
        icon.contentTintColor = Theme.accent
        let rule = FilledView()
        rule.fill = Theme.hairline
        let stack = NSStackView(views: [icon, devicePopup, sizeLabel, rotate, NSView(), agentPopup, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for v in [stack, rule] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `shown` is the viewport actually on screen, smaller than the device when the card is.
    func show(_ preview: DevicePreview, shown: CGSize) {
        self.preview = preview
        devicePopup.selectItem(at: preview.preset)
        agentPopup.selectItem(at: DevicePreview.UserAgent.allCases.firstIndex(of: preview.effectiveUserAgent) ?? 0)
        let size = preview.size
        let scale = preview.device.scale
        let scaleText = scale == scale.rounded() ? "\(Int(scale))×" : String(format: "%.3g×", scale)
        var text = "\(Int(size.width)) × \(Int(size.height)) · \(scaleText)"
        if shown.width < size.width || shown.height < size.height {
            text = "\(Int(shown.width)) × \(Int(shown.height)) of \(Int(size.width)) × \(Int(size.height)) · \(scaleText)"
        }
        sizeLabel.stringValue = text
        sizeLabel.toolTip = text
    }

    @objc private func deviceChanged() {
        guard var p = preview else { return }
        p.preset = devicePopup.indexOfSelectedItem
        p.userAgent = nil
        onChange?(p)
    }

    @objc private func agentChanged() {
        guard var p = preview else { return }
        let agent = DevicePreview.UserAgent.allCases[agentPopup.indexOfSelectedItem]
        p.userAgent = agent == p.device.userAgent ? nil : agent
        onChange?(p)
    }

    @objc private func rotateClicked() {
        guard var p = preview else { return }
        p.landscape.toggle()
        onChange?(p)
    }

    @objc private func closeClicked() { onChange?(nil) }

    override var mouseDownCanMoveWindow: Bool { false }
}
