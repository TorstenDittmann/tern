import AppKit

/// Settings (⌘,): General (search engine, tab suspension, ad blocking, agent API, history) and Shortcuts.
@MainActor
final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()

    let general = GeneralSettings()
    let shortcuts = ShortcutSettings()

    private init() {
        super.init(window: nil)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String, String)] = [(general, "General", "gearshape"), (shortcuts, "Shortcuts", "keyboard")]
        for (vc, title, symbol) in panes {
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        self.window = window
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Int = 0) {
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
        general.refresh()
        shortcuts.reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

@MainActor
final class GeneralSettings: NSViewController, NSTextFieldDelegate {
    let appearancePopup = NSPopUpButton()
    let searchPopup = NSPopUpButton()
    let customSearch = NSTextField()
    let suspendPopup = NSPopUpButton()
    let archivePopup = NSPopUpButton()
    let agentCheckbox = NSButton(checkboxWithTitle: "Let coding agents control Tern", target: nil, action: nil)
    let sidebarPopup = NSPopUpButton()
    let addressBarCheckbox = NSButton(checkboxWithTitle: "Always show the address bar", target: nil, action: nil)
    let blockingCheckbox = NSButton(checkboxWithTitle: "Block ads and trackers", target: nil, action: nil)
    let defaultBrowserButton = NSButton(title: "Make Tern the Default Browser", target: nil, action: nil)

    override func loadView() {
        title = "General"
        appearancePopup.addItems(withTitles: Preferences.Appearance.allCases.map(\.title))
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        searchPopup.addItems(withTitles: Preferences.searchEngines.map(\.name) + ["Custom…"])
        searchPopup.target = self
        searchPopup.action = #selector(searchChanged)
        customSearch.placeholderString = "https://example.com/search?q=%s"
        customSearch.delegate = self
        customSearch.widthAnchor.constraint(equalToConstant: 280).isActive = true

        suspendPopup.addItems(withTitles: Preferences.suspendChoices.map(\.name))
        suspendPopup.target = self
        suspendPopup.action = #selector(suspendChanged)
        archivePopup.addItems(withTitles: Preferences.archiveChoices.map(\.name))
        archivePopup.target = self
        archivePopup.action = #selector(archiveChanged)

        agentCheckbox.target = self
        blockingCheckbox.target = self
        blockingCheckbox.action = #selector(blockingChanged)
        agentCheckbox.action = #selector(agentChanged)

        sidebarPopup.addItems(withTitles: ["On the Left", "On the Right"])
        sidebarPopup.target = self
        sidebarPopup.action = #selector(sidebarSideChanged)
        addressBarCheckbox.target = self
        addressBarCheckbox.action = #selector(addressBarChanged)

        let clear = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .push
        defaultBrowserButton.bezelStyle = .push
        defaultBrowserButton.target = self
        defaultBrowserButton.action = #selector(makeDefaultBrowser)

        let grid = NSGridView(views: [
            [label("Appearance:"), appearancePopup],
            [label("Search engine:"), searchPopup],
            [NSGridCell.emptyContentView, customSearch],
            [label("Suspend idle tabs:"), suspendPopup],
            [NSGridCell.emptyContentView, note("Background tabs give their memory back and keep their history.")],
            [label("Archive idle tabs:"), archivePopup],
            [NSGridCell.emptyContentView, note("Tabs you haven't opened in that long close by themselves. Pinned tabs stay. Find them again in Archived Tabs… (⌘K).")],
            [label("Tab list:"), sidebarPopup],
            [label("Address bar:"), addressBarCheckbox],
            [NSGridCell.emptyContentView, note("Off, the page reaches the top of the window. Point at the top edge or press ⌘L to show the bar.")],
            [label("Privacy:"), blockingCheckbox],
            [NSGridCell.emptyContentView, note("EasyList and EasyPrivacy, plus tracking parameters like utm_source removed from links. Local dev servers are left alone. Toggle Ad Blocking for This Site in ⌘K changes one site.")],
            [label("Agent API:"), agentCheckbox],
            [NSGridCell.emptyContentView, note("A local socket for the tern CLI and MCP server. Only your user can connect.")],
            [label("History:"), clear],
            [label("Default browser:"), defaultBrowserButton],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for row in [2, 4, 6, 9, 11, 13] { grid.row(at: row).topPadding = -4 }
        for row in [1, 3, 5, 7, 8, 10, 12, 14, 15] { grid.row(at: row).topPadding = 8 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            // The pane can be taller than the grid (the window fits the tallest tab): spare room goes below.
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        appearancePopup.selectItem(at: Preferences.Appearance.allCases.firstIndex(of: Preferences.appearance) ?? 0)
        let template = Preferences.searchTemplate
        let index = Preferences.searchEngines.firstIndex { $0.template == template }
        searchPopup.selectItem(at: index ?? Preferences.searchEngines.count)
        customSearch.stringValue = index == nil ? template : ""
        customSearch.isHidden = index != nil
        let suspend = Preferences.suspendAfter ?? -1
        // A value set with `defaults write` that isn't one of the choices gets its own item.
        while suspendPopup.numberOfItems > Preferences.suspendChoices.count { suspendPopup.removeItem(at: suspendPopup.numberOfItems - 1) }
        if let i = Preferences.suspendChoices.firstIndex(where: { $0.seconds == suspend }) {
            suspendPopup.selectItem(at: i)
        } else {
            let minutes = suspend / 60
            suspendPopup.addItem(withTitle: minutes == minutes.rounded() ? "After \(Int(minutes)) minutes" : "After \(Int(suspend)) seconds")
            suspendPopup.selectItem(at: suspendPopup.numberOfItems - 1)
        }
        let archive = Preferences.archiveAfter ?? -1
        archivePopup.selectItem(at: Preferences.archiveChoices.firstIndex { $0.seconds == archive } ?? 0)
        agentCheckbox.state = AgentServer.isEnabled ? .on : .off
        blockingCheckbox.state = Preferences.blocksTrackers ? .on : .off
        sidebarPopup.selectItem(at: Preferences.sidebarOnRight ? 1 : 0)
        addressBarCheckbox.state = Preferences.compactMode ? .off : .on
        let isDefault = DefaultBrowser.isDefault
        defaultBrowserButton.title = isDefault ? "Tern is your default browser" : "Make Tern the Default Browser"
        defaultBrowserButton.isEnabled = !isDefault
    }

    @objc private func makeDefaultBrowser() { DefaultBrowser.makeDefault() }

    @objc func sidebarSideChanged() {
        Preferences.sidebarOnRight = sidebarPopup.indexOfSelectedItem == 1
        AppDelegate.shared.windows.forEach { $0.setSidebarOnRight(Preferences.sidebarOnRight) }
    }

    @objc func addressBarChanged() {
        Preferences.compactMode = addressBarCheckbox.state == .off
        AppDelegate.shared.windows.forEach { $0.setCompact(Preferences.compactMode) }
    }

    @objc func appearanceChanged() {
        Preferences.appearance = Preferences.Appearance.allCases[appearancePopup.indexOfSelectedItem]
    }

    @objc func searchChanged() {
        let i = searchPopup.indexOfSelectedItem
        if Preferences.searchEngines.indices.contains(i) {
            Preferences.searchTemplate = Preferences.searchEngines[i].template
            customSearch.isHidden = true
        } else {
            customSearch.isHidden = false
            view.window?.makeFirstResponder(customSearch)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let text = customSearch.stringValue.trimmingCharacters(in: .whitespaces)
        // Only a template that names where the query goes, on the web.
        guard text.contains("%s"), let url = URL(string: text.replacingOccurrences(of: "%s", with: "q")),
              url.scheme == "https" || url.scheme == "http" else { return NSSound.beep() }
        Preferences.searchTemplate = text
    }

    @objc func suspendChanged() {
        guard Preferences.suspendChoices.indices.contains(suspendPopup.indexOfSelectedItem) else { return } // the custom value
        let seconds = Preferences.suspendChoices[suspendPopup.indexOfSelectedItem].seconds
        Preferences.suspendAfter = seconds < 0 ? nil : seconds
    }

    @objc func archiveChanged() {
        let seconds = Preferences.archiveChoices[archivePopup.indexOfSelectedItem].seconds
        Preferences.archiveAfter = seconds < 0 ? nil : seconds
    }

    @objc private func agentChanged() {
        if (agentCheckbox.state == .on) != AgentServer.isEnabled { AgentServer.shared.toggle() }
        NSApp.mainMenu = MainMenu.build(extensionsMenuDelegate: AppDelegate.shared)
    }

    @objc private func blockingChanged() {
        Preferences.blocksTrackers = blockingCheckbox.state == .on
        if Preferences.blocksTrackers { Task { await ContentBlocker.shared.update() } }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Tern forgets every page you've visited. Open tabs and their back/forward lists stay."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { HistoryStore.shared.clear() }
        }
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 300
        return field
    }
}

// MARK: - Shortcuts

/// Every command and its shortcut. Click a shortcut to record a new one: esc cancels, ⌫ clears.
/// Changes are written to the keymap file, which stays the source of truth.
@MainActor
final class ShortcutSettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private(set) var commands: [Command] = []
    /// The row waiting for a key, if any.
    private(set) var recording: Command?
    private var monitor: Any?

    override func loadView() {
        title = "Shortcuts"
        search.placeholderString = "Filter commands"
        search.delegate = self

        for (id, title, width) in [("command", "Command", 300.0), ("shortcut", "Shortcut", 160.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let file = NSButton(title: "Open keymap.json", target: self, action: #selector(openFile))
        let bottom = NSStackView(views: [status, file, reset])
        bottom.spacing = 8

        let stack = NSStackView(views: [search, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 380),
            root.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = root
        reload()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    func reload() {
        guard isViewLoaded else { return }
        let q = search.stringValue
        commands = Command.allCases.filter { command in
            q.isEmpty || CommandPalette.score(q, command.title) != nil
                || Keymap.shared.chords(for: command).contains { $0.description.localizedCaseInsensitiveContains(q) }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Recording

    func startRecording(_ command: Command) {
        stopRecording()
        recording = command
        status.stringValue = "Type the new shortcut for \(command.title). esc cancels, ⌫ clears."
        table.reloadData()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) ?? false } ? nil : event
        }
    }

    /// Takes the key while recording. Returns whether it was used.
    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        guard let command = recording, event.window === view.window else { return false }
        let chord = KeyChord(event: event)
        if chord.flags.isEmpty, event.keyCode == 53 { // esc
            status.stringValue = ""
        } else if chord.flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // ⌫ / ⌦
            Keymap.shared.setShortcut(nil, for: command)
            status.stringValue = "\(command.title) has no shortcut now."
        } else if chord.flags.intersection([.command, .control, .option]).isEmpty, !chord.key.hasPrefix("f") || chord.key.count == 1 {
            // Plain keys would fire while typing in pages; ask for a modifier (function keys are fine).
            NSSound.beep()
            status.stringValue = "Use ⌘, ⌃ or ⌥ with the key."
            return true
        } else {
            let previous = Keymap.shared.command(for: chord)
            Keymap.shared.setShortcut(chord, for: command)
            status.stringValue = previous.map { $0 == command ? "" : "\(chord) moved from \($0.title)." } ?? ""
        }
        stopRecording()
        reload()
        return true
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            table.reloadData()
        }
    }

    @objc private func restoreDefaults() {
        stopRecording()
        Keymap.shared.resetToDefaults()
        status.stringValue = "All shortcuts are back to their defaults."
        reload()
    }

    @objc private func openFile() {
        Keymap.shared.ensureFileExists()
        NSWorkspace.shared.open(Keymap.fileURL)
    }

    @objc private func shortcutClicked(_ sender: NSButton) {
        guard commands.indices.contains(sender.tag) else { return }
        let command = commands[sender.tag]
        if recording == command { stopRecording() } else { startRecording(command) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        if column?.identifier.rawValue == "command" {
            let cell = NSTableCellView()
            let icon = NSImageView(image: Theme.symbol(command.symbol, size: 12) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let text = NSTextField(labelWithString: command.title)
            text.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [icon, text])
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
            ])
            return cell
        }
        let chords = Keymap.shared.chords(for: command)
        let title = recording == command ? "Type shortcut…" : chords.first?.description ?? "—"
        let button = NSButton(title: title, target: self, action: #selector(shortcutClicked(_:)))
        button.tag = row
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: recording == command ? .regular : .medium)
        if chords.count > 1 { button.toolTip = "Also: " + chords.dropFirst().map(\.description).joined(separator: ", ") }
        return button
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
