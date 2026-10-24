import AppKit
import WebKit

/// Hosts the top bar and, below it, the visible tab(s): one floating card, or two to four in split view.
/// Also owns the floating find bar, which acts on the focused pane.
@MainActor
final class ContentViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let panes = PanesView()
    private let findBar = FindBar()
    private let dropZone = SplitDropView()
    private var shown: [Tab] = []
    private weak var focusedWebView: WKWebView?
    let topBar = TopBar()
    private var panesLeading: NSLayoutConstraint!
    private var panesTrailing: NSLayoutConstraint!
    private var barTop: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()

        findBar.isHidden = true
        findBar.onFind = { [weak self] query, backwards in self?.find(query, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        panes.onDividersChange = { [weak self] d in self?.browser?.splitDividersDidChange(d) }

        dropZone.isHidden = true
        dropZone.paneFrames = { [weak self] in self?.panes.paneFrames ?? [] }
        dropZone.onDrop = { [weak self] id, target in
            guard let browser = self?.browser, let tab = browser.tabs.first(where: { $0.id == id }) else { return false }
            return browser.drop(tab, at: target)
        }

        for v in [topBar, panes, dropZone, findBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let g = Theme.gutter
        panesLeading = panes.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        panesTrailing = panes.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -g)
        barTop = topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: TopBar.defaultContentTop - TopBar.height - g)
        barLeading = topBar.leadingAnchor.constraint(equalTo: panes.leadingAnchor)
        NSLayoutConstraint.activate([
            barTop, barLeading,
            topBar.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: TopBar.height),
            panes.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: g),
            panesLeading,
            panesTrailing,
            panes.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -g),
            dropZone.topAnchor.constraint(equalTo: panes.topAnchor), dropZone.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            dropZone.leadingAnchor.constraint(equalTo: panes.leadingAnchor), dropZone.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            findBar.topAnchor.constraint(equalTo: panes.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: panes.trailingAnchor, constant: -12),
        ])
        view = root
    }

    /// The cards meet the sidebar with no gap and keep a gutter on the window's edge.
    func sidebarDidChange(collapsed: Bool, onRight: Bool) {
        loadViewIfNeeded()
        panesLeading.constant = collapsed || onRight ? Theme.gutter : 0
        panesTrailing.constant = !collapsed && onRight ? 0 : -Theme.gutter
        topBar.setSidebarSide(right: onRight)
    }

    /// Centers the top bar on the traffic lights, `lightsInset` points from its leading edge to clear them.
    func setTitlebar(barTop top: CGFloat, lightsInset: CGFloat) {
        loadViewIfNeeded()
        barTop.constant = top
        barLeading.constant = lightsInset
    }

    // MARK: Display

    /// Shows `tabs` (one, or two to four for a split) and marks `focused` as the pane with keyboard focus.
    func display(_ tabs: [Tab], focused: Tab, layout: SplitLayout, dividers: [CGFloat]) {
        shown = tabs
        panes.arrange(count: tabs.count, layout: layout, dividers: dividers)
        // Lay the cards out first, so a web view moving in gets its final size right away. Otherwise it
        // renders once at the card's old size (full width, or the other half of a split), then resizes.
        panes.layoutSubtreeIfNeeded()
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
    func beginTabDrag() {
        dropZone.canAddPane = (browser?.visibleTabs.count ?? 1) < SplitGroup.maxTabs
        dropZone.isHidden = false
    }

    func endTabDrag() {
        dropZone.isHidden = true
        dropZone.reset()
    }

    // MARK: Link peek

    private(set) var linkPeek: LinkPeek?

    /// Opens `url` in a floating preview over the panes (⌥-click, or ⌥ on a link hint). The card grows out
    /// of `point` (window coordinates), or out of the mouse pointer, where the ⌥-click was.
    func peek(_ url: URL, from tab: Tab, at point: NSPoint? = nil) {
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
        view.layoutSubtreeIfNeeded()
        let origin = (point ?? view.window?.mouseLocationOutsideOfEventStream)
            .map { peek.convert($0, from: nil) }.flatMap { peek.bounds.contains($0) ? $0 : nil }
        peek.animateIn(from: origin ?? NSPoint(x: peek.bounds.midX, y: peek.bounds.midY))
        view.window?.makeFirstResponder(peek.tab.webView)
    }

    func closePeek() {
        guard let peek = linkPeek else { return }
        linkPeek = nil
        view.window?.makeFirstResponder(focusedWebView)
        peek.animateOut {
            peek.takeTab().discard()
            peek.removeFromSuperview()
        }
    }

    /// Keeps the peeked page: as a tab after the one it came from, or in a split beside it.
    func promotePeek(split: Bool) {
        guard let peek = linkPeek, let browser else { return }
        linkPeek = nil
        let from = peek.cardFrame(in: view)
        let tab = peek.takeTab()
        peek.animateOut { peek.removeFromSuperview() }
        if let anchor = peek.anchor ?? browser.activeTab, browser.tabs.contains(anchor) {
            browser.insert(tab, after: anchor, activate: !split)
            if split { browser.split(anchor, with: tab, focus: tab) }
        } else {
            browser.insert(tab, after: nil, activate: true)
        }
        grow(tab, from: from)
    }

    /// The promoted page's card grows out of where the peek's card was (`rect`, in `view`'s coordinates).
    /// The scale is uniform, so the page doesn't stretch when the shapes differ (a split's half-width pane).
    private func grow(_ tab: Tab, from rect: NSRect) {
        guard !LinkPeek.reduceMotion else { return }
        view.layoutSubtreeIfNeeded()
        guard let card = panes.cards.first(where: { tab.webView != nil && tab.webView?.superview === $0.clip }),
              let superview = card.superview, card.frame.width > 0, card.frame.height > 0 else { return }
        let from = superview.convert(rect, from: view)
        let scale = ((from.width / card.frame.width) * (from.height / card.frame.height)).squareRoot()
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: card.layerTransform(
            scale: scale, moving: NSPoint(x: card.frame.midX, y: card.frame.midY), to: NSPoint(x: from.midX, y: from.midY)))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 300
        grow.damping = 30
        grow.duration = grow.settlingDuration
        card.layer?.add(grow, forKey: "grow")
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

/// Lays out one to four cards by hand; the gaps between them are drag handles (double-click evens them out).
final class PanesView: NSView {
    let cards = (0..<SplitGroup.maxTabs).map { _ in CardView() }
    var onDividersChange: (([CGFloat]) -> Void)?
    private(set) var count = 1
    private(set) var arrangement = SplitLayout.columns
    private(set) var dividers: [CGFloat] = []
    private var handles: [SplitHandle] = []

    private let gap = Theme.gutter

    override init(frame: NSRect) {
        super.init(frame: frame)
        cards.forEach(addSubview)
        cards.dropFirst().forEach { $0.isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    var paneFrames: [NSRect] { cards.prefix(count).map(\.frame) }

    func arrange(count: Int, layout: SplitLayout, dividers: [CGFloat]) {
        let count = max(1, min(count, cards.count))
        guard count != self.count || layout != arrangement || dividers != self.dividers else { return }
        self.count = count
        arrangement = layout
        self.dividers = dividers
        for (i, card) in cards.enumerated() { card.isHidden = i >= count }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let frames = SplitGeometry.frames(count: count, layout: arrangement, dividers: dividers, in: bounds, gap: gap)
        for (card, frame) in zip(cards, frames) { card.frame = frame }
        handles = SplitGeometry.handles(count: count, layout: arrangement, frames: frames, in: bounds, gap: gap)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for h in handles { addCursorRect(h.rect, cursor: h.vertical ? .resizeLeftRight : .resizeUpDown) }
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let handle = handles.first(where: { $0.rect.contains(start) }) else { return super.mouseDown(with: event) }
        if event.clickCount == 2 { return setDividers(SplitGroup.evenDividers(count, arrangement)) }
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] e, stop in
            guard let self, let e else { return }
            if e.type == .leftMouseUp { stop.pointee = true; return }
            var d = self.dividers
            d[handle.divider] = SplitGeometry.divider(for: handle, at: self.convert(e.locationInWindow, from: nil), count: self.count,
                                                      layout: self.arrangement, dividers: d, in: self.bounds, gap: self.gap)
            self.setDividers(d)
        }
    }

    private func setDividers(_ d: [CGFloat]) {
        dividers = d
        needsLayout = true
        onDividersChange?(d)
    }
}

/// Shadowed outer view + clipping inner view (a layer can't both clip and cast a shadow).
final class CardView: NSView {
    let clip = FilledView()
    let progress = ProgressLine()
    let agentRing = AgentRingView()

    /// In split view the pane with keyboard focus gets an accent ring with a soft glow.
    var isFocusedPane = false {
        didSet {
            guard isFocusedPane != oldValue else { return }
            clip.border = isFocusedPane ? Theme.accent : Theme.hairline
            needsDisplay = true
        }
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
        if isFocusedPane {
            layer?.shadowColor = Theme.accent.cgColor
            layer?.shadowOpacity = effectiveAppearance.isDark ? 0.35 : 0.25
            layer?.shadowRadius = 4
            layer?.shadowOffset = .zero
        } else {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = effectiveAppearance.isDark ? 0.35 : 0.08
            layer?.shadowRadius = 6
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
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
    override func updateLayer() { bar.backgroundColor = Theme.accent.cgColor }

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
