import AppKit
import WebKit

/// ⌥-click on a link: the page opens in a floating card over the current one, without a tab.
/// ⌘↩ keeps it as a tab, ⇧⌘↩ opens it in a split beside the page it came from, esc (or a click
/// outside the card) closes it. The peek is a real, ownerless `Tab`, so promoting it keeps the page as is.
/// The card grows out of the link it was opened from and shrinks back into it on close.
@MainActor
final class LinkPeek: NSView {
    let tab: Tab
    /// The tab the link was in; a promoted peek goes next to it.
    weak var anchor: Tab?
    var onClose: (() -> Void)?
    var onPromote: ((_ split: Bool) -> Void)?

    /// Holds the card and its header, so both scale and fade as one.
    private let stage = NSView()
    private let backdrop = NSView()
    private let card = CardView()
    private let header = NSVisualEffectView()
    private let address = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?
    /// Where the link was, in this view's coordinates: the card grows from and shrinks back to it.
    private var origin: NSPoint?
    /// Closing: clicks go through to the page underneath while the card fades out.
    private var isClosing = false

    init(url: URL, from anchor: Tab) {
        tab = Tab(url: url)
        tab.homeWindow = anchor.owner
        self.anchor = anchor
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        stage.wantsLayer = true

        let webView = tab.materialize()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        card.clip.addSubview(webView, positioned: .below, relativeTo: card.progress)

        header.material = .menu
        header.state = .active
        header.wantsLayer = true
        header.layer?.cornerRadius = 10
        header.layer?.cornerCurve = .continuous
        header.layer?.borderWidth = 1
        header.layer?.borderColor = Theme.hairline.cgColor
        address.font = .systemFont(ofSize: 12, weight: .medium)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle
        address.stringValue = Theme.displayString(for: url)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let open = Self.button("Open as Tab", keys: "⌘↩", target: self, action: #selector(openAsTab))
        let split = Self.button("Split", keys: "⇧⌘↩", target: self, action: #selector(openInSplit))
        let close = HoverButton(symbol: "xmark", size: 10, label: "Close Peek (esc)", target: self, action: #selector(closeClicked))
        let row = NSStackView(views: [address, open, split, close])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)

        for v in [backdrop, stage] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [card, header] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; stage.addSubview(v) }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor), backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor), stage.bottomAnchor.constraint(equalTo: bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor), stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: header.topAnchor), row.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor), row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -6),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 20),
            card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.82),
            card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.78),
        ])

        titleObservation = webView.observe(\.url) { [weak self] wv, _ in
            MainActor.assumeIsolated { if let url = wv.url { self?.address.stringValue = Theme.displayString(for: url) } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tab.webView?.frame = card.clip.bounds
    }

    /// The card's frame in `view`'s coordinates, for the promoted page to grow out of.
    func cardFrame(in view: NSView) -> NSRect { view.convert(card.frame, from: stage) }

    /// Grows the card out of `point` (in this view's coordinates), where the link was.
    func animateIn(from point: NSPoint) {
        origin = point
        backdrop.layer?.add(Self.fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
        stage.layer?.add(Self.fade(from: 0, to: 1, duration: 0.12), forKey: "fade")
        guard !Motion.reduceMotion else { return }
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: stage.layerTransform(scale: 0.1, moving: point, to: point))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 300
        grow.damping = 28
        grow.duration = grow.settlingDuration
        stage.layer?.add(grow, forKey: "grow")
    }

    /// Shrinks the card back into the link and fades it out, then calls `completion`.
    /// Without the card (it was promoted and its page moved out), the header and backdrop just fade.
    func animateOut(completion: @escaping () -> Void) {
        isClosing = true
        let duration = 0.18
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        backdrop.layer?.add(Self.fade(from: 1, to: 0, duration: duration), forKey: "fade")
        stage.layer?.add(Self.fade(from: 1, to: 0, duration: duration), forKey: "fade")
        if let origin, !card.isHidden, !Motion.reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.toValue = NSValue(caTransform3D: stage.layerTransform(scale: 0.4, moving: origin, to: origin))
            shrink.duration = duration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            stage.layer?.add(shrink, forKey: "grow")
        }
        CATransaction.commit()
    }

    private static func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        return fade
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isClosing ? nil : super.hitTest(point) }

    /// Hands the web view back, still loaded, so the tab can be shown in a pane.
    func takeTab() -> Tab {
        titleObservation = nil
        tab.webView?.removeFromSuperview()
        card.isHidden = true
        return tab
    }

    /// Keys for the peek, ahead of the keymap. Everything else goes to the peeked page.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53, flags.isEmpty { onClose?(); return true }               // esc
        if isReturn, flags == .command { onPromote?(false); return true }               // ⌘↩
        if isReturn, flags == [.command, .shift] { onPromote?(true); return true }      // ⇧⌘↩
        if event.keyCode == 13, flags == .command { onClose?(); return true }           // ⌘W closes the peek, not the tab under it
        return false
    }

    // A click on the dimmed backdrop closes the peek.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) && !header.frame.contains(p) { onClose?() }
    }

    @objc private func openAsTab() { onPromote?(false) }
    @objc private func openInSplit() { onPromote?(true) }
    @objc private func closeClicked() { onClose?() }

    private static func button(_ title: String, keys: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: "\(title)  \(keys)", target: target, action: action)
        b.bezelStyle = .accessoryBarAction
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11, weight: .medium)
        return b
    }
}

extension NSView {
    /// A layer transform that scales this view by `scale` and moves `point` to `target`, both in its
    /// superview's coordinates. Scaling happens around the layer's anchor point, so that's factored out.
    func layerTransform(scale: CGFloat, moving point: NSPoint, to target: NSPoint) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        let anchor = NSPoint(x: frame.minX + layer.anchorPoint.x * frame.width, y: frame.minY + layer.anchorPoint.y * frame.height)
        let dx = target.x - anchor.x - scale * (point.x - anchor.x)
        let dy = target.y - anchor.y - scale * (point.y - anchor.y)
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(dx, dy, 0))
    }
}
