import AppKit

/// ⌘K: fuzzy-switch tabs, open bookmarks and pages from history, run any command, or open a URL / search.
/// Pages and commands you use often and recently rank higher (frecency).
/// ⌘P: the same panel limited to open tabs (all windows, most recent first).
/// ⌥⌘\ ("Split with…"): pick a tab, page or address to show beside the current tab.
@MainActor
final class CommandPalette: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    enum Mode { case everything, tabs, splitWith }

    private enum Item {
        case header(String)
        case open(String)
        case tab(Tab)
        case page(HistoryStore.Entry)
        case bookmark(BookmarkStore.Bookmark)
        case command(Command)

        var isHeader: Bool { if case .header = self { true } else { false } }
    }

    private static var current: CommandPalette?

    static func toggle(for browser: BrowserWindowController, mode: Mode) {
        if let current, current.mode == mode { close() } else { show(for: browser, mode: mode, initialText: "") }
    }

    static func show(for browser: BrowserWindowController, mode: Mode, initialText: String) {
        close()
        guard let parent = browser.window else { return }
        let palette = CommandPalette(browser: browser, mode: mode)
        current = palette
        palette.field.stringValue = initialText
        palette.anchorTop = parent.frame.maxY - max(80, parent.frame.height * 0.16)
        palette.refilter()
        palette.setFrameOrigin(NSPoint(x: parent.frame.midX - palette.frame.width / 2, y: palette.frame.minY))
        parent.addChildWindow(palette, ordered: .above)
        palette.makeKeyAndOrderFront(nil)
        palette.makeFirstResponder(palette.field)
        palette.field.currentEditor()?.selectAll(nil)
    }

    static func close() {
        guard let p = current else { return }
        current = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    private let mode: Mode
    private weak var browser: BrowserWindowController?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private var anchorTop: CGFloat = 0

    private static let width: CGFloat = 640
    private static let headerHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 40
    private static let fieldHeight: CGFloat = 56
    private static let maxListHeight: CGFloat = 420
    private static let footerHeight: CGFloat = 32

    override var canBecomeKey: Bool { true }

    private init(browser: BrowserWindowController, mode: Mode) {
        self.browser = browser
        self.mode = mode
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        delegate = self

        // A solid Graphite surface rather than a material, so it reads the same over any page.
        let bg = FilledView()
        bg.fill = Theme.surface
        bg.border = Theme.hairline
        bg.radius = 14
        bg.wantsLayer = true
        bg.layer?.masksToBounds = true

        let symbol = switch mode {
        case .tabs: "rectangle.stack"
        case .splitWith: "rectangle.split.2x1"
        case .everything: "magnifyingglass"
        }
        let glass = NSImageView(image: Theme.symbol(symbol, size: 16, weight: .medium)!)
        glass.contentTintColor = .secondaryLabelColor

        field.placeholderString = switch mode {
        case .tabs: "Switch to tab…"
        case .splitWith: "Split with a tab, a page, or an address…"
        case .everything: "Search tabs, history and commands, or enter an address"
        }
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true

        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let divider = FilledView()
        divider.fill = Theme.hairline

        // Footer: how to drive the list from the keyboard.
        let footer = FilledView()
        footer.fill = Theme.recessedFill
        let footerRule = FilledView()
        footerRule.fill = Theme.hairline
        let hints = NSTextField(labelWithString: "↑↓ move    ↩ open    esc close")
        hints.font = Theme.monoFont(11)
        hints.textColor = .secondaryLabelColor
        for v in [footerRule, hints] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(v) }

        for v in [glass, field, divider, scroll, footer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            divider.topAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight),
            divider.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerRule.topAnchor.constraint(equalTo: footer.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            hints.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            hints.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 0.5),
        ])
        contentView = bg
    }

    // MARK: Filtering

    private func candidateTabs() -> [Tab] {
        // Split partners must share the window; ⌘P searches every window.
        let windows = mode == .tabs ? AppDelegate.shared.windows : [browser].compactMap { $0 }
        return windows.flatMap(\.tabs)
            .filter { $0 !== browser?.activeTab }
            .sorted { $0.lastActivated > $1.lastActivated }
    }

    private func openURLs(_ tabs: [Tab]) -> Set<String> {
        var open = Set(tabs.compactMap { $0.currentURL?.absoluteString })
        if let current = browser?.activeTab?.currentURL?.absoluteString { open.insert(current) }
        return open
    }

    /// History pages that aren't already open in a tab or listed as bookmarks.
    private func candidatePages(excluding tabs: [Tab]) -> [HistoryStore.Entry] {
        let open = openURLs(tabs)
        return HistoryStore.shared.ranked().filter { !open.contains($0.url) && !BookmarkStore.shared.contains(URL(string: $0.url)) }
    }

    private func candidateBookmarks(excluding tabs: [Tab]) -> [BookmarkStore.Bookmark] {
        let open = openURLs(tabs)
        return BookmarkStore.shared.all.filter { !open.contains($0.url) }
    }

    private func refilter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let tabs = candidateTabs()
        let commands = Command.allCases.filter { $0.selectIndex == nil && $0 != .commandPalette && $0 != .splitWith }
        let rankedCommands = commands.enumerated()
            .sorted { (CommandUsage.frecency($0.element), -$0.offset) > (CommandUsage.frecency($1.element), -$1.offset) }
            .map(\.element)

        var result: [Item] = []
        if q.isEmpty {
            switch mode {
            case .tabs:
                result = tabs.map(Item.tab)
            case .splitWith:
                result = tabs.map(Item.tab)
                let pages = candidatePages(excluding: tabs).prefix(5)
                if !pages.isEmpty { result.append(.header("Frequent Pages")); result += pages.map(Item.page) }
            case .everything:
                if !tabs.isEmpty { result.append(.header("Recent Tabs")); result += tabs.prefix(5).map(Item.tab) }
                let bookmarks = candidateBookmarks(excluding: tabs).prefix(5)
                if !bookmarks.isEmpty { result.append(.header("Bookmarks")); result += bookmarks.map(Item.bookmark) }
                result.append(.header("Commands"))
                result += rankedCommands.map(Item.command)
            }
        } else {
            let matchedTabs = tabs.compactMap { t -> (Int, Tab)? in
                let s = max(Self.score(q, t.displayTitle) ?? .min, Self.score(q, t.currentURL?.absoluteString ?? "") ?? .min)
                return s > .min ? (s, t) : nil
            }.sorted { $0.0 > $1.0 }.map(\.1)

            if mode == .tabs {
                result = matchedTabs.map(Item.tab)
            } else {
                let matchedPages = candidatePages(excluding: tabs).compactMap { e -> (Int, HistoryStore.Entry)? in
                    guard let s = [Self.score(q, e.title ?? ""), Self.score(q, HistoryStore.bare(e.url))].compactMap({ $0 }).max() else { return nil }
                    return (s + Frecency.bonus(e.frecency), e)
                }.sorted { $0.0 > $1.0 }.prefix(6).map(\.1)
                let matchedBookmarks = candidateBookmarks(excluding: tabs).compactMap { b -> (Int, BookmarkStore.Bookmark)? in
                    guard let s = [Self.score(q, b.title), Self.score(q, HistoryStore.bare(b.url))].compactMap({ $0 }).max() else { return nil }
                    return (s, b)
                }.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
                let matchedCommands = mode == .splitWith ? [] : commands.compactMap { c in
                    Self.score(q, c.title).map { ($0 + Frecency.bonus(CommandUsage.frecency(c)), c) }
                }.sorted { $0.0 > $1.0 }.map(\.1)
                let bang = Bangs.parse(q) != nil
                let looksLikeURL = !bang && (q.contains(".") || q.contains("://") || q.hasPrefix("localhost"))
                // A !bang goes first: it's what the user asked for.
                if bang { result.append(.open(q)) }
                if looksLikeURL { result.append(.open(q)) }
                if !matchedTabs.isEmpty { result.append(.header("Tabs")); result += matchedTabs.map(Item.tab) }
                if !matchedBookmarks.isEmpty { result.append(.header("Bookmarks")); result += matchedBookmarks.map(Item.bookmark) }
                if !matchedPages.isEmpty { result.append(.header("History")); result += matchedPages.map(Item.page) }
                if !matchedCommands.isEmpty { result.append(.header("Commands")); result += matchedCommands.map(Item.command) }
                if !looksLikeURL && !bang {
                    result.append(.header("Web"))
                    result.append(.open(q))
                }
            }
        }
        items = result
        table.reloadData()
        resizeToFit()
        if let first = items.firstIndex(where: { !$0.isHeader }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// Grows/shrinks with the result count, keeping the top edge still.
    private func resizeToFit() {
        let list = items.reduce(CGFloat(0)) { $0 + ($1.isHeader ? Self.headerHeight : Self.rowHeight) }
        let empty: CGFloat = items.isEmpty ? 0 : 12
        let height = Self.fieldHeight + 1 + min(list, Self.maxListHeight) + empty + Self.footerHeight
        var frame = self.frame
        frame.size = NSSize(width: Self.width, height: height)
        frame.origin.y = anchorTop - height
        setFrame(frame, display: true)
    }

    /// Subsequence match; rewards consecutive runs and word starts.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), s = Array(text.lowercased())
        guard !q.isEmpty, !s.isEmpty else { return nil }
        var qi = 0, score = 0, last = -2
        for (i, c) in s.enumerated() where qi < q.count && c == q[qi] {
            score += (i == last + 1) ? 6 : 1
            if i == 0 || " /.-_:".contains(s[i - 1]) { score += 4 }
            last = i
            qi += 1
        }
        return qi == q.count ? score * 10 - s.count / 8 : nil
    }

    // MARK: Running

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    private func runSelected() {
        guard items.indices.contains(table.selectedRow), let browser else { return }
        let item = items[table.selectedRow]
        let inNewTab = browser.activeTab?.currentURL != nil && NSApp.currentEvent?.modifierFlags.contains(.command) == true
        Self.close()
        if mode == .splitWith { return split(with: item, in: browser) }
        switch item {
        case .header: break
        case .open(let input): browser.open(input: input, inNewTab: inNewTab)
        case .page(let entry): browser.open(input: entry.url, inNewTab: inNewTab)
        case .bookmark(let bookmark): browser.open(input: bookmark.url, inNewTab: inNewTab)
        case .tab(let tab):
            tab.owner?.activate(tab)
            tab.owner?.window?.makeKeyAndOrderFront(nil)
        case .command(let cmd):
            CommandUsage.record(cmd)
            CommandRouter.perform(cmd, in: browser)
        }
    }

    /// Shows the picked tab, or a new tab for the picked page or address, beside the current tab.
    private func split(with item: Item, in browser: BrowserWindowController) {
        guard let active = browser.activeTab else { return }
        let partner: Tab
        switch item {
        case .tab(let tab): partner = tab
        case .open(let input):
            guard let url = BrowserEngine.shared.resolve(input: input) else { return }
            partner = browser.newTab(url: url, activate: false, after: active)
        case .page(let entry):
            guard let url = URL(string: entry.url) else { return }
            partner = browser.newTab(url: url, activate: false, after: active)
        case .bookmark(let bookmark):
            guard let url = URL(string: bookmark.url) else { return }
            partner = browser.newTab(url: url, activate: false, after: active)
        case .header, .command: return
        }
        // In a split with room, the pick joins it; otherwise it starts a new pair.
        if browser.isPaired(active), browser.split!.tabs.count < SplitGroup.maxTabs, !browser.isPaired(partner) {
            browser.add(partner, toSplitWith: active, focus: partner)
        } else {
            browser.split(active, with: partner, focus: partner)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        var row = table.selectedRow
        repeat { row += delta } while items.indices.contains(row) && items[row].isHeader
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        // Keep the section header visible when moving to the first row of a section.
        table.scrollRowToVisible(row > 0 && items[row - 1].isHeader ? row - 1 : row)
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)   // also ⌃N
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)    // also ⌃P
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): Self.close()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if Self.current === self { Self.close() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].isHeader ? Self.headerHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { items[row].isHeader }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !items[row].isHeader }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let label = NSTextField(labelWithAttributedString: Theme.sectionTitle(title))
            let v = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -5),
            ])
            return v
        case .open(let input):
            if let (bang, query) = Bangs.parse(input) {
                return PaletteCell(icon: Theme.symbol(query.isEmpty ? "arrow.up.forward.app" : "magnifyingglass", size: 14),
                                   tinted: true,
                                   title: query.isEmpty ? "Open \(bang.name)" : "Search \(bang.name) for “\(query)”",
                                   subtitle: "!\(bang.trigger)",
                                   accessory: KeycapView(glyphs: ["↩"]))
            }
            let url = BrowserEngine.shared.resolve(input: input)
            let searchPrefix = BrowserEngine.shared.searchTemplate.components(separatedBy: "%s")[0]
            let isSearch = url?.absoluteString.hasPrefix(searchPrefix) ?? false
            return PaletteCell(icon: Theme.symbol(isSearch ? "magnifyingglass" : "arrow.up.forward.app", size: 14),
                               tinted: true,
                               title: isSearch ? "Search the web for “\(input)”" : "Open \(Theme.displayString(for: url))",
                               subtitle: isSearch ? URL(string: searchPrefix)?.host?.replacingOccurrences(of: "www.", with: "") ?? "" : (url?.absoluteString ?? ""),
                               accessory: KeycapView(glyphs: ["↩"]))
        case .tab(let tab):
            let otherWindow = tab.owner !== browser
            let index = AppDelegate.shared.windows.firstIndex { $0 === tab.owner }.map { "Window \($0 + 1)" }
            return PaletteCell(icon: tab.favicon ?? Monogram.image(for: tab.currentURL, title: tab.displayTitle),
                               tinted: false,
                               title: tab.displayTitle,
                               subtitle: Theme.displayString(for: tab.currentURL),
                               accessory: otherWindow ? Self.tag(index ?? "") : nil)
        case .page(let entry):
            let url = URL(string: entry.url)
            return PaletteCell(icon: FaviconLoader.cached(for: url) ?? Monogram.image(for: url, title: entry.title ?? ""),
                               tinted: false,
                               title: entry.title?.isEmpty == false ? entry.title! : HistoryStore.bare(entry.url),
                               subtitle: HistoryStore.bare(entry.url),
                               accessory: nil)
        case .bookmark(let bookmark):
            let url = URL(string: bookmark.url)
            let star = NSImageView(image: Theme.symbol("star.fill", size: 10) ?? NSImage())
            star.contentTintColor = .tertiaryLabelColor
            return PaletteCell(icon: FaviconLoader.cached(for: url) ?? Monogram.image(for: url, title: bookmark.title),
                               tinted: false,
                               title: bookmark.title,
                               subtitle: HistoryStore.bare(bookmark.url),
                               accessory: star)
        case .command(let cmd):
            let chord = Keymap.shared.primaryChord(for: cmd)
            return PaletteCell(icon: Theme.symbol(cmd.symbol, size: 14) ?? Theme.symbol("command", size: 14),
                               tinted: true,
                               title: cmd.title.replacingOccurrences(of: "…", with: ""),
                               subtitle: "",
                               accessory: chord.map { KeycapView(glyphs: $0.glyphs) })
        }
    }

    private static func tag(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.monoFont(11)
        l.textColor = .secondaryLabelColor
        return l
    }
}

private final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.paletteSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) {}
}

private final class PaletteCell: NSTableCellView {
    init(icon: NSImage?, tinted: Bool, title: String, subtitle: String, accessory: NSView?) {
        super.init(frame: .zero)
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.contentTintColor = tinted ? .secondaryLabelColor : nil
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3
        iconView.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = Theme.monoFont(11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        let text = NSStackView(views: [titleLabel, sub])
        text.spacing = 8
        for v in [iconView, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        var constraints = [
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }
}
