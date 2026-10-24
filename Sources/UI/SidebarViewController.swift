import AppKit
import WebKit

private extension NSPasteboard.PasteboardType {
    static let tabRow = NSPasteboard.PasteboardType("dev.tern.tab-row")
}

/// Vertical tab strip: the tab list and a bottom bar with "New Tab" and extension actions.
/// The address bar and history buttons live in the top bar above the page.
/// The tab list is a view-based NSTableView, so only visible rows have views.
@MainActor
final class SidebarViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let extensionStack = NSStackView()
    private let tableView = TabTableView()
    private var listTop: NSLayoutConstraint!
    private var isSyncingSelection = false
    private var actionButtons: [ObjectIdentifier: ExtensionActionButton] = [:]
    private lazy var newTab = NewTabButton(target: self, action: #selector(newTabClicked))
    /// Below this width the bottom bar drops its label: "New Tab" becomes a +.
    private static let compactWidth: CGFloat = 170
    private let filterPill = FilterPill()
    private let pinnedView = PinnedTabsView()
    private var pinnedGap: NSLayoutConstraint!
    /// The tab a context menu was opened on when it isn't a row (a pinned tile).
    private var contextTab: Tab?
    private var filterHeight: NSLayoutConstraint!
    private var filterGap: NSLayoutConstraint!

    private var tabs: [Tab] { browser?.tabs ?? [] }
    /// The tabs the list shows: all of them, or those matching the filter while the tab list has focus.
    private var rows: [Tab] = []
    private var filter = ""
    /// ⌘E: the tab list has keyboard focus. Typing filters, ↑↓ move, ↩ opens, ⌘⌫ closes, esc leaves.
    private(set) var isTabListFocused = false
    var visibleRowCount: Int { rows.count }
    var pinnedTileCount: Int { pinnedView.tileCount }

    override func loadView() {
        let root = NSView()

        // Tab list
        tableView.addTableColumn(NSTableColumn(identifier: .init("tab")))
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = Theme.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.tabRow])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onMiddleClick = { [weak self] row in self?.closeTab(atRow: row) }
        tableView.onKey = { [weak self] event in self?.handleTabListKey(event) ?? false }
        tableView.onResign = { [weak self] in
            // Clicking the page or the address bar ends keyboard mode.
            DispatchQueue.main.async {
                guard let self, self.isTabListFocused, self.view.window?.firstResponder !== self.tableView else { return }
                self.leaveTabList(focusPage: false)
            }
        }
        tableView.menu = makeContextMenu()
        tableView.onMenu = { [weak self] in self?.contextTab = nil }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar
        extensionStack.orientation = .horizontal
        extensionStack.spacing = 2
        let bottom = NSStackView(views: [newTab, NSView(), extensionStack])
        bottom.spacing = 4
        // Nothing in the bottom bar may hold the sidebar wider than the user drags it: it compacts, then clips.
        bottom.setClippingResistancePriority(.defaultLow, for: .horizontal)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        // Pinned tabs: favicon tiles above the list.
        pinnedView.onSelect = { [weak self] tab in self?.leaveTabList(focusPage: false); self?.browser?.activate(tab) }
        pinnedView.onClose = { [weak self] tab in self?.browser?.close(tab) }
        pinnedView.menuForTab = { [weak self] tab in
            guard let self else { return nil }
            self.contextTab = tab
            return self.tableView.menu
        }
        pinnedView.translatesAutoresizingMaskIntoConstraints = false

        filterPill.isHidden = true
        for v in [pinnedView, filterPill, scroll, bottom] as [NSView] { root.addSubview(v) }
        filterPill.translatesAutoresizingMaskIntoConstraints = false

        let inset: CGFloat = 10
        filterHeight = filterPill.heightAnchor.constraint(equalToConstant: 0)
        pinnedGap = filterPill.topAnchor.constraint(equalTo: pinnedView.bottomAnchor, constant: 0)
        filterGap = scroll.topAnchor.constraint(equalTo: filterPill.bottomAnchor, constant: 0)
        // Lines the pinned tiles, or the first tab, up with the top of the page, below the top bar.
        listTop = pinnedView.topAnchor.constraint(equalTo: root.topAnchor, constant: TopBar.defaultContentTop)
        NSLayoutConstraint.activate([
            listTop,
            pinnedView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            pinnedView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            pinnedGap,

            filterPill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            filterPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            filterHeight,
            filterGap,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -6),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            bottom.heightAnchor.constraint(equalToConstant: 30),
        ])
        view = root
    }

    /// Distance from the window top to the page cards, so the first tab lines up with them.
    var contentTop: CGFloat { listTop?.constant ?? 0 }

    func setContentTop(_ top: CGFloat) {
        loadViewIfNeeded()
        listTop.constant = top
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        newTab.isCompact = view.bounds.width < Self.compactWidth
    }

    /// For the smoke test: whether the bottom bar shows just its icons, and the New Tab button's width.
    var bottomBarCompact: (isCompact: Bool, newTabWidth: CGFloat) { (newTab.isCompact, newTab.frame.width) }

    /// Space between a row's edge and its chip (half the gap between rows).
    var rowChipInset: CGFloat { tableView.intercellSpacing.height / 2 }

    /// The first row, the split block a split starting there would get, and the list's visible area,
    /// in window coordinates (for the smoke test).
    var firstRowFrame: (row: NSRect, block: NSRect, visible: NSRect)? {
        guard tableView.numberOfRows > 0, let clip = tableView.enclosingScrollView?.contentView else { return nil }
        return (tableView.convert(tableView.rect(ofRow: 0), to: nil), tableView.convert(tableView.blockRect(0...0), to: nil),
                clip.convert(clip.bounds, to: nil))
    }

    // MARK: Updates from the window

    func reloadTabs() {
        let highlighted = tableView.selectedRow
        updatePinned()
        refreshRows()
        tableView.splitRuns = splitRuns()
        tableView.reloadData()
        if isTabListFocused { highlight(row: min(max(highlighted, 0), rows.count - 1)) } else { syncSelection() }
    }

    /// Pinned tabs show as tiles, so the list leaves them out, except while filtering (⌘E), where every tab can match.
    private func refreshRows() {
        rows = filter.isEmpty ? tabs.filter { !$0.isPinned } : tabs.filter { tab in
            CommandPalette.score(filter, tab.displayTitle) != nil
                || CommandPalette.score(filter, HistoryStore.bare(tab.currentURL?.absoluteString ?? "")) != nil
        }
    }

    /// Runs of neighboring rows whose tabs are in the split, drawn as one block in the list.
    private(set) var lastSplitRuns: [ClosedRange<Int>] = []
    private func splitRuns() -> [TabTableView.SplitRun] {
        guard let browser, let group = browser.split else { lastSplitRuns = []; return [] }
        var runs: [ClosedRange<Int>] = []
        for (i, tab) in rows.enumerated() where group.contains(tab) {
            if let last = runs.last, last.upperBound == i - 1 { runs[runs.count - 1] = last.lowerBound...i } else { runs.append(i...i) }
        }
        lastSplitRuns = runs
        let onScreen = browser.activeTab.map(group.contains) ?? false
        return runs.map { TabTableView.SplitRun(rows: $0, onScreen: onScreen) }
    }

    func reload(_ tab: Tab) {
        if tab.isPinned { pinnedView.refresh(tab) }
        guard let row = rows.firstIndex(of: tab),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView else { return }
        cell.configure(with: tab)
    }

    private func updatePinned() {
        let pinned = tabs.filter(\.isPinned)
        pinnedView.show(pinned, active: browser?.activeTab)
        pinnedGap?.constant = pinned.isEmpty ? 0 : 10
    }

    func activeTabDidChange() {
        updatePinned()
        tableView.splitRuns = splitRuns()
        refreshSplitGlyphs()
        if !isTabListFocused { syncSelection() }
        updateExtensionActions()
    }

    private func syncSelection() {
        // A pinned active tab has no row: nothing in the list is selected.
        highlight(row: browser?.activeTab.flatMap { rows.firstIndex(of: $0) } ?? -1)
    }

    /// Selects a row without activating its tab.
    private func highlight(row: Int) {
        isSyncingSelection = true
        if rows.indices.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
        for r in 0..<tableView.numberOfRows {
            (tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? TabCellView)?.isSelected = (r == row)
        }
    }

    // MARK: Keyboard tab list

    func focusTabList() {
        isTabListFocused = true
        tableView.acceptsKeys = true
        setFilter("")
        filterPill.isHidden = false
        filterHeight.constant = 28
        filterGap.constant = 6
        view.window?.makeFirstResponder(tableView)
        if let active = browser?.activeTab, let row = rows.firstIndex(of: active) { highlight(row: row) }
    }

    func leaveTabList(focusPage: Bool) {
        guard isTabListFocused else { return }
        isTabListFocused = false
        tableView.acceptsKeys = false
        filter = ""
        filterPill.isHidden = true
        filterHeight.constant = 0
        filterGap.constant = 0
        reloadTabs()
        if focusPage, let webView = browser?.activeTab?.webView { view.window?.makeFirstResponder(webView) }
    }

    private func setFilter(_ text: String) {
        filter = text
        filterPill.text = text
        refreshRows()
        tableView.splitRuns = splitRuns()
        tableView.reloadData()
        let activeRow = browser?.activeTab.flatMap { rows.firstIndex(of: $0) }
        highlight(row: text.isEmpty ? (activeRow ?? 0) : 0)
    }

    /// Keys while the tab list has focus. Returns false for keys it leaves to the responder chain.
    func handleTabListKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let row = tableView.selectedRow
        switch event.keyCode {
        case 53: // esc: clear the filter, then leave
            if filter.isEmpty { leaveTabList(focusPage: true) } else { setFilter("") }
            return true
        case 36, 76: // return, enter
            guard rows.indices.contains(row) else { return true }
            let tab = rows[row]
            leaveTabList(focusPage: false)
            browser?.activate(tab)
            return true
        case 125: highlight(row: min(row + 1, rows.count - 1)); return true // ↓
        case 126: highlight(row: max(row - 1, 0)); return true // ↑
        case 51, 117: // ⌘⌫ / ⌘⌦ close the highlighted tab; plain ⌫ edits the filter
            if flags.contains(.command) {
                if rows.indices.contains(row) { browser?.close(rows[row]) }
            } else if !filter.isEmpty {
                setFilter(String(filter.dropLast()))
            }
            return true
        default: break
        }
        if flags == .control, let key = event.charactersIgnoringModifiers {
            if key == "n" { highlight(row: min(row + 1, rows.count - 1)); return true }
            if key == "p" { highlight(row: max(row - 1, 0)); return true }
        }
        guard flags.isDisjoint(with: [.command, .control]), let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        setFilter(filter + chars)
        return true
    }

    // MARK: Extension actions

    func updateExtensionActions() {
        let tab = browser?.activeTab
        extensionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionButtons.removeAll()
        for ctx in ExtensionManager.shared.loadedContexts {
            guard let action = ctx.action(for: tab) else { continue }
            let button = ExtensionActionButton(target: self, action: #selector(extensionActionClicked(_:)))
            button.configure(with: action, fallbackName: ctx.webExtension.displayName ?? "Extension")
            button.identifier = .init(ctx.uniqueIdentifier)
            extensionStack.addArrangedSubview(button)
            actionButtons[ObjectIdentifier(ctx)] = button
        }
    }

    func actionButton(for context: WKWebExtensionContext) -> NSView? {
        actionButtons[ObjectIdentifier(context)]
    }

    @objc private func extensionActionClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let ctx = ExtensionManager.shared.loadedContexts.first(where: { $0.uniqueIdentifier == id }) else { return }
        ctx.performAction(for: browser?.activeTab)
    }

    // MARK: Actions

    @objc private func newTabClicked() { browser?.newTab(url: nil) }

    private func closeTab(atRow row: Int) {
        guard rows.indices.contains(row) else { return }
        browser?.close(rows[row])
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)?] = [
            ("Open in Split View", #selector(ctxSplit)),
            ("Remove from Split", #selector(ctxRemoveFromSplit)),
            ("Unsplit", #selector(ctxUnsplit)),
            nil,
            ("Pin Tab", #selector(ctxPin)),
            ("Duplicate", #selector(ctxDuplicate)), ("Copy URL", #selector(ctxCopyURL)), ("Suspend", #selector(ctxSuspend)),
            nil,
            ("Close Tab", #selector(ctxClose)), ("Close Tabs Below", #selector(ctxCloseBelow)), ("Close Other Tabs", #selector(ctxCloseOthers)),
        ]
        for item in items {
            guard let (title, sel) = item else { menu.addItem(.separator()); continue }
            menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        return menu
    }

    private var clickedTab: Tab? {
        if let contextTab { return contextTab }
        return rows.indices.contains(tableView.clickedRow) ? rows[tableView.clickedRow] : nil
    }
    @objc private func ctxPin() { clickedTab.map { browser?.setPinned($0, !$0.isPinned) } }
    @objc private func ctxSplit() {
        guard let browser, let clicked = clickedTab, let active = browser.activeTab else { return }
        if clicked === active { return browser.toggleSplit() }
        // In a split with room, the tab joins it; otherwise it pairs with the current tab.
        if browser.isPaired(active), !browser.isPaired(clicked), browser.visibleTabs.count < SplitGroup.maxTabs {
            browser.add(clicked, toSplitWith: active, focus: clicked)
        } else {
            browser.split(active, with: clicked, focus: clicked)
        }
    }
    @objc private func ctxRemoveFromSplit() { clickedTab.map { browser?.removeFromSplit($0) } }
    @objc private func ctxUnsplit() { browser?.unsplit() }
    @objc private func ctxDuplicate() { clickedTab.map { browser?.duplicate($0) } }
    @objc private func ctxSuspend() { clickedTab?.suspend() }
    @objc private func ctxClose() { clickedTab.map { browser?.close($0) } }
    @objc private func ctxCloseBelow() { clickedTab.map { browser?.closeTabs(below: $0) } }
    @objc private func ctxCloseOthers() { clickedTab.map { browser?.closeOthers(than: $0) } }
    @objc private func ctxCopyURL() {
        guard let url = clickedTab?.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: - Table

extension SidebarViewController {
    /// Moves a tab in the list. Dragging a split's tab away from the others takes it out of the split.
    func moveRow(from: Int, to: Int) {
        guard let browser, browser.tabs.indices.contains(from) else { return }
        let tab = browser.tabs[from]
        browser.moveTab(from: from, to: to)
        // A drop back in place isn't a drag out, even when the split's rows aren't next to each other.
        guard browser.isPaired(tab), let i = browser.tabs.firstIndex(of: tab), i != from else { return }
        let neighbors = [i - 1, i + 1].filter(browser.tabs.indices.contains).map { browser.tabs[$0] }
        if !neighbors.contains(where: browser.isPaired) { browser.removeFromSplit(tab) }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: TabRowView.reuseID, owner: nil) as? TabRowView) ?? TabRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TabCellView.reuseID, owner: nil) as? TabCellView) ?? TabCellView()
        let tab = rows[row]
        cell.configure(with: tab)
        cell.isSelected = isTabListFocused ? row == tableView.selectedRow : tab.isActive
        cell.splitPane = splitPane(for: tab)
        cell.onUnsplit = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = self.tableView.row(for: cell)
            if self.rows.indices.contains(row) { self.browser?.removeFromSplit(self.rows[row]) }
        }
        cell.onClose = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.closeTab(atRow: self.tableView.row(for: cell))
        }
        return cell
    }

    private func splitPane(for tab: Tab) -> TabCellView.SplitPane? {
        guard let browser, let group = browser.split, let index = group.tabs.firstIndex(where: { $0 === tab }) else { return nil }
        return .init(count: group.tabs.count, layout: group.layout, index: index,
                     onScreen: browser.activeTab.map(group.contains) ?? false)
    }

    private func refreshSplitGlyphs() {
        for r in 0..<tableView.numberOfRows where rows.indices.contains(r) {
            (tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? TabCellView)?.splitPane = splitPane(for: rows[r])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, rows.indices.contains(tableView.selectedRow) else { return }
        let tab = rows[tableView.selectedRow]
        leaveTabList(focusPage: false)
        browser?.activate(tab)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .tabRow)
        if rows.indices.contains(row) { item.setString(rows[row].id.uuidString, forType: .tabID) }
        return item
    }

    // While a tab is dragged, the page accepts it as the other half of a split.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        browser?.content.beginTabDrag()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        browser?.content.endTabDrag()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard filter.isEmpty else { return [] } // rows don't map to positions while filtered
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        // Rows leave out pinned tabs, so map them back to positions in the window's tab list.
        guard let s = info.draggingPasteboard.string(forType: .tabRow), let fromRow = Int(s), rows.indices.contains(fromRow),
              let from = tabs.firstIndex(of: rows[fromRow]) else { return false }
        let to = rows.indices.contains(row) ? tabs.firstIndex(of: rows[row]) ?? tabs.count : tabs.count
        moveRow(from: from, to: to > from ? to - 1 : to)
        return true
    }
}

final class TabTableView: NSTableView {
    /// The first rows can sit in the titlebar strip (tab list on the right), where the window is movable by
    /// its background: a press on a tab must start a tab drag there, never move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Rows of the split's tabs, drawn behind them as one block so the group reads as a unit.
    struct SplitRun: Equatable { var rows: ClosedRange<Int>; var onScreen: Bool }
    var splitRuns: [SplitRun] = [] { didSet { if splitRuns != oldValue { needsDisplay = true } } }

    /// The block behind a run of split rows. The row rects already leave a point around each chip; staying
    /// inside them keeps the block's top edge on screen when the split's first tab is the first row.
    func blockRect(_ rows: ClosedRange<Int>) -> NSRect {
        rect(ofRow: rows.lowerBound).union(rect(ofRow: rows.upperBound))
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        for run in splitRuns where run.rows.upperBound < numberOfRows {
            let rect = blockRect(run.rows)
            guard rect.intersects(clipRect) else { continue }
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.rowRadius + 2, yRadius: Theme.rowRadius + 2)
            Theme.accent.withAlphaComponent(run.onScreen ? 0.12 : 0.06).setFill()
            path.fill()
            Theme.accent.withAlphaComponent(run.onScreen ? 0.35 : 0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    var onMiddleClick: ((Int) -> Void)?
    /// Keys while the list has keyboard focus (⌘E); return false to pass a key on.
    var onKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    var onMenu: (() -> Void)?
    /// Off except in keyboard mode, so clicking a tab leaves focus on the page.
    var acceptsKeys = false

    override func keyDown(with event: NSEvent) {
        if acceptsKeys, onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResign?() }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
        return super.menu(for: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) }
    }

    // No focus ring / emphasized blue: selection is drawn by TabRowView.
    override var acceptsFirstResponder: Bool { acceptsKeys }
}

// MARK: - Rows

/// Draws the selected tab as a raised chip and a soft fill on hover.
final class TabRowView: NSTableRowView {
    override var mouseDownCanMoveWindow: Bool { false }
    static let reuseID = NSUserInterfaceItemIdentifier("TabRow")
    private var hovering = false { didSet { needsDisplay = true; cell?.isHovering = hovering } }
    private var cell: TabCellView? { subviews.first as? TabCellView }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isEmphasized: Bool { get { false } set {} }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        Theme.hoverFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.rowRadius, yRadius: Theme.rowRadius).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: Theme.rowRadius, yRadius: Theme.rowRadius)
        NSGraphicsContext.saveGraphicsState()
        // Dark: a flat lifted chip. Light: a white chip with a whisper of shadow.
        if !effectiveAppearance.isDark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        Theme.selectedFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

final class TabCellView: NSTableCellView {
    override var mouseDownCanMoveWindow: Bool { false }
    /// Presses on the icon and title land on the cell (which never moves the window); buttons and the
    /// pane glyph keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton || hit === glyph ? hit : self
    }
    static let reuseID = NSUserInterfaceItemIdentifier("TabCell")

    var onClose: (() -> Void)?
    var isSelected = false { didSet { updateState() } }
    var isHovering = false { didSet { updateState() } }
    /// Where the tab sits in the split, drawn as a small map of the panes.
    struct SplitPane: Equatable { var count: Int; var layout: SplitLayout; var index: Int; var onScreen: Bool }
    var splitPane: SplitPane? { didSet { if splitPane != oldValue { glyph.pane = splitPane; updateState() } } }
    var onUnsplit: (() -> Void)?
    private var isAgentDriving = false

    private let icon = NSImageView()
    private let glyph = PaneGlyph()
    private var titleToClose: NSLayoutConstraint!
    private var titleToGlyph: NSLayoutConstraint!
    private let agentIcon = NSImageView(image: Theme.symbol("cursorarrow.rays", size: 11, weight: .semibold)!)
    private let pinIcon = NSImageView(image: Theme.symbol("pin.fill", size: 10, weight: .medium)!)
    private var isPinned = false
    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton()
    private var suspended = false

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        closeButton.image = Theme.symbol("xmark", size: 9, weight: .bold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"

        glyph.onClick = { [weak self] in self?.onUnsplit?() }
        agentIcon.contentTintColor = AgentRingView.color
        agentIcon.toolTip = "An agent is driving this tab"
        pinIcon.contentTintColor = .tertiaryLabelColor
        pinIcon.toolTip = "Pinned"
        for v in [icon, spinner, title, closeButton, glyph, agentIcon, pinIcon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            glyph.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 20),
            glyph.heightAnchor.constraint(equalToConstant: 16),
            agentIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            agentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            pinIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleToClose = title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6)
        titleToGlyph = title.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -4)
        titleToClose.isActive = true
        updateState()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with tab: Tab) {
        title.stringValue = tab.displayTitle
        toolTip = tab.currentURL?.absoluteString
        icon.image = tab.favicon ?? (tab.currentURL == nil
            ? Theme.symbol("square.dashed", size: 13, weight: .regular)
            : Monogram.image(for: tab.currentURL, title: tab.displayTitle))
        icon.contentTintColor = .tertiaryLabelColor
        if tab.isLoading { spinner.startAnimation(nil); icon.isHidden = true }
        else { spinner.stopAnimation(nil); icon.isHidden = false }
        suspended = tab.isSuspended
        isAgentDriving = tab.isAgentDriving
        isPinned = tab.isPinned
        updateState()
    }

    private func updateState() {
        closeButton.isHidden = !(isHovering || isSelected)
        agentIcon.isHidden = !isAgentDriving || !closeButton.isHidden
        glyph.isHidden = splitPane == nil
        titleToClose.isActive = glyph.isHidden
        titleToGlyph.isActive = !glyph.isHidden
        pinIcon.isHidden = !isPinned || !closeButton.isHidden || !agentIcon.isHidden
        title.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        title.textColor = isSelected ? .labelColor : (suspended ? .tertiaryLabelColor : .secondaryLabelColor)
        // Suspended tabs are dimmed: they cost no memory until opened.
        icon.alphaValue = suspended && !isSelected ? 0.5 : 1
    }

    @objc private func closeClicked() { onClose?() }
}

/// A tiny map of the split's panes with this tab's pane filled in. Hovering it turns it into a button
/// that takes the tab out of the split.
final class PaneGlyph: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var pane: TabCellView.SplitPane? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pointerInside = false {
        didSet { removeIcon.isHidden = !pointerInside; needsDisplay = true }
    }
    private let removeIcon = NSImageView(image: (Theme.symbol("rectangle.badge.minus", size: 12, weight: .medium)
        ?? Theme.symbol("minus.circle", size: 12, weight: .medium))!)

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "In a split. Click to take this tab out."
        removeIcon.contentTintColor = .secondaryLabelColor
        removeIcon.isHidden = true
        removeIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeIcon)
        NSLayoutConstraint.activate([
            removeIcon.centerXAnchor.constraint(equalTo: centerXAnchor), removeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }
    // Swallow the press so the row doesn't select; act on release inside.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane else { return }
        if pointerInside {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            return
        }
        let box = NSRect(x: 2, y: 3, width: bounds.width - 4, height: bounds.height - 6)
        let frames = SplitGeometry.frames(count: pane.count, layout: pane.layout,
                                          dividers: SplitGroup.evenDividers(pane.count, pane.layout), in: box, gap: 1.5)
        let color = pane.onScreen ? Theme.accent : NSColor.secondaryLabelColor
        for (i, f) in frames.enumerated() {
            if i == pane.index {
                color.setFill()
                NSBezierPath(roundedRect: f, xRadius: 1.5, yRadius: 1.5).fill()
            } else {
                color.withAlphaComponent(0.55).setStroke()
                let path = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

extension SidebarViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(ctxPin) { item.title = clickedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab" }
        let paired = clickedTab.map { browser?.isPaired($0) ?? false } ?? false
        if item.action == #selector(ctxRemoveFromSplit) || item.action == #selector(ctxUnsplit) { item.isHidden = !paired }
        if item.action == #selector(ctxSplit), let browser, let active = browser.activeTab, let clicked = clickedTab {
            item.isHidden = paired && browser.isPaired(active)
            item.title = browser.isPaired(active) && clicked !== active && browser.visibleTabs.count < SplitGroup.maxTabs
                ? "Add to Split" : "Open in Split View"
        }
        return true
    }
}

/// Shown above the tab list while it has keyboard focus: the filter text, or how to use it.
final class FilterPill: FilledView {
    private let label = NSTextField(labelWithString: "")
    var text = "" { didSet { update() } }

    init() {
        super.init(frame: .zero)
        fill = Theme.fieldFill
        radius = 8
        let icon = NSImageView(image: Theme.symbol("line.3.horizontal.decrease", size: 11, weight: .semibold)!)
        icon.contentTintColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        for v in [icon, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        label.stringValue = text.isEmpty ? "Type to filter · ↩ open · ⌘⌫ close · esc" : text
        label.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
    }
}

// MARK: - Bottom bar

final class NewTabButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        let title = NSAttributedString(string: "New Tab", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        attributedTitle = title
        image = Theme.symbol("plus", size: 12, weight: .semibold)
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .secondaryLabelColor
        isBordered = false
        self.target = target
        self.action = action
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolTip = "New Tab (⌘T)"
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
    }

    /// Just the +, in a narrow sidebar.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            imagePosition = isCompact ? .imageOnly : .imageLeading
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += isCompact ? 14 : 20
        return s
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Theme.rowRadius
        layer?.backgroundColor = hovering ? Theme.hoverFill.cgColor : .clear
    }
}

/// Toolbar icon for an extension with a small badge capsule (Safari-style).
final class ExtensionActionButton: NSButton {
    private let badge = NSTextField(labelWithString: "")
    private let badgeBox = FilledView()
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        self.target = target
        self.action = action
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        badgeBox.fill = .systemRed
        badgeBox.radius = 6
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badgeBox.addSubview(badge)
        addSubview(badgeBox)
        for v in [badge, badgeBox] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28),
            badgeBox.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            badgeBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            badgeBox.heightAnchor.constraint(equalToConstant: 12),
            badgeBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            badgeBox.widthAnchor.constraint(greaterThanOrEqualTo: badge.widthAnchor, constant: 6),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func configure(with action: WKWebExtension.Action, fallbackName: String) {
        image = action.icon(for: NSSize(width: 18, height: 18)) ?? Theme.symbol("puzzlepiece.extension", size: 14)
        contentTintColor = .secondaryLabelColor
        toolTip = action.label.isEmpty ? fallbackName : action.label
        isEnabled = action.isEnabled
        badge.stringValue = action.badgeText
        badgeBox.isHidden = action.badgeText.isEmpty
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = hovering ? Theme.hoverFill.cgColor : .clear
    }
}
