import AppKit
import WebKit

/// One browser window: a vertical tab sidebar plus the content area. Owns the tab list.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private struct ClosedTab { let url: URL?; let title: String?; let state: Data?; let index: Int }

    /// Stable for the window's lifetime; how the agent API names windows.
    let id = UUID()
    /// A private window: its tabs share a data store that lives only in memory, record no history,
    /// aren't saved with the session, and are invisible to extensions.
    let isPrivate: Bool
    private lazy var privateConfiguration: WKWebViewConfiguration = {
        let c = BrowserEngine.shared.webViewConfiguration.copy() as! WKWebViewConfiguration
        c.websiteDataStore = .nonPersistent()
        c.webExtensionController = nil
        return c
    }()

    /// What a tab in this window creates its web view with.
    func webViewConfiguration(for url: URL?) -> WKWebViewConfiguration {
        isPrivate ? privateConfiguration : BrowserEngine.shared.configuration(for: url)
    }
    private(set) var tabs: [Tab] = []
    private(set) var activeTab: Tab?
    private(set) var split: SplitGroup?
    private var closedTabs: [ClosedTab] = []

    /// What the content area shows: the active tab, or every pane of its split.
    var visibleTabs: [Tab] {
        guard let activeTab else { return [] }
        if let split, split.contains(activeTab) { return split.tabs }
        return [activeTab]
    }

    func isPaired(_ tab: Tab) -> Bool { split?.contains(tab) ?? false }

    let sidebar = SidebarViewController()
    let content = ContentViewController()
    private let splitController = TernSplitViewController()
    private var sidebarItem: NSSplitViewItem!

    /// Extension controller is only told about this window once it's fully set up.
    private var isAnnounced = false
    private var extensions: WKWebExtensionController { BrowserEngine.shared.extensionController }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }
    private(set) var isSidebarOnRight = Preferences.sidebarOnRight
    /// The collapsed state the content and top bar were last laid out for.
    private var laidOutCollapsed = false

    init(tabs initial: [Tab], active: Int, frame: NSRect?, sidebarCollapsed: Bool, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
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
        content.topBar.browser = self
        // A plain split item (not `sidebarWithViewController`): no floating glass panel; the whole
        // window shares one material and the page sits on top as a card.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 100
        sidebarItem.maximumThickness = 440
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = sidebarCollapsed
        sidebarItem.holdingPriority = .init(260)
        splitController.splitView = InvisibleDividerSplitView()
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(NSSplitViewItem(viewController: content))
        splitController.insertSplitViewItem(sidebarItem, at: isSidebarOnRight ? 1 : 0)
        splitController.splitView.autosaveName = Self.widthAutosaveName(right: isSidebarOnRight)
        // Dragging the divider shut (or open) collapses the sidebar without toggleSidebar().
        // Deferred: this runs inside a layout pass, where changing constraints can loop.
        splitController.onResize = { [weak self] in
            guard let self, self.sidebarItem.isCollapsed != self.laidOutCollapsed else { return }
            DispatchQueue.main.async { self.sidebarCollapseDidChange() }
        }
        window.contentViewController = RootViewController(child: splitController)
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none

        // Assigning contentViewController resizes the window to fit, so set the frame afterwards.
        if let frame { window.setFrame(frame, display: false) }
        else { window.setContentSize(NSSize(width: 1280, height: 820)); window.center() }
        // Nothing saved for this side yet (first launch): without this the split view squeezes the tab list to its minimum.
        let savedWidth = "NSSplitView Subview Frames \(Self.widthAutosaveName(right: isSidebarOnRight))"
        if !sidebarCollapsed, UserDefaults.standard.object(forKey: savedWidth) == nil {
            splitController.splitView.layoutSubtreeIfNeeded()
            setSidebarWidth(Self.defaultSidebarWidth)
        }

        initial.forEach { $0.owner = self }
        let shown = initial.isEmpty ? nil : initial[max(0, min(active, initial.count - 1))]
        tabs = initial.filter(\.isPinned) + initial.filter { !$0.isPinned }
        sidebar.reloadTabs()
        laidOutCollapsed = sidebarCollapsed
        content.sidebarDidChange(collapsed: sidebarCollapsed, onRight: isSidebarOnRight)
        updateTitlebarLayout()
        content.onBarReveal = { [weak self] _ in self?.updateTrafficLights() }
        if Preferences.compactMode { setCompact(true) }
        if let shown { activate(shown) } else { newTab(url: nil) }
    }

    static let defaultSidebarWidth: CGFloat = 240

    /// Divider positions are saved per side: they're stored by pane order.
    private static func widthAutosaveName(right: Bool) -> String {
        UserDefaults.autosaveName(right ? "TernSidebarWidthRight" : "TernSidebarWidth")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called once the window is registered with the app, so extensions see a consistent world.
    func announceToExtensions() {
        guard !isAnnounced, !isPrivate else { return }
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
        // Pinned tabs live in a block at the top; others go below it.
        let bounds = tab.isPinned ? 0...pinnedCount : pinnedCount...tabs.count
        tabs.insert(tab, at: max(bounds.lowerBound, min(index, bounds.upperBound)))
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
        content.topBar.updateChrome()
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
        RequestInspector.tabClosed(tab)
        closedTabs.append(ClosedTab(url: tab.currentURL, title: tab.pageTitle, state: tab.interactionStateData, index: index))
        if closedTabs.count > 50 { closedTabs.removeFirst() }

        let wasActive = tab === activeTab
        // Closing a pane takes it out of the split and hands focus to a neighbor.
        let partner = isPaired(tab) ? leaveSplit(tab) : nil
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
        for tab in tabs where tab !== keep && !tab.isPinned { close(tab) }
    }

    func closeTabs(below tab: Tab) {
        guard let i = tabs.firstIndex(of: tab) else { return }
        for t in tabs[(i + 1)...] where !t.isPinned { close(t) }
    }

    // MARK: Pinned tabs

    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Pinning moves the tab to the end of the pinned block; unpinning to just below it.
    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard tab.isPinned != pinned, let from = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: from)
        tab.isPinned = pinned
        tab.pinnedURL = pinned ? tab.currentURL : nil
        let to = pinnedCount
        tabs.insert(tab, at: to)
        sidebar.reloadTabs()
        if isAnnounced, from != to { extensions.didMoveTab(tab, from: from, in: self) }
    }

    /// ⌘W on a pinned tab doesn't close it. If it has left its pinned page, it goes back there; if it's
    /// already there, it's put to sleep and the previous tab comes forward.
    func closeOrResetPinned(_ tab: Tab) {
        guard tab.isPinned else { return close(tab) }
        if tab.hasLeftPinnedURL, let url = tab.pinnedURL { return tab.load(url) }
        let previous = tabs.filter { $0 !== tab }.max { $0.lastActivated < $1.lastActivated }
        guard let previous else { return }
        if isPaired(tab) { removeFromSplit(tab) }
        activate(previous)
        tab.suspend()
    }

    /// Makes the page a pinned tab is on its pinned page.
    func repin(_ tab: Tab) {
        guard tab.isPinned else { return }
        tab.pinnedURL = tab.currentURL
        tabDidChange(tab)
    }

    // MARK: Split view

    private func showVisibleTabs() {
        guard let activeTab else { return }
        let visible = visibleTabs
        visible.forEach { $0.materialize() }
        let group = split.flatMap { $0.contains(activeTab) ? $0 : nil }
        content.display(visible, focused: activeTab, layout: group?.layout ?? .columns, dividers: group?.dividers ?? [])
        content.topBar.updateChrome()
    }

    /// ⌘\: split the current tab with a new tab on the right, or end the split it's in.
    func toggleSplit() {
        guard let active = activeTab else { return }
        if isPaired(active) { return unsplit() }
        splitWithNewTab(layout: .columns)
    }

    /// ⌃⌘\: split the current tab with a new tab below it.
    func splitDown() {
        guard let active = activeTab else { return }
        if isPaired(active) { return addPane() }
        splitWithNewTab(layout: .rows)
    }

    private func splitWithNewTab(layout: SplitLayout) {
        guard let active = activeTab else { return }
        let fresh = Tab(url: nil)
        insert(fresh, after: active, activate: false)
        split(active, with: fresh, focus: fresh, layout: layout)
    }

    /// Adds a new tab to the split the current tab is in (or starts one), up to four panes.
    func addPane() {
        guard let active = activeTab else { return }
        guard let group = split, group.contains(active) else { return splitWithNewTab(layout: .columns) }
        guard group.tabs.count < SplitGroup.maxTabs else { NSSound.beep(); return }
        let fresh = Tab(url: nil)
        insert(fresh, after: group.tabs.last, activate: false)
        add(fresh, toSplitWith: active, focus: fresh)
    }

    /// Pairs the current tab with the tab used before it.
    func splitWithPreviousTab() {
        guard let active = activeTab,
              let previous = tabs.filter({ $0 !== active && !(split?.contains(active) == true && split?.contains($0) == true) })
                .max(by: { $0.lastActivated < $1.lastActivated }) else { return }
        if isPaired(active), split!.tabs.count < SplitGroup.maxTabs { return add(previous, toSplitWith: active, focus: active) }
        split(active, with: previous, focus: active)
    }

    /// Starts a new split of two tabs, replacing any split there was.
    func split(_ left: Tab, with right: Tab, focus: Tab, layout: SplitLayout = .columns) {
        split([left, right], layout: layout, focus: focus)
    }

    /// Shows `tabs` (two to four, in reading order) together, replacing any split there was.
    func split(_ group: [Tab], layout: SplitLayout, focus: Tab) {
        var seen = Set<ObjectIdentifier>()
        let group = group.filter { tabs.contains($0) && seen.insert(ObjectIdentifier($0)).inserted }.prefix(SplitGroup.maxTabs)
        guard group.count > 1, group.contains(focus) else { return }
        split = SplitGroup(tabs: Array(group), layout: layout)
        gatherSplitTabs()
        sidebar.reloadTabs()
        activate(focus)
    }

    /// Adds `tab` to the split `anchor` is in, after the anchor's pane; four panes become a grid.
    /// Without a split, it starts one beside `anchor`.
    func add(_ tab: Tab, toSplitWith anchor: Tab, focus: Tab) {
        guard var group = split, group.contains(anchor) else { return split(anchor, with: tab, focus: focus) }
        guard !group.contains(tab), group.tabs.count < SplitGroup.maxTabs, tabs.contains(tab) else { return }
        var panes = group.tabs
        panes.insert(tab, at: (panes.firstIndex { $0 === anchor } ?? panes.count - 1) + 1)
        group.setTabs(panes, layout: panes.count == SplitGroup.maxTabs && group.layout != .grid ? .grid : nil)
        split = group
        gatherSplitTabs()
        sidebar.reloadTabs()
        activate(focus)
    }

    /// Ends the split. The tabs stay open, and the active one is shown alone.
    func unsplit() {
        guard split != nil else { return }
        split = nil
        sidebar.reloadTabs()
        if let activeTab { activate(activeTab) }
    }

    /// Takes `tab` out of its split and shows it alone. With two panes, that ends the split.
    func removeFromSplit(_ tab: Tab) {
        guard isPaired(tab) else { return }
        leaveSplit(tab)
        sidebar.reloadTabs()
        if let activeTab { activate(activeTab) }
    }

    /// Drops `tab` from the split model and returns the pane that should get focus in its place.
    @discardableResult
    private func leaveSplit(_ tab: Tab) -> Tab? {
        guard var group = split, let i = group.tabs.firstIndex(where: { $0 === tab }) else { return nil }
        var panes = group.tabs
        panes.remove(at: i)
        let neighbor = panes[min(i, panes.count - 1)]
        if panes.count < 2 {
            split = nil
        } else {
            group.setTabs(panes)
            split = group
        }
        return neighbor
    }

    /// Switches the split the current tab is in to `layout`, or to the next one that fits.
    func setSplitLayout(_ layout: SplitLayout?) {
        guard var group = split, let activeTab, group.contains(activeTab) else { return }
        let fitting = SplitLayout.allCases.filter { $0.fits(group.tabs.count) }
        let next = layout ?? fitting[((fitting.firstIndex(of: group.layout) ?? 0) + 1) % fitting.count]
        guard next.fits(group.tabs.count), next != group.layout else { return }
        group.setTabs(group.tabs, layout: next)
        split = group
        sidebar.reloadTabs()
        showVisibleTabs()
    }

    /// Moves every pane one place along; with two panes, they trade places.
    func swapPanes() {
        guard var group = split, let activeTab, group.contains(activeTab) else { return }
        let panes = Array(group.tabs.dropFirst()) + [group.tabs[0]]
        let dividers = group.tabs.count == 2 && group.layout != .grid ? group.dividers.map { 1 - $0 } : group.dividers
        group = SplitGroup(tabs: panes, layout: group.layout, dividers: dividers)
        split = group
        sidebar.reloadTabs()
        showVisibleTabs()
    }

    enum PaneDirection { case left, right, up, down }

    /// Focuses the nearest pane in `direction` from the focused one.
    func focusPane(_ direction: PaneDirection) {
        guard let group = split, let activeTab, let from = group.tabs.firstIndex(where: { $0 === activeTab }) else { return }
        let frames = SplitGeometry.frames(count: group.tabs.count, layout: group.layout, dividers: group.dividers,
                                          in: NSRect(x: 0, y: 0, width: 1000, height: 1000), gap: 0)
        let here = NSPoint(x: frames[from].midX, y: frames[from].midY)
        let candidates = frames.indices.filter { i in
            let f = frames[i]
            switch direction {
            case .left: return f.maxX <= frames[from].minX + 0.5 && f.maxY > frames[from].minY && f.minY < frames[from].maxY
            case .right: return f.minX >= frames[from].maxX - 0.5 && f.maxY > frames[from].minY && f.minY < frames[from].maxY
            case .up: return f.minY >= frames[from].maxY - 0.5 && f.maxX > frames[from].minX && f.minX < frames[from].maxX
            case .down: return f.maxY <= frames[from].minY + 0.5 && f.maxX > frames[from].minX && f.minX < frames[from].maxX
            }
        }
        let distance = { (i: Int) in hypot(frames[i].midX - here.x, frames[i].midY - here.y) }
        guard let target = candidates.min(by: { distance($0) < distance($1) }) else { return }
        activate(group.tabs[target])
    }

    /// Where a tab dropped on the page goes.
    enum PaneDrop: Equatable {
        /// A new pane along that edge of the page.
        case edge(NSRectEdge)
        /// In place of the pane at that index.
        case pane(Int)
    }

    /// Opens `tab` in the split the drop names. Returns false when nothing changed.
    @discardableResult
    func drop(_ tab: Tab, at target: PaneDrop) -> Bool {
        guard let active = activeTab, tabs.contains(tab) else { return false }
        let group = split.flatMap { $0.contains(active) ? $0 : nil }
        switch target {
        case .edge(let edge):
            let horizontal = edge == .minX || edge == .maxX
            let first = edge == .minX || edge == .maxY // maxY is the top
            guard var panes = group?.tabs else {
                guard tab !== active else { return false }
                split(first ? [tab, active] : [active, tab], layout: horizontal ? .columns : .rows, focus: tab)
                return true
            }
            panes.removeAll { $0 === tab }
            guard panes.count < SplitGroup.maxTabs, panes.count > 0 else { return false }
            if first { panes.insert(tab, at: 0) } else { panes.append(tab) }
            let current = group!.layout
            let layout: SplitLayout = panes.count == 2 ? (horizontal ? .columns : .rows)
                : current == .grid || (current == .columns) == horizontal ? current : .grid
            split(panes, layout: panes.count == SplitGroup.maxTabs ? .grid : layout, focus: tab)
            return true
        case .pane(let index):
            guard var panes = group?.tabs, panes.indices.contains(index), panes[index] !== tab else { return false }
            if let from = panes.firstIndex(where: { $0 === tab }) { panes.swapAt(from, index) } else { panes[index] = tab }
            split(panes, layout: group!.layout, focus: tab)
            return true
        }
    }

    /// Keeps a split's tabs next to each other in the tab list, after its first tab.
    private func gatherSplitTabs() {
        guard let group = split else { return }
        let members = group.tabs.sorted { (tabs.firstIndex(of: $0) ?? 0) < (tabs.firstIndex(of: $1) ?? 0) }
        guard let anchor = members.first, members.allSatisfy({ $0.isPinned == anchor.isPinned }) else { return }
        for tab in members.dropFirst() {
            guard let from = tabs.firstIndex(of: tab), let at = tabs.firstIndex(of: anchor) else { continue }
            let block = members.prefix { $0 !== tab }.compactMap { tabs.firstIndex(of: $0) }.max() ?? at
            let to = from > block ? block + 1 : block
            guard from != to else { continue }
            tabs.remove(at: from)
            tabs.insert(tab, at: to)
            if isAnnounced { extensions.didMoveTab(tab, from: from, in: self) }
        }
    }

    /// A click into a visible web view makes its tab the active one (address bar, extensions, commands).
    func paneDidFocus(_ tab: Tab) {
        guard tab !== activeTab, visibleTabs.contains(tab) else { return }
        activate(tab)
    }

    func restoreSplit(_ group: [Tab], layout: SplitLayout, dividers: [CGFloat]?) {
        guard group.count > 1, group.count <= SplitGroup.maxTabs else { return }
        split = SplitGroup(tabs: group, layout: layout, dividers: dividers)
        sidebar.reloadTabs()
        showVisibleTabs()
    }

    func splitDividersDidChange(_ dividers: [CGFloat]) {
        split?.dividers = dividers
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
        guard tabs.indices.contains(from) else { return }
        // A tab moves within its own block: pinned tabs stay above the rest.
        let pinned = pinnedCount
        let bounds = tabs[from].isPinned ? 0...(pinned - 1) : pinned...(tabs.count - 1)
        let to = max(bounds.lowerBound, min(rawTo, bounds.upperBound))
        guard from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        sidebar.reloadTabs()
        if isAnnounced { extensions.didMoveTab(tab, from: from, in: self) }
    }

    // MARK: Chrome

    func focusAddressBar() { content.focusAddressBar() }

    /// Compact mode: no top bar until you point at the top edge or press ⌘L. The traffic lights hide
    /// with it where they'd sit over the page.
    func setCompact(_ compact: Bool) {
        content.setCompact(compact)
        updateTitlebarLayout()
    }

    private func updateTrafficLights() {
        guard let window else { return }
        let underLights = !window.styleMask.contains(.fullScreen) && (isSidebarCollapsed || isSidebarOnRight)
        let hide = content.isCompact && !content.isBarRevealed && underLights
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = hide }
    }

    /// ⌘E: filter and pick tabs from the keyboard in the sidebar, or the tab picker when it's hidden.
    func focusTabList() {
        if isSidebarCollapsed { CommandPalette.show(for: self, mode: .tabs, initialText: "") } else { sidebar.focusTabList() }
    }

    func toggleSidebar() {
        let collapse = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            sidebarItem.animator().isCollapsed = collapse
        }
        laidOutCollapsed = collapse
        content.sidebarDidChange(collapsed: collapse, onRight: isSidebarOnRight)
        updateTitlebarLayout()
    }

    private func sidebarCollapseDidChange() {
        guard sidebarItem.isCollapsed != laidOutCollapsed else { return }
        laidOutCollapsed = sidebarItem.isCollapsed
        content.sidebarDidChange(collapsed: laidOutCollapsed, onRight: isSidebarOnRight)
        updateTitlebarLayout()
    }

    /// Moves the divider so the tab list is `width` wide, within its limits.
    func setSidebarWidth(_ width: CGFloat) {
        let splitView = splitController.splitView
        splitView.setPosition(isSidebarOnRight ? splitView.bounds.width - width - splitView.dividerThickness : width, ofDividerAt: 0)
    }

    /// Moves the tab list to the other side of the window, keeping its width.
    func setSidebarOnRight(_ right: Bool) {
        guard right != isSidebarOnRight else { return }
        let width = sidebar.view.frame.width
        isSidebarOnRight = right
        let splitView = splitController.splitView
        splitView.autosaveName = nil
        splitController.removeSplitViewItem(sidebarItem)
        splitController.insertSplitViewItem(sidebarItem, at: right ? 1 : 0)
        // The autosave name goes on first: the split view restores that side's saved width when it lays out
        // with the name set, which would otherwise undo the width carried over below. Setting the divider
        // afterwards also saves it under the new side's name.
        splitView.autosaveName = Self.widthAutosaveName(right: right)
        splitView.layoutSubtreeIfNeeded()
        if !sidebarItem.isCollapsed {
            splitView.setPosition(right ? splitView.bounds.width - width - splitView.dividerThickness : width, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
        content.sidebarDidChange(collapsed: isSidebarCollapsed, onRight: right)
        updateTitlebarLayout()
    }

    /// Lines the top bar up with the traffic lights, and clears them when the page sits under them
    /// (sidebar hidden or on the right). Runs on setup, fullscreen changes and sidebar changes only:
    /// changing constraints from inside a layout pass loops forever in fullscreen, where the traffic
    /// lights live in a separate titlebar window and their position keeps changing.
    func updateTitlebarLayout() {
        guard let window else { return }
        let fullscreen = window.styleMask.contains(.fullScreen)
        var top = (TopBar.defaultContentTop - TopBar.height) / 2
        if !fullscreen, let close = window.standardWindowButton(.closeButton), close.window === window,
           let container = close.superview, let root = window.contentView {
            let midInWindow = container.convert(NSPoint(x: 0, y: close.frame.midY), to: nil).y
            let midFromTop = root.bounds.height - root.convert(NSPoint(x: 0, y: midInWindow), from: nil).y
            top = max(2, (midFromTop - TopBar.height / 2).rounded())
        } else if fullscreen {
            top = Theme.gutter
        }
        let underLights = !fullscreen && (isSidebarCollapsed || isSidebarOnRight)
        content.setTitlebar(barTop: top, lightsInset: underLights ? 78 - Theme.gutter : 0)
        // On the left, the traffic lights take the strip above the list, so the list starts level with the page.
        // On the right nothing sits there, so the list moves up: the first tab's chip starts level with the address pill.
        sidebar.setContentTop(isSidebarOnRight ? max(0, top - sidebar.rowChipInset) : top + TopBar.height + top)
        updateTrafficLights()
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
        // The address bar follows the active tab even while a filter hides its row.
        if tab === activeTab { content.topBar.updateChrome() }
        if tab === activeTab { window?.title = tab.displayTitle }
    }

    // MARK: NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) { updateTitlebarLayout() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTitlebarLayout() }
    func windowDidExitFullScreen(_ notification: Notification) { updateTitlebarLayout() }

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

/// Window background: one solid Graphite ground under both sidebar and cards.
final class RootViewController: NSViewController {
    private let child: NSViewController
    init(child: NSViewController) { self.child = child; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let bg = FilledView()
        bg.fill = Theme.ground
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
    /// After every resize, including the sidebar collapsing because its divider was dragged shut.
    var onResize: (() -> Void)?

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -4, dy: 0)
    }
}
