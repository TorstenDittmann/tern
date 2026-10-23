import AppKit

/// History (⌘Y) and Bookmarks (⌥⌘B) in one window: search, open (↩ or double-click; ⌘ for a
/// new tab), copy, rename a bookmark, and delete (⌫).
@MainActor
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static let shared = LibraryWindow()

    enum Section: Int { case history, bookmarks }

    struct Row: Equatable {
        let url: String
        let title: String
        let date: Date
    }

    private let picker = NSSegmentedControl(labels: ["History", "Bookmarks"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = LibraryTableView()
    private let empty = NSTextField(labelWithString: "")
    private(set) var section = Section.history
    private(set) var rows: [Row] = []
    private var observer: Any?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Library"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TernLibrary")
        super.init(window: window)
        build()
        observer = NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.section == .bookmarks { self?.reload() } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ section: Section) {
        self.section = section
        picker.selectedSegment = section.rawValue
        search.stringValue = ""
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    private func build() {
        picker.target = self
        picker.action = #selector(sectionChanged)
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        for (id, title, width) in [("title", "Title", 300.0), ("url", "Address", 280.0), ("date", "Date", 140.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        let top = NSStackView(views: [picker, search])
        top.spacing = 10
        for v in [top, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        let root = NSView()
        root.addSubview(top)
        root.addSubview(scroll)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window?.contentView = root
    }

    func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let all: [Row]
        switch section {
        case .history:
            all = HistoryStore.shared.entries.values.sorted { $0.lastVisit > $1.lastVisit }
                .map { Row(url: $0.url, title: $0.title?.isEmpty == false ? $0.title! : HistoryStore.bare($0.url), date: $0.lastVisit) }
        case .bookmarks:
            all = BookmarkStore.shared.all.map { Row(url: $0.url, title: $0.title, date: $0.added) }
        }
        rows = q.isEmpty ? all : all.filter {
            CommandPalette.score(q, $0.title) != nil || CommandPalette.score(q, HistoryStore.bare($0.url)) != nil
        }
        table.tableColumns.last?.title = section == .history ? "Last Visited" : "Added"
        table.reloadData()
        empty.stringValue = !rows.isEmpty ? "" : !q.isEmpty ? "No matches" : section == .history ? "No history yet" : "No bookmarks yet. Press ⌘D on a page to add one."
        empty.isHidden = !rows.isEmpty
    }

    @objc private func sectionChanged() {
        section = Section(rawValue: picker.selectedSegment) ?? .history
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            window?.makeFirstResponder(table)
            if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            openSelected()
        default: return false
        }
        return true
    }

    // MARK: Actions

    private var selectedRows: [Row] {
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// The browser window that was in front before the library.
    private var targetBrowser: BrowserWindowController {
        let app = AppDelegate.shared
        return NSApp.orderedWindows.lazy.compactMap { w in app.windows.first { $0.window === w } }.first
            ?? app.windows.last ?? app.openWindow()
    }

    @objc func openSelected() {
        let picked = selectedRows
        guard !picked.isEmpty else { return }
        let newTab = picked.count > 1 || NSApp.currentEvent?.modifierFlags.contains(.command) == true
        open(picked, inNewTabs: newTab)
    }

    func open(_ picked: [Row], inNewTabs: Bool) {
        let browser = targetBrowser
        let urls = picked.compactMap { URL(string: $0.url) }
        if !inNewTabs, urls.count == 1, let tab = browser.activeTab {
            tab.load(urls[0])
        } else {
            for (i, url) in urls.enumerated() { browser.newTab(url: url, activate: i == urls.count - 1) }
        }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openInNewTabs() { open(selectedRows, inNewTabs: true) }

    @objc private func copyAddresses() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedRows.map(\.url).joined(separator: "\n"), forType: .string)
    }

    @objc func deleteSelected() {
        let picked = selectedRows
        guard !picked.isEmpty else { return }
        for row in picked {
            if section == .history { HistoryStore.shared.remove(row.url) } else { BookmarkStore.shared.remove(row.url) }
        }
        let first = table.selectedRowIndexes.first ?? 0
        reload()
        if !rows.isEmpty { table.selectRowIndexes([min(first, rows.count - 1)], byExtendingSelection: false) }
    }

    @objc private func renameBookmark() {
        guard let row = selectedRows.first, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        let field = NSTextField(string: row.title)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { BookmarkStore.shared.rename(row.url, to: field.stringValue) }
        }
    }

    @objc private func bookmarkSelected() {
        for row in selectedRows { if let url = URL(string: row.url) { BookmarkStore.shared.add(url, title: row.title) } }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: openSelected(); return true
        case 51, 117: deleteSelected(); return true
        default: return false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !selectedRows.isEmpty else { return }
        menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTabs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Address", action: #selector(copyAddresses), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if section == .bookmarks {
            menu.addItem(withTitle: "Rename…", action: #selector(renameBookmark), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Add Bookmark", action: #selector(bookmarkSelected), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: section == .history ? "Remove from History" : "Delete Bookmark",
                     action: #selector(deleteSelected), keyEquivalent: "").target = self
    }

    // MARK: Table

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell = NSTableCellView()
        let text: NSTextField
        switch column?.identifier.rawValue {
        case "title":
            let url = URL(string: item.url)
            let icon = NSImageView(image: FaviconLoader.cached(for: url) ?? Monogram.image(for: url, title: item.title))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            text = NSTextField(labelWithString: item.title)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            ])
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8).isActive = true
        case "url":
            text = NSTextField(labelWithString: HistoryStore.bare(item.url))
            text.textColor = .secondaryLabelColor
        default:
            text = NSTextField(labelWithString: Self.dateFormatter.string(from: item.date))
            text.textColor = .secondaryLabelColor
        }
        text.lineBreakMode = .byTruncatingTail
        if text.superview == nil {
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Passes ↩ and ⌫ to the library before the table's own handling.
final class LibraryTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
