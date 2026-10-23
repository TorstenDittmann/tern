import AppKit
import WebKit

/// One browser window: a vertical tab sidebar plus the content area. Owns the tab list.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private struct ClosedTab { let url: URL?; let title: String?; let state: Data?; let index: Int }

    /// Two tabs shown side by side. It's on screen whenever the active tab is one of them;
    /// picking another tab shows that tab alone and keeps the pair for later.
    struct SplitPair { var left: Tab; var right: Tab; var fraction: CGFloat = 0.5 }

    /// Stable for the window's lifetime; how the agent API names windows.
    let id = UUID()
    private(set) var tabs: [Tab] = []
    private(set) var activeTab: Tab?
    private(set) var split: SplitPair?
    private var closedTabs: [ClosedTab] = []

    /// What the content area shows: the active tab, or both halves of its split.
    var visibleTabs: [Tab] {
        guard let activeTab else { return [] }
        if let split, split.left === activeTab || split.right === activeTab { return [split.left, split.right] }
        return [activeTab]
    }

    func isPaired(_ tab: Tab) -> Bool { split.map { $0.left === tab || $0.right === tab } ?? false }

    let sidebar = SidebarViewController()
    let content = ContentViewController()
    private let splitController = TernSplitViewController()
    private var sidebarItem: NSSplitViewItem!

    /// Extension controller is only told about this window once it's fully set up.
    private var isAnnounced = false
    private var extensions: WKWebExtensionController { BrowserEngine.shared.extensionController }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    init(tabs initial: [Tab], active: Int, frame: NSRect?, sidebarCollapsed: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 320)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self

        sidebar.browser = self
        content.browser = self
        // A plain split item (not `sidebarWithViewController`): no floating glass panel; the whole
        // window shares one material and the page sits on top as a card.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 440
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = sidebarCollapsed
        sidebarItem.holdingPriority = .init(260)
        splitController.splitView = InvisibleDividerSplitView()
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: content))
        splitController.splitView.autosaveName = "TernSidebarWidth"
        window.contentViewController = RootViewController(child: splitController)
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none

        // Assigning contentViewController resizes the window to fit, so set the frame afterwards.
        if let frame { window.setFrame(frame, display: false) }
        else { window.setContentSize(NSSize(width: 1280, height: 820)); window.center() }

        initial.forEach { $0.owner = self }
        tabs = initial
        sidebar.reloadTabs()
        content.sidebarDidToggle(collapsed: sidebarCollapsed)
        if tabs.isEmpty { newTab(url: nil) } else { activate(tabs[max(0, min(active, tabs.count - 1))]) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called once the window is registered with the app, so extensions see a consistent world.
    func announceToExtensions() {
        guard !isAnnounced else { return }
        isAnnounced = true
        extensions.didOpenWindow(self)
        tabs.forEach { extensions.didOpenTab($0) }
        if let activeTab { extensions.didActivateTab(activeTab, previousActiveTab: nil) }
    }

    // MARK: Tab lifecycle

    @discardableResult
    func newTab(url: URL?, activate: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(url: url)
        insert(tab, after: anchor, activate: activate)
        return tab
    }

    func insert(_ tab: Tab, after anchor: Tab?, activate: Bool) {
        let index = anchor.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        insert(tab, at: index, activate: activate)
    }

    func insert(_ tab: Tab, at index: Int, activate shouldActivate: Bool) {
        tab.owner = self
        tabs.insert(tab, at: max(0, min(index, tabs.count)))
        sidebar.reloadTabs()
        if isAnnounced { extensions.didOpenTab(tab) }
        if shouldActivate || activeTab == nil { activate(tab) }
    }

    func activate(_ tab: Tab) {
        guard tabs.contains(tab) else { return }
        let previous = activeTab
        previous?.lastActivated = Date()
        activeTab = tab
        tab.lastActivated = Date()

        let webView = tab.materialize()
        showVisibleTabs()
        sidebar.activeTabDidChange()
        window?.title = tab.displayTitle

        if tab.currentURL == nil { focusAddressBar() } else if window?.firstResponder !== webView { window?.makeFirstResponder(webView) }

        if isAnnounced, previous !== tab {
            extensions.didActivateTab(tab, previousActiveTab: previous)
            extensions.didSelectTabs([tab])
            if let previous { extensions.didDeselectTabs([previous]) }
        }
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closedTabs.append(ClosedTab(url: tab.currentURL, title: tab.pageTitle, state: tab.interactionStateData, index: index))
        if closedTabs.count > 50 { closedTabs.removeFirst() }

        let wasActive = tab === activeTab
        // Closing half of a split ends it and hands focus to the other half.
        var partner: Tab?
        if let split, isPaired(tab) {
            partner = split.left === tab ? split.right : split.left
            self.split = nil
        }
        tabs.remove(at: index)
        if isAnnounced { extensions.didCloseTab(tab, windowIsClosing: false) }
        tab.discard()

        if tabs.isEmpty {
            activeTab = nil
            window?.close()
            return
        }
        sidebar.reloadTabs()
        if wasActive {
            activeTab = nil
            activate(partner ?? tabs[min(index, tabs.count - 1)])
        } else if partner != nil, let activeTab {
            activate(activeTab)
        }
    }

    func reopenClosedTab() {
        guard let c = closedTabs.popLast() else { return }
        insert(Tab(url: c.url, title: c.title, interactionState: c.state), at: c.index, activate: true)
    }

    func duplicate(_ tab: Tab) {
        insert(Tab(url: tab.currentURL, title: tab.pageTitle, interactionState: tab.interactionStateData), after: tab, activate: true)
    }

    func closeOthers(than keep: Tab) {
        for tab in tabs where tab !== keep { close(tab) }
    }

    func closeTabs(below tab: Tab) {
        guard let i = tabs.firstIndex(of: tab) else { return }
        for t in tabs[(i + 1)...] { close(t) }
    }

    // MARK: Split view

    private func showVisibleTabs() {
        guard let activeTab else { return }
        let visible = visibleTabs
        visible.forEach { $0.materialize() }
        content.display(visible, focused: activeTab, fraction: split?.fraction ?? 0.5)
    }

    /// ⌘\: split the current tab with a new tab on the right, or end the split it's in.
    func toggleSplit() {
        guard let active = activeTab else { return }
        if isPaired(active) { return unsplit() }
        let fresh = Tab(url: nil)
        insert(fresh, after: active, activate: false)
        split(active, with: fresh, focus: fresh)
    }

    /// Pairs the current tab with the tab used before it.
    func splitWithPreviousTab() {
        guard let active = activeTab,
              let previous = tabs.filter({ $0 !== active }).max(by: { $0.lastActivated < $1.lastActivated }) else { return }
        split(active, with: previous, focus: active)
    }

    func split(_ left: Tab, with right: Tab, focus: Tab) {
        guard left !== right, tabs.contains(left), tabs.contains(right) else { return }
        split = SplitPair(left: left, right: right, fraction: split?.fraction ?? 0.5)
        sidebar.reloadTabs()
        activate(focus)
        showVisibleTabs()
    }

    func unsplit() {
        guard split != nil else { return }
        split = nil
        sidebar.reloadTabs()
        if let activeTab { activate(activeTab) }
    }

    func swapPanes() {
        guard var pair = split, let activeTab, isPaired(activeTab) else { return }
        swap(&pair.left, &pair.right)
        pair.fraction = 1 - pair.fraction
        split = pair
        showVisibleTabs()
    }

    func focusPane(right: Bool) {
        guard let pair = split, let activeTab, isPaired(activeTab) else { return }
        activate(right ? pair.right : pair.left)
    }

    /// A click into a visible web view makes its tab the active one (address bar, extensions, commands).
    func paneDidFocus(_ tab: Tab) {
        guard tab !== activeTab, visibleTabs.contains(tab) else { return }
        activate(tab)
    }

    func restoreSplit(left: Tab, right: Tab, fraction: CGFloat) {
        split = SplitPair(left: left, right: right, fraction: fraction)
        sidebar.reloadTabs()
        showVisibleTabs()
    }

    func splitFractionDidChange(_ fraction: CGFloat) {
        split?.fraction = fraction
    }

    // MARK: Selection & ordering

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index])
    }

    func selectRelative(_ delta: Int) {
        guard let activeTab, let i = tabs.firstIndex(of: activeTab), !tabs.isEmpty else { return }
        select(index: (i + delta + tabs.count) % tabs.count)
    }

    func moveActiveTab(by delta: Int) {
        guard let activeTab, let i = tabs.firstIndex(of: activeTab) else { return }
        moveTab(from: i, to: i + delta)
    }

    func moveTab(from: Int, to rawTo: Int) {
        let to = max(0, min(rawTo, tabs.count - 1))
        guard tabs.indices.contains(from), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        sidebar.reloadTabs()
        if isAnnounced { extensions.didMoveTab(tab, from: from, in: self) }
    }

    // MARK: Chrome

    func focusAddressBar() {
        if isSidebarCollapsed {
            CommandPalette.show(for: self, mode: .everything, initialText: activeTab?.currentURL?.absoluteString ?? "")
        } else {
            sidebar.focusAddressField()
        }
    }

    func toggleSidebar() {
        let collapse = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            sidebarItem.animator().isCollapsed = collapse
        }
        content.sidebarDidToggle(collapsed: collapse)
    }

    /// Navigates the active tab (or a new one) to whatever the user typed.
    func open(input: String, inNewTab: Bool) {
        guard let url = BrowserEngine.shared.resolve(input: input) else { return }
        if inNewTab || activeTab == nil {
            newTab(url: url)
        } else if let tab = activeTab {
            tab.load(url)
            window?.makeFirstResponder(tab.webView)
        }
    }

    func tabDidChange(_ tab: Tab) {
        sidebar.reload(tab)
        content.update(for: tab)
        if tab === activeTab { window?.title = tab.displayTitle }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if isAnnounced { extensions.didFocusWindow(self) }
    }

    func windowWillClose(_ notification: Notification) {
        CommandPalette.close()
        for tab in tabs {
            if isAnnounced { extensions.didCloseTab(tab, windowIsClosing: true) }
            tab.discard()
        }
        if isAnnounced { extensions.didCloseWindow(self) }
        tabs.removeAll()
        activeTab = nil
        split = nil
        AppDelegate.shared.windowDidClose(self)
    }
}

/// Window background: one behind-window material under both sidebar and card.
final class RootViewController: NSViewController {
    private let child: NSViewController
    init(child: NSViewController) { self.child = child; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let bg = NSVisualEffectView()
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: bg.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])
        view = bg
    }
}

/// 1pt transparent divider; the drag target is widened so resizing still feels easy.
final class InvisibleDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override func drawDivider(in rect: NSRect) {}
}

final class TernSplitViewController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -4, dy: 0)
    }
}
