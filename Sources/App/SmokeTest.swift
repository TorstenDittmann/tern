import AppKit
import WebKit

/// End-to-end smoke test driven through the real UI objects. Run with
/// `TERN_SMOKE=<out dir> TERN_SMOKE_BASE=http://localhost:8765 TERN_SMOKE_EXT=<unpacked ext dir> Tern.app/Contents/MacOS/Tern`.
/// It doesn't touch the saved session or enabled extensions, and exits with 0 on success.
@MainActor
enum SmokeTest {
    static var isRunning: Bool { ProcessInfo.processInfo.environment["TERN_SMOKE"] != nil }

    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func run() {
        let env = ProcessInfo.processInfo.environment
        if let a = env["TERN_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        let out = URL(fileURLWithPath: env["TERN_SMOKE"]!)
        let base = env["TERN_SMOKE_BASE"] ?? "http://localhost:8765"
        Task {
            await body(out: out, base: base, extDir: env["TERN_SMOKE_EXT"])
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func body(out: URL, base: String, extDir: String?) async {
        await ExtensionManager.shared.refresh()
        // Pure logic
        check(KeyChord(string: "cmd+shift+]") == KeyChord(key: "]", flags: [.command, .shift]), "chord parsing")
        check(Keymap.shared.command(for: KeyChord(string: "ctrl+tab")!) == .nextTab, "default keymap ctrl+tab → nextTab")
        let engine = BrowserEngine.shared
        check(engine.resolve(input: "localhost:3000")?.absoluteString == "http://localhost:3000", "resolve localhost")
        check(engine.resolve(input: "github.com/apple")?.absoluteString == "https://github.com/apple", "resolve bare host")
        check(engine.resolve(input: "swift async let")?.host == "duckduckgo.com", "resolve search")
        check(CommandPalette.score("gh", "GitHub") != nil && CommandPalette.score("zz", "GitHub") == nil, "fuzzy score")

        // Extension (loaded before the first page so its content script injects)
        var ctx: WKWebExtensionContext?
        if let extDir {
            ctx = await ExtensionManager.shared.loadForSmokeTest(URL(fileURLWithPath: extDir))
            check(ctx?.isLoaded == true, "unpacked extension loaded")
        }

        let browser = AppDelegate.shared.openWindow(restoring: [Tab(url: URL(string: "\(base)/one.html"))])
        await wait { browser.activeTab?.isLoading == false && browser.activeTab?.pageTitle == "Page One" }
        check(browser.activeTab?.pageTitle == "Page One", "tab 1 loaded")

        let two = browser.newTab(url: URL(string: "\(base)/two.html"))
        await wait { two.pageTitle == "Page Two" && !two.isLoading }
        check(browser.tabs.count == 2 && browser.activeTab === two, "tab 2 opened and active")

        if let ctx {
            let marker = try? await two.webView?.evaluateJavaScript("document.documentElement.dataset.ternExt")
            check(marker as? String == "injected", "content script injected")
            var count: Any?
            await wait {
                two.webView?.evaluateJavaScript("document.documentElement.dataset.ternCount") { r, _ in count = r }
                return count != nil && !(count is NSNull)
            }
            check((count as? String) == "2", "content script ↔ background messaging, tabs.query (got \(count ?? "nil"))")
            await wait { ctx.action(for: two)?.badgeText == "2" }
            check(ctx.action(for: two)?.badgeText == "2", "background tabs.query sees 2 tabs (badge: \(ctx.action(for: two)?.badgeText ?? "nil"))")
        }

        // Navigate tab 2 so it has history, then check suspend/restore keeps it.
        two.load(URL(string: "\(base)/one.html?second")!)
        await wait { two.currentURL?.query == "second" && !two.isLoading }
        let one = browser.tabs[0]
        browser.activate(one)
        two.suspend()
        check(two.isSuspended && two.webView == nil, "background tab suspended")
        browser.activate(two)
        await wait { !two.isLoading && two.webView?.canGoBack == true }
        check(two.webView?.canGoBack == true && two.currentURL?.query == "second", "suspended tab restored with history")

        // Commands
        CommandRouter.perform(.nextTab, in: browser)
        check(browser.activeTab === one, "nextTab wraps around")
        CommandRouter.perform(.closeTab, in: browser)
        check(browser.tabs.count == 1, "closeTab")
        CommandRouter.perform(.reopenClosedTab, in: browser)
        await wait { browser.tabs.count == 2 && browser.activeTab?.isLoading == false }
        check(browser.tabs.count == 2 && browser.tabs[0].pageTitle == "Page One", "reopenClosedTab at original index")
        CommandRouter.perform(.moveTabDown, in: browser)
        check(browser.tabs[1] === browser.activeTab, "moveTabDown")

        // Split view
        check(Keymap.shared.command(for: KeyChord(string: "cmd+\\")!) == .toggleSplit, "⌘\\ bound to split view")
        let left = browser.activeTab!
        let tabCount = browser.tabs.count
        CommandRouter.perform(.toggleSplit, in: browser)
        let right = browser.activeTab!
        check(browser.tabs.count == tabCount + 1 && right !== left && browser.visibleTabs == [left, right], "⌘\\ splits with a new tab on the right")
        check(left.webView?.window != nil && right.webView?.window != nil, "both panes have web views on screen")
        right.load(URL(string: "\(base)/two.html")!)
        await wait { right.pageTitle == "Page Two" && !right.isLoading }
        browser.paneDidFocus(left)
        check(browser.activeTab === left && browser.visibleTabs.count == 2, "clicking a pane focuses it, split stays")
        CommandRouter.perform(.focusRightPane, in: browser)
        check(browser.activeTab === right, "focusRightPane")
        CommandRouter.perform(.swapPanes, in: browser)
        check(browser.visibleTabs == [right, left], "swapPanes")
        let outside = browser.tabs.first { !browser.isPaired($0) }!
        browser.activate(outside)
        check(browser.visibleTabs == [outside] && browser.split != nil, "other tab shows alone, pair kept")
        check(outside.webView?.frame.width == outside.webView?.superview?.bounds.width
              && (outside.webView?.frame.width ?? 0) > (left.webView?.frame.width ?? 0) * 1.5,
              "a tab leaving a split gets the full width at once")
        browser.activate(left)
        check(browser.visibleTabs.count == 2, "returning to a paired tab restores the split")
        check([left, right].allSatisfy { $0.webView?.superview != nil && $0.webView?.frame.width == $0.webView?.superview?.bounds.width }
              && (left.webView?.frame.width ?? 0) < (outside.webView?.frame.width ?? 0) * 0.75,
              "split panes get their half width at once, without a full-width frame first")
        right.suspend()
        check(!right.isSuspended, "visible split pane is never suspended")
        CommandRouter.perform(.closeTab, in: browser)
        check(browser.split == nil && browser.activeTab === right, "closing one pane ends split, focuses the other")
        CommandRouter.perform(.splitWithPreviousTab, in: browser)
        check(browser.visibleTabs.count == 2, "split with previous tab")
        CommandRouter.perform(.toggleSplit, in: browser)
        check(browser.split == nil && browser.visibleTabs.count == 1, "⌘\\ again unsplits")
        await tabList(browser: browser, base: base)
        await linkTools(browser: browser, base: base)
        dragToSplit(browser: browser, base: base)
        await welcome(browser: browser)
        settings()
        await bookmarksAndLibrary(browser: browser, base: base)
        await agentAPI(browser: browser, base: base)

        if ProcessInfo.processInfo.environment["TERN_SMOKE_SPLIT"] != nil {
            CommandRouter.perform(.splitWithPreviousTab, in: browser)
        }

        // Safari extensions installed on this Mac: can WebKit parse them?
        let safari = ExtensionManager.shared.available.filter { if case .safari = $0.source { true } else { false } }
        for item in safari {
            if case .safari(let appex, _) = item.source, let bundle = Bundle(url: appex) {
                do {
                    let ext = try await WKWebExtension(appExtensionBundle: bundle)
                    print("INFO  Safari extension “\(ext.displayName ?? item.name)” \(ext.version ?? "") MV\(ext.manifestVersion) — \(ext.requestedPermissions.count) permissions, errors: \(ext.errors.count)")
                } catch {
                    print("INFO  Safari extension \(item.name) failed to parse: \(error.localizedDescription)")
                }
            }
        }

        func dump(_ v: NSView, _ depth: Int = 0) {
            guard depth < 6 else { return }
            print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(NSStringFromRect(v.frame))\(v.isHidden ? " hidden" : "")")
            v.subviews.forEach { dump($0, depth + 1) }
        }
        if ProcessInfo.processInfo.environment["TERN_SMOKE_DUMP"] != nil {
            dump(browser.sidebar.view)
            if let w = browser.window, let frameView = w.contentView?.superview {
                for y in [w.frame.height - 5, w.frame.height - 20, w.frame.height - 40] {
                    let hit = frameView.hitTest(NSPoint(x: w.frame.width / 2, y: y))
                    print("HIT y=\(Int(w.frame.height - y)) from top → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                }
            }
        }

        // Snapshots for eyeballing
        try? await Task.sleep(for: .milliseconds(400))
        if let wv = browser.activeTab?.webView, let img = try? await wv.takeSnapshot(configuration: nil) {
            write(img, to: out.appendingPathComponent("page.png"))
        }
        if let view = browser.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("window.png"))
        }

        // TERN_SMOKE_PALETTE=<query>: leave the palette open for a few seconds so it can be screenshotted.
        let env = ProcessInfo.processInfo.environment
        if env["TERN_SMOKE_NEWTAB"] != nil {
            browser.newTab(url: nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
        // TERN_SMOKE_FULLSCREEN=window|element: enter fullscreen, report layout, hold, exit, report again.
        if let kind = env["TERN_SMOKE_FULLSCREEN"], let window = browser.window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            func report(_ label: String) {
                print("LAYOUT \(label): window=\(NSStringFromRect(window.frame)) fullscreen=\(window.styleMask.contains(.fullScreen))")
                print("  sidebar=\(NSStringFromRect(browser.sidebar.view.frame)) content=\(NSStringFromRect(browser.content.view.frame))")
                for v in browser.sidebar.view.subviews { print("  sidebar.\(type(of: v)) \(NSStringFromRect(v.frame))") }
                if let wv = browser.activeTab?.webView {
                    print("  webView=\(NSStringFromRect(wv.frame)) super=\(wv.superview.map { String(describing: type(of: $0)) } ?? "nil") window=\(wv.window === window)")
                }
            }
            report("before")
            if kind == "element" {
                _ = try? await browser.activeTab?.webView?.evaluateJavaScript("document.documentElement.requestFullscreen().then(()=>'ok',e=>String(e))")
            } else {
                window.toggleFullScreen(nil)
            }
            try? await Task.sleep(for: .seconds(2.5))
            report("in")
            try? await Task.sleep(for: .seconds(3))  // capture window
            if kind == "element" {
                _ = try? await browser.activeTab?.webView?.evaluateJavaScript("document.exitFullscreen()")
            } else {
                window.toggleFullScreen(nil)
            }
            try? await Task.sleep(for: .seconds(2.5))
            report("after")
            try? await Task.sleep(for: .seconds(3))  // capture window
        }
        if let query = env["TERN_SMOKE_PALETTE"] {
            NSApp.activate()
            browser.window?.makeKeyAndOrderFront(nil)
            CommandPalette.show(for: browser, mode: env["TERN_SMOKE_PALETTE_MODE"] == "tabs" ? .tabs : .everything, initialText: query)
            try? await Task.sleep(for: .milliseconds(600))
            FileManager.default.createFile(atPath: out.appendingPathComponent("ready").path, contents: nil)
            try? await Task.sleep(for: .seconds(4))
        } else if env["TERN_SMOKE_HOLD"] != nil {
            NSApp.activate()
            browser.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
            // Screenshot scripts wait for this file instead of guessing how long the run takes.
            FileManager.default.createFile(atPath: out.appendingPathComponent("ready").path, contents: nil)
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// Pinned tabs and the keyboard tab list (⌘E).
    private static func tabList(browser: BrowserWindowController, base: String) async {
        let plain = browser.newTab(url: URL(string: "\(base)/one.html?pin"))
        let pinned = browser.newTab(url: URL(string: "\(base)/two.html?filtered"))
        await wait { !plain.isLoading && pinned.pageTitle == "Page Two" && !pinned.isLoading }
        browser.setPinned(pinned, true)
        check(browser.tabs.first === pinned && pinned.isPinned, "pinning moves a tab to the top")
        if let i = browser.tabs.firstIndex(of: plain) { browser.moveTab(from: i, to: 0) }
        check(browser.tabs.first === pinned && browser.tabs[1] === plain, "unpinned tabs stay below pinned ones")

        browser.activate(plain)
        CommandRouter.perform(.focusTabList, in: browser)
        let sidebar = browser.sidebar
        check(sidebar.isTabListFocused, "⌘E focuses the tab list")
        func key(_ chars: String, code: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: browser.window?.windowNumber ?? 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        for c in "filtered" { _ = sidebar.handleTabListKey(key(String(c))) }
        check(sidebar.visibleRowCount == 1, "typing filters the tab list (\(sidebar.visibleRowCount) rows)")
        _ = sidebar.handleTabListKey(key("\r", code: 36))
        check(browser.activeTab === pinned && !sidebar.isTabListFocused, "↩ opens the filtered tab and leaves the list")

        browser.setPinned(pinned, false)
        check(!pinned.isPinned && browser.pinnedCount == 0, "unpinning")
        browser.close(plain)
        browser.close(pinned)
    }

    /// Drives the agent API through the embedded `tern` CLI, the way an agent would.
    /// ⌘J link hints and ⌥-click link peek.
    private static func linkTools(browser: BrowserWindowController, base: String) async {
        let tab = browser.newTab(url: URL(string: "\(base)/one.html?hints"))
        await wait { tab.pageTitle == "Page One" && !tab.isLoading }
        func key(_ chars: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: browser.window?.windowNumber ?? 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        check(Keymap.shared.command(for: KeyChord(string: "cmd+j")!) == .linkHints, "⌘J bound to link hints")
        let count = await LinkHints.start(in: browser)
        check(count == 1 && LinkHints.active != nil, "link hints label the page's one link (\(count))")
        _ = LinkHints.active?.handle(key("\u{1b}", code: 53))
        check(LinkHints.active == nil, "esc leaves link hints")

        await LinkHints.start(in: browser)
        _ = LinkHints.active?.handle(key("s", code: 1))
        await wait { tab.pageTitle == "Page Two" && !tab.isLoading }
        check(tab.pageTitle == "Page Two" && LinkHints.active == nil, "typing a hint follows the link")

        let before = browser.tabs.count
        browser.content.peek(URL(string: "\(base)/form.html?peek")!, from: tab)
        guard let peek = browser.content.linkPeek else { return check(false, "link peek opens") }
        await wait { peek.tab.pageTitle != nil && !peek.tab.isLoading && peek.tab.loadsEnded > 0 }
        check(peek.tab.loadsEnded > 0 && browser.tabs.count == before && peek.tab.webView?.window != nil,
              "link peek loads the page without adding a tab")
        _ = peek.handle(key("\u{1b}", code: 53))
        check(browser.content.linkPeek == nil && peek.tab.isSuspended, "esc closes the peek")

        browser.content.peek(URL(string: "\(base)/form.html?split")!, from: tab)
        let peeked = browser.content.linkPeek?.tab
        browser.content.promotePeek(split: true)
        check(peeked != nil && browser.tabs.count == before + 1 && browser.split?.left === tab && browser.split?.right === peeked
              && peeked?.webView?.window != nil, "a peek promotes to a split beside its page")
        browser.unsplit()
        if let peeked { browser.close(peeked) }
        browser.close(tab)
    }

    /// Dropping a sidebar tab on the left or right half of the page.
    private static func dragToSplit(browser: BrowserWindowController, base: String) {
        let a = browser.newTab(url: URL(string: "\(base)/one.html?dropA"))
        let b = browser.newTab(url: URL(string: "\(base)/one.html?dropB"), activate: false)
        let c = browser.newTab(url: URL(string: "\(base)/one.html?dropC"), activate: false)
        browser.content.dropTab(b, onRight: true)
        check(browser.visibleTabs == [a, b] && browser.activeTab === b, "dropping a tab on the right half splits with it")
        browser.content.dropTab(c, onRight: false)
        check(browser.visibleTabs == [c, b] && browser.activeTab === c, "dropping on the left half of a split replaces the left pane")
        check(!browser.content.dropTab(c, onRight: true), "dropping a tab beside itself does nothing")
        browser.unsplit()
        [a, b, c].forEach(browser.close)
    }

    private static func welcome(browser: BrowserWindowController) async {
        CommandRouter.perform(.showWelcome, in: browser)
        let sheet = browser.window?.attachedSheet
        check(sheet?.contentViewController is Welcome, "Welcome to Tern opens the welcome sheet")
        (sheet?.contentViewController as? Welcome)?.close()
        await wait { browser.window?.attachedSheet == nil }
        check(browser.window?.attachedSheet == nil, "Get Started closes it")
    }

    /// Settings ▸ General values and the shortcut editor (on a throwaway keymap file).
    private static func settings() {
        Preferences.searchTemplate = Preferences.searchEngines[1].template
        check(BrowserEngine.shared.resolve(input: "swift actors")?.host == "www.google.com", "search engine setting")
        Preferences.searchTemplate = Preferences.searchEngines[0].template
        Preferences.suspendAfter = nil
        check(TabSuspender.shared.idleInterval == nil, "suspend idle tabs: never")
        Preferences.suspendAfter = 600
        SettingsWindow.shared.show()
        check(SettingsWindow.shared.general.suspendPopup.titleOfSelectedItem == "After 10 minutes", "a custom suspend time shows as itself")
        Preferences.suspendAfter = 15 * 60

        let keymap = Keymap.shared
        let j = KeyChord(string: "cmd+j")!, y = KeyChord(string: "cmd+shift+y")!
        keymap.setShortcut(y, for: .linkHints)
        check(keymap.command(for: y) == .linkHints && keymap.primaryChord(for: .linkHints) == y && keymap.command(for: j) == nil,
              "recording a shortcut replaces the old one")
        keymap.setShortcut(y, for: .toggleSidebar)
        check(keymap.command(for: y) == .toggleSidebar && keymap.primaryChord(for: .linkHints) == nil, "a taken shortcut moves to the new command")
        keymap.setShortcut(nil, for: .commandPalette)
        check(keymap.chords(for: .commandPalette).isEmpty, "clearing removes every shortcut of a command")
        try? #"{ "shift+cmd+y": "copyURL" }"#.write(to: Keymap.fileURL, atomically: true, encoding: .utf8)
        keymap.load()
        keymap.setShortcut(nil, for: .copyURL)
        check(keymap.command(for: y) == nil, "clearing finds a chord the file spells differently")
        keymap.resetToDefaults()
        check(keymap.command(for: j) == .linkHints && keymap.primaryChord(for: .commandPalette) == KeyChord(string: "cmd+k")
              && !keymap.hasCustomShortcuts, "restore defaults")

        let window = SettingsWindow.shared
        window.show(tab: 1)
        window.shortcuts.startRecording(.copyURL)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                     windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: "u",
                                     charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32)!
        window.shortcuts.record(event)
        check(keymap.command(for: KeyChord(string: "cmd+alt+u")!) == .copyURL && window.shortcuts.recording == nil,
              "Settings ▸ Shortcuts records a key (\(keymap.primaryChord(for: .copyURL)?.spec ?? "none"))")
        keymap.resetToDefaults()
        window.close()
        try? FileManager.default.removeItem(at: Keymap.fileURL)
    }

    /// ⌘D bookmarks, the star, the start page tiles, and the History/Bookmarks window.
    private static func bookmarksAndLibrary(browser: BrowserWindowController, base: String) async {
        let tab = browser.newTab(url: URL(string: "\(base)/two.html?bookmark"))
        await wait { tab.pageTitle == "Page Two" && !tab.isLoading }
        CommandRouter.perform(.toggleBookmark, in: browser)
        check(BookmarkStore.shared.contains(tab.currentURL) && BookmarkStore.shared.all.first?.title == "Page Two", "⌘D bookmarks the page")
        check(StartPage.html.contains("Bookmarks") && StartPage.html.contains("two.html?bookmark"), "start page shows bookmarks as tiles")

        let library = LibraryWindow.shared
        library.show(.bookmarks)
        check(library.rows.count == 1 && library.rows.first?.url == tab.currentURL?.absoluteString, "Show Bookmarks lists the bookmark")
        library.show(.history)
        check(library.rows.contains { $0.url == tab.currentURL?.absoluteString }, "Show History lists visited pages")
        let other = browser.newTab(url: nil)
        library.open([LibraryWindow.Row(url: "\(base)/one.html?fromLibrary", title: "x", date: Date())], inNewTabs: false)
        await wait { other.pageTitle == "Page One" && !other.isLoading }
        check(other.currentURL?.query == "fromLibrary", "opening from the library loads the front tab")
        library.close()

        CommandRouter.perform(.toggleBookmark, in: browser) // `other` is active now; bookmark it, then remove both
        BookmarkStore.shared.remove(other.currentURL?.absoluteString ?? "")
        browser.activate(tab)
        CommandRouter.perform(.toggleBookmark, in: browser)
        check(BookmarkStore.shared.all.isEmpty, "⌘D again removes the bookmark")
        HistoryStore.shared.remove(other.currentURL?.absoluteString ?? "")
        check(!HistoryStore.shared.entries.keys.contains(other.currentURL?.absoluteString ?? ""), "removing a page from history")
        browser.close(other)
        browser.close(tab)
    }

    private static func agentAPI(browser: BrowserWindowController, base: String) async {
        guard AgentServer.shared.isRunning else { return check(false, "agent API listening (TERN_SOCKET set by make smoke)") }
        let before = browser.tabs.count

        let hello = await tern(["hello"])
        check(hello.status == 0 && (hello.json?["apiVersion"] as? Int) == 1, "tern hello (\(hello.out.prefix(80)))")

        let metrics = await tern(["call", "tern.metrics"])
        let launch = metrics.json?["launch"] as? [String: Any], memory = metrics.json?["memory"] as? [String: Any]
        check(launch?["firstPageMs"] is Double && (memory?["appMB"] as? Double ?? 0) > 0
              && ((memory?["webProcesses"] as? [Any])?.isEmpty == false),
              "tern.metrics reports launch timings and memory (\(metrics.out.prefix(160)))")

        let opened = await tern(["tabs", "open", "\(base)/one.html", "--windowId", browser.id.uuidString])
        let id = opened.json?["id"] as? String ?? ""
        check(opened.json?["title"] as? String == "Page One" && opened.json?["openedByAgent"] as? Bool == true,
              "tabs open waits for the load (\(opened.out.prefix(160)))")
        check(browser.tabs.count == before + 1 && browser.activeTab?.id.uuidString == id, "tabs open adds an active tab")

        let list = await tern(["tabs", "list", "--plain"])
        check(list.status == 0 && list.out.contains(id), "tabs list --plain")
        let pin = await tern(["tabs", "pin", id])
        let unpin = await tern(["tabs", "pin", id, "--pinned", "false"])
        check(pin.json?["pinned"] as? Bool == true && pin.json?["index"] as? Int == 0 && unpin.json?["pinned"] as? Bool == false,
              "tabs pin (\(pin.out.prefix(80)))")

        let nav = await tern(["tabs", "navigate", "\(base)/two.html", "--tabId", id])
        let history = await tern(["history", "search", "Page Two", "--json"])
        // Any visit of two.html (an earlier check opened it with a query string) is a right answer.
        let topURL = history.array?.first.flatMap { ($0 as? [String: Any])?["url"] as? String }
        check(topURL.flatMap(URL.init(string:))?.path == "/two.html", "history search finds a visited page (\(topURL ?? history.out))")
        check(HistoryStore.shared.completion(for: "localh") == HistoryStore.bare(base) + "/", "address bar completes a visited site")
        check(nav.json?["title"] as? String == "Page Two", "tabs navigate")
        let back = await tern(["tabs", "back", id])
        check(back.json?["title"] as? String == "Page One", "tabs back")
        let noHistory = await tern(["tabs", "back", id, "--timeoutMs", "3000"])
        check(noHistory.status == 1 && noHistory.out.contains("-32006"), "tabs back with no history fails fast")

        let commands = await tern(["commands", "list"])
        let names = (commands.array ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
        check(names.contains("toggleSplit") && names.count == Command.allCases.count, "commands list")
        _ = await tern(["run", "splitWithPreviousTab"])
        check(browser.split != nil && browser.visibleTabs.count == 2, "run splitWithPreviousTab")
        _ = await tern(["run", "toggleSplit"])
        check(browser.split == nil, "run toggleSplit ends the split")

        let unknown = await tern(["tabs", "frobnicate"])
        check(unknown.status == 1 && unknown.out.contains("-32601"), "unknown method is an error")

        // agentOwnTabsOnly: tabs the agent didn't open are read-only.
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "agentOwnTabsOnly")
        defaults.set(true, forKey: "agentOwnTabsOnly")
        let theirs = browser.tabs.first { $0.id.uuidString != id && !$0.isActive }!
        let denied = await tern(["tabs", "close", theirs.id.uuidString])
        check(denied.status == 1 && denied.out.contains("-32005") && browser.tabs.contains(theirs), "agentOwnTabsOnly blocks other tabs")
        let closeWindow = await tern(["run", "closeWindow", "--windowId", browser.id.uuidString])
        check(closeWindow.status == 1 && closeWindow.out.contains("-32005") && browser.window?.isVisible == true,
              "agentOwnTabsOnly blocks closeWindow on a window with other tabs")
        let closed = await tern(["tabs", "close", id])
        check(closed.status == 0 && browser.tabs.count == before, "tabs close (own tab)")
        defaults.set(previous, forKey: "agentOwnTabsOnly")

        await agentPage(browser: browser, base: base)
        await agentLogs(browser: browser, base: base)
        await agentMCP(base: base)
    }

    /// `tern mcp`: the handshake, the tool list, and tool calls answered with text, images and errors.
    private static func agentMCP(base: String) async {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "smoke", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "tabs_open", "arguments": ["url": "\(base)/form.html"]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "page_snapshot", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "page_screenshot", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "page_eval", "arguments": ["js": "throw new Error('mcp-boom')"]]],
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "nope", "arguments": [:]]],
        ]
        let input = requests.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        let run = await tern(["mcp"], input: input)
        var replies: [Int: [String: Any]] = [:]
        for line in run.out.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            replies[id] = object
        }
        func result(_ id: Int) -> [String: Any] { replies[id]?["result"] as? [String: Any] ?? [:] }
        func content(_ id: Int) -> [[String: Any]] { result(id)["content"] as? [[String: Any]] ?? [] }

        check(result(1)["protocolVersion"] as? String == "2025-06-18" && replies.count == 7,
              "mcp initialize (\(replies.count) replies: \(run.out.prefix(120)))")
        let names = (result(2)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(names.contains("page_snapshot") && names.contains("console_read"), "mcp tools/list (\(names.count) tools)")
        check((content(3).first?["text"] as? String)?.contains("form.html") == true, "mcp tabs_open")
        check((content(4).first?["text"] as? String)?.contains("Submit") == true, "mcp page_snapshot returns the outline")
        check(content(5).first?["type"] as? String == "image" && content(5).first?["mimeType"] as? String == "image/png",
              "mcp page_screenshot returns an image")
        check(result(6)["isError"] as? Bool == true && (content(6).first?["text"] as? String)?.contains("mcp-boom") == true,
              "mcp tool errors come back as isError results")
        check((replies[7]?["error"] as? [String: Any])?["code"] as? Int == -32602, "mcp unknown tool is a protocol error")
        if let id = (content(3).first?["text"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })?["id"] as? String {
            _ = await tern(["tabs", "close", id])
        }
    }

    /// console.*, network.*, events.*, and the "agent is driving" marking.
    private static func agentLogs(browser: BrowserWindowController, base: String) async {
        let opened = await tern(["tabs", "open", "\(base)/form.html", "--windowId", browser.id.uuidString])
        let id = opened.json?["id"] as? String ?? ""

        // No --count: other pages can log too, so collect everything until the stream goes quiet.
        async let streamed = tern(["events", "subscribe", "console.message", "--timeoutMs", "3000"])
        for _ in 0..<50 where !AgentServer.shared.hasSubscribers { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(AgentServer.shared.hasSubscribers && AgentActivity.shared.isActive, "events subscribe keeps a listener connected")

        _ = await tern(["page", "eval", "console.warn('tern-warn', {a: 1}); fetch('one.html').then(r => r.status)", "--tabId", id])
        _ = await tern(["page", "eval", "fetch('missing.html').then(r => r.status)", "--tabId", id])
        _ = await tern(["page", "eval", "setTimeout(() => { throw new Error('tern-uncaught') }, 0); 1", "--tabId", id])
        let tab = browser.tabs.first { $0.id.uuidString == id }
        check(tab?.isAgentDriving == true, "a tab an agent acts on is marked as driven")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let warn = await tern(["console", "read", "--tabId", id, "--level", "warn"])
        check(warn.out.contains("[warn] tern-warn {\"a\":1}"), "console read captures console.warn (\(warn.out.prefix(80)))")
        let errors = await tern(["console", "read", "--tabId", id, "--level", "error", "--json"])
        check(errors.out.contains("tern-uncaught"), "console read captures uncaught errors")
        let net = await tern(["network", "list", "--tabId", id, "--json"])
        check(net.out.contains("one.html") && net.out.contains("\"status\" : 200"), "network list records fetch requests")
        let failed = await tern(["network", "list", "--tabId", id, "--failedOnly", "true"])
        check(failed.out.contains("404") && !failed.out.contains("one.html"), "network list --failedOnly (\(failed.out.prefix(80)))")
        let since = (net.json?["last"] as? Int).map(String.init) ?? "0"
        let none = await tern(["network", "list", "--tabId", id, "--since", since, "--json"])
        check((none.json?["entries"] as? [Any])?.isEmpty == true, "network list --since skips entries already read")
        let oldest = await tern(["network", "list", "--tabId", id, "--since", "0", "--limit", "1", "--json"])
        check(oldest.out.contains("one.html") && !oldest.out.contains("missing.html"), "network list --since pages from the oldest unread entry")

        let events = await streamed
        check(events.status == 0 && events.out.contains("console.message") && events.out.contains("tern-warn"),
              "events subscribe streams console messages (\(events.status): \(events.out.prefix(200)))")
        _ = await tern(["tabs", "close", id])
    }

    /// page.*: snapshot, refs, native input, eval, text, audit, screenshot, waitFor, stale refs.
    private static func agentPage(browser: BrowserWindowController, base: String) async {
        let opened = await tern(["tabs", "open", "\(base)/form.html", "--windowId", browser.id.uuidString])
        let id = opened.json?["id"] as? String ?? ""
        let snap = await tern(["page", "snapshot", "--tabId", id])
        func ref(_ needle: String) -> String {
            let line = snap.out.split(separator: "\n").first { $0.contains(needle) } ?? ""
            guard let r = line.range(of: #"ref=e\d+"#, options: .regularExpression) else { return "e0" }
            return String(line[r].dropFirst(4))
        }
        check(snap.out.contains("heading \"Sign up\" [level=1]") && snap.out.contains("-> two.html"), "page snapshot")
        let name = ref("textbox \"Name\""), color = ref("combobox \"Color\""), agree = ref("checkbox"), go = ref("button \"Submit\"")
        let link = ref("link \"Go to page two\"")

        let typed = await tern(["page", "type", name, "Ada", "--tabId", id])
        print("INFO  page type native=\(typed.json?["native"] ?? "?")")
        let value = await tern(["page", "eval", "document.getElementById('name').value", "--tabId", id])
        check(value.out.trimmingCharacters(in: .whitespacesAndNewlines) == "Ada", "page type (\(value.out.prefix(60)))")
        let selected = await tern(["page", "select", color, "g", "--tabId", id])
        check(selected.out.contains("\"g\""), "page select")
        let clickedBox = await tern(["page", "click", agree, "--tabId", id])
        let clickedGo = await tern(["page", "click", go, "--tabId", id])
        print("INFO  page click native=\(clickedBox.json?["native"] ?? "?"), \(clickedGo.json?["native"] ?? "?")")
        let out = await tern(["page", "eval", "return document.getElementById('out').textContent", "--tabId", id])
        check(out.out.hasPrefix("Hello Ada g true"), "page click (\(out.out.prefix(60)))")
        if clickedGo.json?["native"] as? Bool == true { check(out.out.contains("true true"), "native click is trusted") }

        _ = await tern(["page", "click", name, "--tabId", id])
        _ = await tern(["page", "press", "enter", "--tabId", id])
        let entered = await tern(["page", "eval", "document.getElementById('out').textContent", "--tabId", id])
        check(entered.out.hasPrefix("enter"), "page press enter (\(entered.out.prefix(40)))")

        let waited = await tern(["page", "waitFor", "enter", "--tabId", id, "--timeoutMs", "2000"])
        check(waited.status == 0, "page waitFor text")
        let timedOut = await tern(["page", "waitFor", "--selector", "#nope", "--tabId", id, "--timeoutMs", "300"])
        check(timedOut.status == 1 && timedOut.out.contains("-32003"), "page waitFor times out")

        let md = await tern(["page", "text", "markdown", "--tabId", id])
        check(md.out.contains("# Sign up") && md.out.contains("**All fields**"), "page text markdown")
        let audit = await tern(["page", "audit", "--tabId", id, "--json"])
        check(audit.out.contains("image-alt"), "page audit finds the image without alt")
        let shot = await tern(["page", "screenshot", "--tabId", id, "--path", NSTemporaryDirectory() + "tern-agent-shot.png"])
        let png = (shot.json?["path"] as? String).flatMap { FileManager.default.contents(atPath: $0) }
        check(png?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "page screenshot writes a PNG")
        let mapped = await tern(["page", "eval", "[1, 2].map(n => { return n * 2 })", "--tabId", id, "--json"])
        check(mapped.out.filter { !$0.isWhitespace } == "[2,4]", "page eval keeps a value with a nested return (\(mapped.out.prefix(40)))")
        let semi = await tern(["page", "eval", "document.title;", "--tabId", id])
        check(semi.out.trimmingCharacters(in: .whitespacesAndNewlines) == "Form", "page eval allows a trailing semicolon (\(semi.out.prefix(40)))")
        let body = await tern(["page", "eval", "const n = 20; return n + 1", "--tabId", id])
        check(body.out.trimmingCharacters(in: .whitespacesAndNewlines) == "21", "page eval runs a function body")
        _ = await tern(["page", "snapshot", "--tabId", id, "--scope", "ul"])
        let again = await tern(["page", "snapshot", "--tabId", id])
        check(again.out.contains("button \"Submit\" [ref=\(go)]"), "scoped snapshot keeps earlier refs")
        let bad = await tern(["page", "eval", "throw new Error('boom')", "--tabId", id])
        check(bad.status == 1 && bad.out.contains("-32004") && bad.out.contains("boom"), "page eval reports JS errors (\(bad.out))")

        let followed = await tern(["page", "click", link, "--tabId", id])
        check(followed.json?["title"] as? String == "Page Two", "clicking a link waits for the new page")
        let stale = await tern(["page", "click", go, "--tabId", id])
        check(stale.status == 1 && stale.out.contains("-32002"), "refs go stale after navigation")
        _ = await tern(["tabs", "close", id])
    }

    private struct CLIResult {
        let status: Int32
        let out: String
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
        var array: [Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [Any] }
    }

    /// Runs the CLI without blocking the main thread, which the server needs to answer it.
    private static func tern(_ args: [String], input: String? = nil) async -> CLIResult {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tern")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        return await withCheckedContinuation { done in
            do { try process.run() } catch {
                return done.resume(returning: CLIResult(status: -1, out: "\(error)"))
            }
            // Drain output while it runs: a large result (a screenshot) would fill the pipe and stall it.
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: CLIResult(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private static func wait(timeout: Double = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
