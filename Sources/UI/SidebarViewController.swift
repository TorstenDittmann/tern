import AppKit
import WebKit

private extension NSPasteboard.PasteboardType {
    static let tabRow = NSPasteboard.PasteboardType("dev.tern.tab-row")
}

/// Vertical tab strip: nav buttons beside the traffic lights, address pill, tab list,
/// and a bottom bar with "New Tab" and extension actions.
/// The tab list is a view-based NSTableView, so only visible rows have views.
@MainActor
final class SidebarViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let addressPill = AddressPill()
    private var addressField: AddressField { addressPill.field }
    private lazy var backButton = HoverButton(symbol: "chevron.backward", label: "Back", target: self, action: #selector(backClicked))
    private lazy var forwardButton = HoverButton(symbol: "chevron.forward", label: "Forward", target: self, action: #selector(forwardClicked))
    private lazy var reloadButton = HoverButton(symbol: "arrow.clockwise", label: "Reload", target: self, action: #selector(reloadClicked))
    private let extensionStack = NSStackView()
    private let tableView = TabTableView()
    private var navTop: NSLayoutConstraint!
    private var navLeading: NSLayoutConstraint!
    private var windowObservers: [NSObjectProtocol] = []
    private var isSyncingSelection = false
    private var actionButtons: [ObjectIdentifier: ExtensionActionButton] = [:]
    private let agentPill = AgentPill()
    private var agentObserver: NSObjectProtocol?

    private var tabs: [Tab] { browser?.tabs ?? [] }

    override func loadView() {
        let root = NSView()

        // Row 1: leaves room for the traffic lights, then sidebar + history buttons.
        let nav = NSStackView(views: [NSView(), backButton, forwardButton, reloadButton])
        nav.spacing = 0
        nav.translatesAutoresizingMaskIntoConstraints = false

        addressField.delegate = self

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
        tableView.menu = makeContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar
        let newTab = NewTabButton(target: self, action: #selector(newTabClicked))
        extensionStack.orientation = .horizontal
        extensionStack.spacing = 2
        agentPill.isHidden = !AgentActivity.shared.isActive
        agentObserver = NotificationCenter.default.addObserver(forName: AgentActivity.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.agentPill.isHidden = !AgentActivity.shared.isActive }
        }
        let bottom = NSStackView(views: [newTab, agentPill, NSView(), extensionStack])
        bottom.spacing = 4
        bottom.translatesAutoresizingMaskIntoConstraints = false

        for v in [nav, addressPill, scroll, bottom] as [NSView] { root.addSubview(v) }
        addressPill.translatesAutoresizingMaskIntoConstraints = false

        let inset: CGFloat = 10
        navTop = nav.topAnchor.constraint(equalTo: root.topAnchor, constant: 2)
        navLeading = nav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 78) // traffic lights
        NSLayoutConstraint.activate([
            navTop,
            navLeading,
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset + 2),
            nav.heightAnchor.constraint(equalToConstant: 26),

            addressPill.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 10),
            addressPill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            addressPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            addressPill.heightAnchor.constraint(equalToConstant: 34),

            scroll.topAnchor.constraint(equalTo: addressPill.bottomAnchor, constant: 12),
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

    override func viewDidAppear() {
        super.viewDidAppear()
        guard windowObservers.isEmpty, let window = view.window else { return }
        let names: [Notification.Name] = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                          NSWindow.willEnterFullScreenNotification]
        windowObservers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTitlebarLayout() }
            }
        }
        updateTitlebarLayout()
    }

    /// Lines the nav buttons up with the traffic lights. Runs on appear and fullscreen changes only:
    /// changing constraints from inside a layout pass loops forever in fullscreen, where the traffic
    /// lights live in a separate titlebar window and their position keeps changing.
    private func updateTitlebarLayout() {
        guard let window = view.window else { return }
        if window.styleMask.contains(.fullScreen) {
            navTop.constant = 8
            navLeading.constant = 10
            return
        }
        navLeading.constant = 78
        guard let close = window.standardWindowButton(.closeButton), close.window === window,
              let container = close.superview else { return }
        view.layoutSubtreeIfNeeded()
        let midInWindow = container.convert(NSPoint(x: 0, y: close.frame.midY), to: nil).y
        let midInView = view.convert(NSPoint(x: 0, y: midInWindow), from: nil).y
        navTop.constant = max(0, view.bounds.height - midInView - 13)
    }

    // MARK: Updates from the window

    func reloadTabs() {
        tableView.reloadData()
        syncSelection()
    }

    func reload(_ tab: Tab) {
        guard let row = tabs.firstIndex(of: tab) else { return }
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
            cell.configure(with: tab)
        }
        if tab.isActive { updateChrome() }
    }

    func activeTabDidChange() {
        syncSelection()
        updateChrome()
        updateExtensionActions()
    }

    func focusAddressField() {
        view.window?.makeFirstResponder(addressField)
    }

    private func syncSelection() {
        guard let active = browser?.activeTab, let row = tabs.firstIndex(of: active) else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isSyncingSelection = false
        for r in 0..<tableView.numberOfRows {
            (tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? TabCellView)?.isSelected = (r == row)
        }
    }

    private func updateChrome() {
        let tab = browser?.activeTab
        addressPill.show(url: tab?.currentURL)
        backButton.isEnabled = tab?.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab?.webView?.canGoForward ?? false
        let loading = tab?.isLoading == true
        reloadButton.image = Theme.symbol(loading ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = loading ? "Stop" : "Reload"
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

    @objc private func backClicked() { browser?.activeTab?.webView?.goBack() }
    @objc private func forwardClicked() { browser?.activeTab?.webView?.goForward() }
    @objc private func reloadClicked() {
        guard let wv = browser?.activeTab?.webView else { return }
        if wv.isLoading { wv.stopLoading() } else { wv.reload() }
    }
    @objc private func newTabClicked() { browser?.newTab(url: nil) }

    private func closeTab(atRow row: Int) {
        guard tabs.indices.contains(row) else { return }
        browser?.close(tabs[row])
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)?] = [
            ("Open in Split View", #selector(ctxSplit)),
            nil,
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

    private var clickedTab: Tab? { tabs.indices.contains(tableView.clickedRow) ? tabs[tableView.clickedRow] : nil }
    @objc private func ctxSplit() {
        guard let browser, let clicked = clickedTab, let active = browser.activeTab else { return }
        if clicked === active { browser.toggleSplit() } else { browser.split(active, with: clicked, focus: clicked) }
    }
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

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: TabRowView.reuseID, owner: nil) as? TabRowView) ?? TabRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TabCellView.reuseID, owner: nil) as? TabCellView) ?? TabCellView()
        let tab = tabs[row]
        cell.configure(with: tab)
        cell.isSelected = tab.isActive
        cell.isPaired = browser?.isPaired(tab) ?? false
        cell.onClose = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.closeTab(atRow: self.tableView.row(for: cell))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, tabs.indices.contains(tableView.selectedRow) else { return }
        browser?.activate(tabs[tableView.selectedRow])
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .tabRow)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: .tabRow), let from = Int(s) else { return false }
        browser?.moveTab(from: from, to: row > from ? row - 1 : row)
        return true
    }
}

// MARK: - Address field

extension SidebarViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            browser?.open(input: addressField.stringValue, inNewTab: newTab)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.makeFirstResponder(browser?.activeTab?.webView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        addressPill.show(url: browser?.activeTab?.currentURL)
    }
}

/// Rounded field that shows just the host ("github.com") and the full URL while editing.
final class AddressPill: FilledView {
    let field = AddressField()
    private let icon = NSImageView()
    private var url: URL?

    init() {
        super.init(frame: .zero)
        fill = Theme.fieldFill
        radius = 9

        icon.contentTintColor = .tertiaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "Search or enter URL"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        for v in [icon, field] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(url: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(url: URL?) {
        self.url = url
        guard !field.isEditing else { return }
        field.stringValue = Theme.displayString(for: url)
        field.toolTip = url?.absoluteString
        let secure = url?.scheme == "https"
        icon.image = Theme.symbol(url == nil ? "magnifyingglass" : (secure ? "lock.fill" : "globe"), size: 11, weight: .semibold)
    }

    private func setFocused(_ focused: Bool) {
        fill = focused ? Theme.fieldFocusedFill : Theme.fieldFill
        border = focused ? NSColor.controlAccentColor.withAlphaComponent(0.6) : nil
        if focused {
            field.stringValue = url?.absoluteString ?? ""
            icon.image = Theme.symbol("magnifyingglass", size: 11, weight: .semibold)
        }
    }

    // Clicking anywhere on the pill focuses the field.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

final class AddressField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            DispatchQueue.main.async { self.currentEditor()?.selectAll(nil) }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

final class TabTableView: NSTableView {
    var onMiddleClick: ((Int) -> Void)?

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) }
    }

    // No focus ring / emphasized blue: selection is drawn by TabRowView.
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Rows

/// Draws the selected tab as a raised chip and a soft fill on hover.
final class TabRowView: NSTableRowView {
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
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(effectiveAppearance.isDark ? 0.25 : 0.08)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Theme.selectedFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

final class TabCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("TabCell")

    var onClose: (() -> Void)?
    var isSelected = false { didSet { updateState() } }
    var isHovering = false { didSet { updateState() } }
    var isPaired = false { didSet { updateState() } }
    private var isAgentDriving = false

    private let icon = NSImageView()
    private let pairIcon = NSImageView(image: Theme.symbol("rectangle.split.2x1", size: 11, weight: .medium)!)
    private let agentIcon = NSImageView(image: Theme.symbol("cursorarrow.rays", size: 11, weight: .semibold)!)
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

        pairIcon.contentTintColor = .tertiaryLabelColor
        pairIcon.toolTip = "In split view"
        agentIcon.contentTintColor = AgentRingView.color
        agentIcon.toolTip = "An agent is driving this tab"
        for v in [icon, spinner, title, closeButton, pairIcon, agentIcon] as [NSView] {
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
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            pairIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            pairIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            agentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
        updateState()
    }

    private func updateState() {
        closeButton.isHidden = !(isHovering || isSelected)
        agentIcon.isHidden = !isAgentDriving || !closeButton.isHidden
        pairIcon.isHidden = !isPaired || !closeButton.isHidden || !agentIcon.isHidden
        title.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        title.textColor = isSelected ? .labelColor : (suspended ? .tertiaryLabelColor : .secondaryLabelColor)
        // Suspended tabs are dimmed: they cost no memory until opened.
        icon.alphaValue = suspended && !isSelected ? 0.5 : 1
    }

    @objc private func closeClicked() { onClose?() }
}

// MARK: - Bottom bar

/// "Agent connected": shown while an agent drives a tab or listens for events.
final class AgentPill: FilledView {
    init() {
        super.init(frame: .zero)
        fill = AgentRingView.color.withAlphaComponent(0.15)
        radius = 10
        toolTip = "A coding agent is using Tern through the agent API"
        let dot = FilledView()
        dot.fill = AgentRingView.color
        dot.radius = 3
        let label = NSTextField(labelWithString: "Agent connected")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = AgentRingView.color
        let stack = NSStackView(views: [dot, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

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
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 20
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
