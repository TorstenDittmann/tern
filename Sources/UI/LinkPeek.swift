import AppKit
import WebKit

/// ⌥-click on a link: the page opens in a floating card over the current one, without a tab.
/// ⌘↩ keeps it as a tab, ⇧⌘↩ opens it in a split beside the page it came from, esc (or a click
/// outside the card) closes it. The peek is a real, ownerless `Tab`, so promoting it keeps the page as is.
@MainActor
final class LinkPeek: NSView {
    let tab: Tab
    /// The tab the link was in; a promoted peek goes next to it.
    weak var anchor: Tab?
    var onClose: (() -> Void)?
    var onPromote: ((_ split: Bool) -> Void)?

    private let card = CardView()
    private let header = NSVisualEffectView()
    private let address = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?

    init(url: URL, from anchor: Tab) {
        tab = Tab(url: url)
        self.anchor = anchor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

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

        for v in [card, header] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
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

    /// Hands the web view back, still loaded, so the tab can be shown in a pane.
    func takeTab() -> Tab {
        titleObservation = nil
        tab.webView?.removeFromSuperview()
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
