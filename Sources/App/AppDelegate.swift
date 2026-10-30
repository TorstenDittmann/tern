import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var windows: [BrowserWindowController] = []
    private var keyMonitor: Any?
    private var pendingURLs: [URL] = []
    private var didLaunch = false

    var allTabs: [Tab] { windows.flatMap(\.tabs) }

    /// The browser window that owns the key window (the palette is a child window).
    var keyBrowser: BrowserWindowController? {
        guard let key = NSApp.keyWindow else { return windows.first { $0.window?.isMainWindow == true } }
        return windows.first { $0.window === key || $0.window === key.parent }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Metrics.markLaunched()
        LegacyMigration.run() // before anything reads settings or starts WebKit
        Preferences.applyAppearance()
        if SmokeTest.isRunning {
            // A throwaway keymap file: the smoke test edits shortcuts and must start from the defaults.
            Keymap.fileOverride = FileManager.default.temporaryDirectory.appendingPathComponent("tern-smoke-keymap-\(getpid()).json")
            // Nor may it read your bangs or write to your Downloads folder.
            Bangs.fileOverride = FileManager.default.temporaryDirectory.appendingPathComponent("tern-smoke-bangs-\(getpid()).json")
            DownloadManager.directoryOverride = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TERN_SMOKE"]!).appendingPathComponent("downloads")
        }
        Keymap.shared.load()
        NSApp.mainMenu = MainMenu.build(extensionsMenuDelegate: self)
        installKeyMonitor()
        ContentBlocker.shared.start()
        ExtensionManager.shared.start()
        AgentServer.shared.startIfEnabled()

        if SmokeTest.isRunning { return SmokeTest.run() }
        if let url = Metrics.benchmarkURL { openWindow(restoring: [Tab(url: url)]); return }
        if !SessionStore.restore(into: self) { openWindow() }
        if let first = windows.first { Welcome.showIfFirstRun(in: first) }
        didLaunch = true
        if !pendingURLs.isEmpty { open(pendingURLs); pendingURLs = [] }
        TabSuspender.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentServer.shared.stop()
        HistoryStore.shared.save()
        if !SmokeTest.isRunning && !Metrics.isBenchmark { SessionStore.save(windows) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { openWindow() }
        return true
    }

    /// Links opened from other apps (when Tern is the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        if didLaunch { open(urls) } else { pendingURLs += urls }
    }

    private func open(_ urls: [URL]) {
        let browser = keyBrowser ?? windows.last ?? openWindow()
        var urls = urls[...]
        // Reuse an untouched blank tab instead of leaving it behind.
        if let blank = browser.activeTab, blank.currentURL == nil, blank.webView?.canGoBack != true, let first = urls.popFirst() {
            blank.load(first)
            browser.window?.makeFirstResponder(blank.webView)
        }
        for url in urls { browser.newTab(url: url) }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Windows

    @discardableResult
    func openWindow(restoring tabs: [Tab] = [], active: Int = 0, frame: NSRect? = nil, sidebarCollapsed: Bool = false,
                    isPrivate: Bool = false) -> BrowserWindowController {
        let controller = BrowserWindowController(tabs: tabs, active: active, frame: frame, sidebarCollapsed: sidebarCollapsed, isPrivate: isPrivate)
        if frame == nil, let last = windows.last?.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        windows.append(controller)
        controller.showWindow(nil)
        Metrics.markWindowShown()
        controller.announceToExtensions()
        return controller
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
    }

    // MARK: Keys

    /// Tern's own bindings run before the web page sees the key, so ⌘L/⌘K/⌃Tab always work,
    /// even while a page has focus. Unmatched keys go through untouched.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AppDelegate.shared.handleKeyDown(event) } ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if let welcome = Welcome.active, welcome.handle(event) { return true }
        guard let browser = keyBrowser, NSApp.keyWindow?.attachedSheet == nil else { return false }
        if let hints = LinkHints.active, hints.handle(event) { return true }
        if let peek = browser.content.linkPeek, peek.handle(event) { return true }
        let chord = KeyChord(event: event)
        if let command = Keymap.shared.command(for: chord) {
            // Plain-key bindings (vim-style) must not swallow typing in text fields or the ⌘E tab filter.
            if chord.isPlain, NSApp.keyWindow?.firstResponder is NSTextView || browser.sidebar.isTabListFocused { return false }
            CommandUsage.record(command)
            CommandRouter.perform(command, in: browser)
            return true
        }
        return ExtensionManager.shared.performCommand(for: event)
    }

    func reloadKeymap() {
        if SmokeTest.isRunning {
            // A throwaway keymap file: the smoke test edits shortcuts and must start from the defaults.
            Keymap.fileOverride = FileManager.default.temporaryDirectory.appendingPathComponent("tern-smoke-keymap-\(getpid()).json")
        }
        Keymap.shared.load()
        NSApp.mainMenu = MainMenu.build(extensionsMenuDelegate: self)
    }

    // MARK: Menus

    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = Command(rawValue: raw) else { return }
        CommandUsage.record(command)
        CommandRouter.perform(command, in: keyBrowser)
    }

    func extensionsDidChange() {
        windows.forEach { $0.sidebar.updateExtensionActions() }
        NotificationCenter.default.post(name: ExtensionManager.didChange, object: nil)
    }

    /// The Extensions menu is rebuilt each time it opens, from what's installed right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(MainMenu.item(.browseChromeWebStore))
        menu.addItem(MainMenu.item(.loadUnpackedExtension))
        menu.addItem(MainMenu.item(.revealExtensionsFolder))
        menu.addItem(withTitle: "Rescan Installed Extensions", action: #selector(rescanExtensions), keyEquivalent: "")

        let manager = ExtensionManager.shared
        let safari = manager.available.filter { if case .safari = $0.source { true } else { false } }
        let store = manager.available.filter { if case .store = $0.source { true } else { false } }
        let unpacked = manager.available.filter { if case .unpacked = $0.source { true } else { false } }

        for (header, items) in [("Chrome Web Store", store), ("Safari Extensions", safari), ("Unpacked", unpacked)] where !items.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: header))
            for item in items {
                let mi = NSMenuItem(title: item.name, action: #selector(toggleExtension(_:)), keyEquivalent: "")
                mi.representedObject = item.id
                mi.state = manager.isEnabled(item) ? .on : .off
                if case .safari(_, let app) = item.source, app != item.name { mi.toolTip = "From \(app)" }

                let sub = NSMenu()
                sub.addItem(withTitle: manager.isEnabled(item) ? "Turn Off" : "Turn On", action: #selector(toggleExtension(_:)), keyEquivalent: "").representedObject = item.id
                if manager.context(for: item)?.optionsPageURL != nil {
                    sub.addItem(withTitle: "Options…", action: #selector(openExtensionOptions(_:)), keyEquivalent: "").representedObject = item.id
                }
                switch item.source {
                case .unpacked, .store:
                    sub.addItem(withTitle: "Remove", action: #selector(removeExtension(_:)), keyEquivalent: "").representedObject = item.id
                case .safari: break
                }
                mi.submenu = sub
                menu.addItem(mi)
            }
        }
        if manager.available.isEmpty {
            menu.addItem(.separator())
            let none = NSMenuItem(title: "No extensions found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    private func extensionItem(_ sender: NSMenuItem) -> ExtensionManager.Available? {
        guard let id = sender.representedObject as? String else { return nil }
        return ExtensionManager.shared.available.first { $0.id == id }
    }

    @objc private func toggleExtension(_ sender: NSMenuItem) {
        extensionItem(sender).map { ExtensionManager.shared.toggle($0) }
    }

    @objc private func removeExtension(_ sender: NSMenuItem) {
        extensionItem(sender).map { ExtensionManager.shared.remove($0) }
    }

    @objc private func openExtensionOptions(_ sender: NSMenuItem) {
        guard let item = extensionItem(sender), let url = ExtensionManager.shared.context(for: item)?.optionsPageURL else { return }
        ExtensionManager.browserForExtensions.newTab(url: url)
    }

    @objc private func rescanExtensions() {
        Task { await ExtensionManager.shared.refresh() }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Keeps titles that depend on state ("Move Tab List to the Left") current when a menu opens.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let raw = item.representedObject as? String, let command = Command(rawValue: raw) { item.title = command.title }
        return true
    }
}
