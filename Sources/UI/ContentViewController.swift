import AppKit
import WebKit

/// Hosts the visible tab(s): one floating card, or two side by side in split view.
/// Also owns the floating find bar, which acts on the focused pane.
@MainActor
final class ContentViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let panes = PanesView()
    private let findBar = FindBar()
    private var shown: [Tab] = []
    private weak var focusedWebView: WKWebView?
    private var panesLeading: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()

        findBar.isHidden = true
        findBar.onFind = { [weak self] query, backwards in self?.find(query, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        panes.onFractionChange = { [weak self] f in self?.browser?.splitFractionDidChange(f) }

        for v in [panes, findBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let g = Theme.gutter
        panesLeading = panes.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            panes.topAnchor.constraint(equalTo: root.topAnchor, constant: g),
            panesLeading,
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -g),
            panes.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -g),
            findBar.topAnchor.constraint(equalTo: panes.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: panes.trailingAnchor, constant: -12),
        ])
        view = root
    }

    func sidebarDidToggle(collapsed: Bool) {
        panesLeading.constant = collapsed ? Theme.gutter : 0
    }

    // MARK: Display

    /// Shows `tabs` (one, or two for a split) and marks `focused` as the pane with keyboard focus.
    func display(_ tabs: [Tab], focused: Tab, fraction: CGFloat) {
        shown = tabs
        panes.count = tabs.count
        panes.fraction = fraction
        for (i, card) in panes.cards.enumerated() {
            let webView = i < tabs.count ? tabs[i].webView : nil
            // Detach whatever this card showed before, unless it's the view we want.
            for case let old as WKWebView in card.clip.subviews where old !== webView { old.removeFromSuperview() }
            if let webView, webView.superview !== card.clip {
                webView.removeFromSuperview()
                // Autoresizing instead of constraints: cheaper on every live resize.
                webView.translatesAutoresizingMaskIntoConstraints = true
                webView.frame = card.clip.bounds
                webView.autoresizingMask = [.width, .height]
                card.clip.addSubview(webView, positioned: .below, relativeTo: card.progress)
            }
            card.isFocusedPane = tabs.count > 1 && i < tabs.count && tabs[i] === focused
            if i < tabs.count { card.progress.set(progress: tabs[i].progress, visible: tabs[i].isLoading) }
        }
        focusedWebView = focused.webView
    }

    func update(for tab: Tab) {
        guard let i = shown.firstIndex(of: tab) else { return }
        panes.cards[i].progress.set(progress: tab.progress, visible: tab.isLoading)
    }

    // MARK: Find

    func showFindBar() {
        findBar.isHidden = false
        findBar.focus()
    }

    func hideFindBar() {
        findBar.isHidden = true
        focusedWebView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
        view.window?.makeFirstResponder(focusedWebView)
    }

    func findAgain(backwards: Bool) {
        if findBar.isHidden { showFindBar() }
        find(findBar.query, backwards: backwards)
    }

    private func find(_ query: String, backwards: Bool) {
        guard let webView = focusedWebView, !query.isEmpty else { findBar.setStatus(nil); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(query, configuration: config) { [weak self] result in
            self?.findBar.setStatus(result.matchFound)
        }
    }
}

/// Lays out one or two cards by hand; the gap between two is a drag handle (double-click resets to 50/50).
final class PanesView: NSView {
    let cards = [CardView(), CardView()]
    var onFractionChange: ((CGFloat) -> Void)?
    var count = 1 {
        didSet {
            guard count != oldValue else { return }
            cards[1].isHidden = count < 2
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var fraction: CGFloat = 0.5 { didSet { if fraction != oldValue { needsLayout = true } } }

    private let gap = Theme.gutter

    override init(frame: NSRect) {
        super.init(frame: frame)
        cards.forEach(addSubview)
        cards[1].isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        guard count > 1 else { cards[0].frame = bounds; return }
        let left = ((bounds.width - gap) * fraction).rounded()
        cards[0].frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        cards[1].frame = NSRect(x: left + gap, y: 0, width: bounds.width - left - gap, height: bounds.height)
        window?.invalidateCursorRects(for: self)
    }

    private var handleRect: NSRect {
        NSRect(x: cards[0].frame.maxX - 3, y: 0, width: gap + 6, height: bounds.height)
    }

    override func resetCursorRects() {
        if count > 1 { addCursorRect(handleRect, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        guard count > 1, handleRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        if event.clickCount == 2 { setFraction(0.5); return }
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] e, stop in
            guard let self, let e else { return }
            if e.type == .leftMouseUp { stop.pointee = true; return }
            let x = self.convert(e.locationInWindow, from: nil).x
            self.setFraction((x - self.gap / 2) / (self.bounds.width - self.gap))
        }
    }

    private func setFraction(_ f: CGFloat) {
        fraction = min(0.8, max(0.2, f))
        onFractionChange?(fraction)
    }
}

/// Shadowed outer view + clipping inner view (a layer can't both clip and cast a shadow).
final class CardView: NSView {
    let clip = FilledView()
    let progress = ProgressLine()

    /// In split view the pane with keyboard focus gets an accent ring.
    var isFocusedPane = false {
        didSet { clip.border = isFocusedPane ? NSColor.controlAccentColor.withAlphaComponent(0.55) : Theme.hairline }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.radius = Theme.cardRadius
        clip.fill = .textBackgroundColor
        clip.border = Theme.hairline
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        clip.addSubview(progress)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor), clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor), clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            progress.topAnchor.constraint(equalTo: clip.topAnchor),
            progress.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2.5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        clip.layer?.masksToBounds = true
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.cardRadius, cornerHeight: Theme.cardRadius, transform: nil)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = effectiveAppearance.isDark ? 0.35 : 0.10
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// Accent line; layer-only so it doesn't trigger layout while loading.
final class ProgressLine: NSView {
    private let bar = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        bar.cornerRadius = 1.25
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { bar.backgroundColor = NSColor.controlAccentColor.cgColor }

    func set(progress: Double, visible: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0.08, progress), height: bounds.height)
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.1 : 0.35
            animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// Floating find pill in the card's top-right corner (Safari-style).
final class FindBar: NSVisualEffectView, NSTextFieldDelegate {
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    var query: String { field.stringValue }

    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .menu
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor

        let glass = NSImageView(image: Theme.symbol("magnifyingglass", size: 12, weight: .semibold)!)
        glass.contentTintColor = .tertiaryLabelColor
        field.placeholderString = "Find in page"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        status.textColor = .tertiaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .medium)

        let prev = HoverButton(symbol: "chevron.up", size: 11, label: "Previous", target: self, action: #selector(prevClicked))
        let next = HoverButton(symbol: "chevron.down", size: 11, label: "Next", target: self, action: #selector(nextClicked))
        let done = HoverButton(symbol: "xmark", size: 10, label: "Done", target: self, action: #selector(doneClicked))

        let stack = NSStackView(views: [glass, field, status, prev, next, done])
        stack.spacing = 4
        stack.setCustomSpacing(8, after: glass)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func setStatus(_ found: Bool?) {
        status.stringValue = found == false ? "No matches" : ""
        status.textColor = found == false ? .systemRed : .tertiaryLabelColor
    }

    func controlTextDidChange(_ obj: Notification) { onFind?(query, false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onFind?(query, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default: return false
        }
    }

    @objc private func prevClicked() { onFind?(query, true) }
    @objc private func nextClicked() { onFind?(query, false) }
    @objc private func doneClicked() { onClose?() }
}
