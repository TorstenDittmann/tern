import AppKit
import WebKit

/// Hosts the visible tab(s): one floating card, or two side by side in split view.
/// Also owns the floating find bar, which acts on the focused pane.
@MainActor
final class ContentViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let panes = PanesView()
    private let findBar = FindBar()
    private let dropZone = SplitDropView()
    private var shown: [Tab] = []
    private weak var focusedWebView: WKWebView?
    private var panesLeading: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()

        findBar.isHidden = true
        findBar.onFind = { [weak self] query, backwards in self?.find(query, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        panes.onFractionChange = { [weak self] f in self?.browser?.splitFractionDidChange(f) }

        dropZone.isHidden = true
        dropZone.onDrop = { [weak self] id, right in
            guard let self, let tab = self.browser?.tabs.first(where: { $0.id == id }) else { return false }
            return self.dropTab(tab, onRight: right)
        }

        for v in [panes, dropZone, findBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let g = Theme.gutter
        panesLeading = panes.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            panes.topAnchor.constraint(equalTo: root.topAnchor, constant: g),
            panesLeading,
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -g),
            panes.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -g),
            dropZone.topAnchor.constraint(equalTo: panes.topAnchor), dropZone.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            dropZone.leadingAnchor.constraint(equalTo: panes.leadingAnchor), dropZone.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
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
            card.agentRing.isShown = i < tabs.count && tabs[i].isAgentDriving
            if i < tabs.count { card.progress.set(progress: tabs[i].progress, visible: tabs[i].isLoading) }
        }
        focusedWebView = focused.webView
    }

    func update(for tab: Tab) {
        guard let i = shown.firstIndex(of: tab) else { return }
        panes.cards[i].progress.set(progress: tab.progress, visible: tab.isLoading)
        panes.cards[i].agentRing.isShown = tab.isAgentDriving
    }

    // MARK: Drag a tab onto the page

    /// The sidebar started dragging a tab: the panes become a drop target.
    func beginTabDrag() { dropZone.isHidden = false }

    func endTabDrag() {
        dropZone.isHidden = true
        dropZone.reset()
    }

    /// Splits the page with `tab` on the given side. In a split, it replaces the pane on that side.
    @discardableResult
    func dropTab(_ tab: Tab, onRight right: Bool) -> Bool {
        guard let browser, let active = browser.activeTab else { return false }
        let visible = browser.visibleTabs
        let other = visible.count == 2 ? (right ? visible[0] : visible[1]) : active
        guard other !== tab else { return false }
        browser.split(right ? other : tab, with: right ? tab : other, focus: tab)
        return true
    }

    // MARK: Link peek

    private(set) var linkPeek: LinkPeek?

    /// Opens `url` in a floating preview over the panes (⌥-click, or ⌥ on a link hint).
    func peek(_ url: URL, from tab: Tab) {
        closePeek()
        let peek = LinkPeek(url: url, from: tab)
        peek.onClose = { [weak self] in self?.closePeek() }
        peek.onPromote = { [weak self] split in self?.promotePeek(split: split) }
        peek.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(peek)
        NSLayoutConstraint.activate([
            peek.topAnchor.constraint(equalTo: view.topAnchor), peek.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            peek.leadingAnchor.constraint(equalTo: view.leadingAnchor), peek.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        linkPeek = peek
        view.window?.makeFirstResponder(peek.tab.webView)
    }

    func closePeek() {
        guard let peek = linkPeek else { return }
        linkPeek = nil
        peek.takeTab().discard()
        peek.removeFromSuperview()
        view.window?.makeFirstResponder(focusedWebView)
    }

    /// Keeps the peeked page: as a tab after the one it came from, or in a split beside it.
    func promotePeek(split: Bool) {
        guard let peek = linkPeek, let browser else { return }
        linkPeek = nil
        let tab = peek.takeTab()
        peek.removeFromSuperview()
        guard let anchor = peek.anchor ?? browser.activeTab, browser.tabs.contains(anchor) else {
            return browser.insert(tab, after: nil, activate: true)
        }
        if split {
            browser.insert(tab, after: anchor, activate: false)
            browser.split(anchor, with: tab, focus: tab)
        } else {
            browser.insert(tab, after: anchor, activate: true)
        }
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
    let agentRing = AgentRingView()

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
        agentRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        addSubview(agentRing)
        clip.addSubview(progress)
        NSLayoutConstraint.activate([
            agentRing.topAnchor.constraint(equalTo: topAnchor), agentRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            agentRing.leadingAnchor.constraint(equalTo: leadingAnchor), agentRing.trailingAnchor.constraint(equalTo: trailingAnchor),
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

/// A colored ring and a "Agent is driving" tag around a card an agent is acting on.
/// Purely visual: clicks go through to the page.
final class AgentRingView: NSView {
    static let color = NSColor.systemPurple

    private let badge = NSTextField(labelWithString: "Agent is driving")

    var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = isShown ? 0.15 : 0.4
                animator().alphaValue = isShown ? 1 : 0
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = false
        let pill = FilledView()
        pill.fill = Self.color
        pill.radius = 9
        pill.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        pill.addSubview(badge)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.heightAnchor.constraint(equalToConstant: 18),
            badge.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2.5
        layer?.borderColor = Self.color.cgColor
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
