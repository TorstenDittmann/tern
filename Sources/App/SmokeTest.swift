import AppKit
import WebKit

/// End-to-end smoke test driven through the real UI objects. Run with
/// `TERN_SMOKE=<out dir> TERN_SMOKE_BASE=http://localhost:8765 TERN_SMOKE_EXT=<unpacked ext dir> Tern.app/Contents/MacOS/Tern`.
/// It doesn't touch the saved session, settings or enabled extensions, and exits with 0 on success.
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

        check(Preferences.compactMode, "the address bar is hidden by default (compact mode)")
        // The rest of the run works the top bar a lot, so it starts with the bar showing; compact mode gets its own checks.
        Preferences.compactMode = false
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
        let memory = browser.sidebar.memoryText
        check(memory.hasSuffix(" MB") || memory.hasSuffix(" GB"), "the tab list shows Tern's memory use (\(memory))")
        check(SidebarViewController.memoryString(412.4) == "412 MB" && SidebarViewController.memoryString(1536) == "1.5 GB", "memory formatting")
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
        check(Keymap.shared.primaryChord(for: .toggleSplit) == KeyChord(string: "cmd+shift+s")
              && Keymap.shared.command(for: KeyChord(string: "cmd+\\")!) == .toggleSplit
              && Keymap.shared.command(for: KeyChord(string: "cmd+alt+right")!) == .focusRightPane
              && Keymap.shared.command(for: KeyChord(string: "cmd+alt+down")!) == .focusPaneBelow, "⇧⌘S (and ⌘\\) bound to split view, ⌥⌘ arrows to panes")
        let left = browser.activeTab!
        let tabCount = browser.tabs.count
        CommandRouter.perform(.toggleSplit, in: browser)
        let right = browser.activeTab!
        check(browser.tabs.count == tabCount + 1 && right !== left && browser.visibleTabs == [left, right], "⌘\\ splits with a new tab on the right")
        check(left.webView?.window != nil && right.webView?.window != nil, "both panes have web views on screen")
        right.load(URL(string: "\(base)/two.html")!)
        await wait { right.pageTitle == "Page Two" && !right.isLoading }
        let bar = browser.content.topBar
        check(bar.splitButton.contentTintColor == Theme.accent, "the split button is lit in split view")
        check(browser.content.paneHeaderTexts == ["localhost:8765", "localhost:8765"], "each pane has a header with its host (\(browser.content.paneHeaderTexts))")
        check([left, right].allSatisfy { ($0.webView?.frame.height ?? 0) == ($0.webView?.superview?.bounds.height ?? 0) - PaneHeader.height },
              "split panes' pages sit below their headers")
        browser.paneDidFocus(left)
        check(browser.activeTab === left && browser.visibleTabs.count == 2, "clicking a pane focuses it, split stays")
        CommandRouter.perform(.focusRightPane, in: browser)
        check(browser.activeTab === right, "focusRightPane")
        CommandRouter.perform(.swapPanes, in: browser)
        check(browser.visibleTabs == [right, left], "swapPanes")
        let outside = browser.tabs.first { !browser.isPaired($0) }!
        browser.activate(outside)
        check(browser.visibleTabs == [outside] && browser.split != nil, "other tab shows alone, pair kept")
        check(browser.content.paneHeaderTexts.isEmpty && outside.webView?.frame.height == outside.webView?.superview?.bounds.height
              && bar.splitButton.contentTintColor != Theme.accent, "a single page has no header and the split button is off")
        check(outside.webView?.frame.width == outside.webView?.superview?.bounds.width
              && (outside.webView?.frame.width ?? 0) > (left.webView?.frame.width ?? 0) * 1.5,
              "a tab leaving a split gets the full width at once")
        let fullWidth = outside.webView?.frame.width ?? 0
        browser.activate(left)
        check(browser.visibleTabs.count == 2, "returning to a paired tab restores the split")
        check([left, right].allSatisfy { $0.webView?.superview != nil && ($0.webView?.frame.width ?? .infinity) < fullWidth * 0.75 },
              "split panes get their half width at once, without a full-width frame first")
        right.suspend()
        check(!right.isSuspended, "visible split pane is never suspended")
        CommandRouter.perform(.closeTab, in: browser)
        check(browser.split == nil && browser.activeTab === right, "closing one pane ends split, focuses the other")
        CommandRouter.perform(.splitWithPreviousTab, in: browser)
        check(browser.visibleTabs.count == 2, "split with previous tab")
        bar.splitButton.performClick(nil)
        check(browser.split == nil && browser.visibleTabs.count == 1, "the split button unsplits")
        bar.splitButton.performClick(nil)
        check(browser.visibleTabs.count == 2, "the split button splits")
        CommandRouter.perform(.toggleSplit, in: browser)
        check(browser.split == nil && browser.visibleTabs.count == 1, "⌘\\ again unsplits")
        let alone = browser.activeTab!
        CommandRouter.perform(.focusRightPane, in: browser)
        check(browser.split?.layout == .columns && browser.visibleTabs.first === alone && browser.visibleTabs.count == 2, "⌥⌘→ with no split opens a pane on the right")
        CommandRouter.perform(.focusPaneBelow, in: browser)
        check(browser.split?.layout == .grid && browser.visibleTabs.count == 3 && browser.activeTab !== alone, "⌥⌘↓ with no pane below opens one there")
        CommandRouter.perform(.focusLeftPane, in: browser)
        check(browser.activeTab === alone, "⌥⌘← moves back to the left pane")
        let paneTabs = browser.visibleTabs.filter { $0 !== alone }
        CommandRouter.perform(.toggleSplit, in: browser)
        paneTabs.forEach { browser.close($0) }
        check(browser.split == nil && browser.activeTab === alone, "back to one tab")
        await tabList(browser: browser, base: base)
        await linkTools(browser: browser, base: base)
        await swipes(browser: browser, base: base)
        dragToSplit(browser: browser, base: base)
        await splitInTabList(browser: browser, base: base)
        await windowChrome(browser: browser)
        await addressBar(browser: browser, base: base)
        await welcome(browser: browser)
        settings()
        await privacy(browser: browser, base: base)
        await bookmarksAndLibrary(browser: browser, base: base)
        await browsingBasics(browser: browser, base: base, out: out)
        await tabHousekeeping(browser: browser, base: base)
        await privateWindow(base: base)
        await pageTools(browser: browser, base: base)
        await requests(browser: browser, base: base)
        await agentAPI(browser: browser, base: base)

        // TERN_SMOKE_SPLIT=1 leaves a pair on screen for the snapshots; =columns|rows|grid leaves three or four tabs.
        if let kind = ProcessInfo.processInfo.environment["TERN_SMOKE_SPLIT"], let active = browser.activeTab {
            if let layout = SplitLayout(rawValue: kind) {
                let extra = (0..<(layout == .grid ? 3 : 2)).map { browser.newTab(url: URL(string: "\(base)/two.html?shot\($0)"), activate: false) }
                browser.split([active] + extra, layout: layout, focus: active)
                await wait { extra.allSatisfy { !$0.isLoading } }
            } else {
                CommandRouter.perform(.splitWithPreviousTab, in: browser)
            }
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
        check(browser.sidebar.pinnedTileCount == 1 && browser.sidebar.visibleRowCount == browser.tabs.count - 1,
              "a pinned tab shows as a tile above the list, not as a row (\(browser.sidebar.pinnedTileCount) tiles, \(browser.sidebar.visibleRowCount) rows)")

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
        check(!pinned.isPinned && browser.pinnedCount == 0 && browser.sidebar.pinnedTileCount == 0, "unpinning")
        browser.close(plain)
        browser.close(pinned)
    }

    /// Drives the agent API through the embedded `tern` CLI, the way an agent would.
    /// ⌘J link hints and ⌥-click link peek.
    /// Two-finger swipes, sent as trackpad scroll events: they go back and forward at once, without
    /// WebKit's page slide, but never instead of a vertical scroll or a page that can still scroll sideways.
    private static func swipes(browser: BrowserWindowController, base: String) async {
        guard SwipeNavigator.isEnabled else { return print("INFO  swipe between pages is off in System Settings; swipes not tested") }
        let tab = browser.newTab(url: URL(string: "\(base)/one.html?swipe"))
        await wait { tab.pageTitle == "Page One" && !tab.isLoading }
        tab.load(URL(string: "\(base)/two.html?swipe")!)
        await wait { tab.pageTitle == "Page Two" && !tab.isLoading }
        guard let wv = tab.webView else { return check(false, "swipe tab has a web view") }
        check(!wv.allowsBackForwardNavigationGestures, "WebKit's sliding swipe is off")

        /// One gesture: began, `steps` changes of (dx, dy) points each, ended. Positive dx is fingers moving right.
        func swipe(dx: CGFloat, dy: CGFloat = 0, steps: Int = 12) async {
            func send(_ phase: NSEvent.Phase, _ dx: CGFloat, _ dy: CGFloat) async {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: Int32(dy), wheel2: Int32(-dx), wheel3: 0) else { return }
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                // kCGScrollWheelEventScrollPhase takes CGScrollPhase values, not NSEvent.Phase ones.
                let cgPhase: Int64 = phase == .began ? 1 : phase == .changed ? 2 : 4
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: cgPhase)
                if let window = wv.window, let screen = window.screen {
                    let p = window.convertPoint(toScreen: wv.convert(NSPoint(x: wv.bounds.midX, y: wv.bounds.midY), to: nil))
                    cg.location = CGPoint(x: p.x, y: screen.frame.maxY - p.y)
                }
                if let event = NSEvent(cgEvent: cg) { wv.scrollWheel(with: event) }
                try? await Task.sleep(for: .milliseconds(12))
            }
            await send(.began, 0, 0)
            for _ in 0..<steps { await send(.changed, dx, dy) }
            await send(.ended, 0, 0)
        }

        let started = Date()
        await swipe(dx: 8)
        await wait(timeout: 3) { tab.pageTitle == "Page One" && !tab.isLoading }
        check(tab.pageTitle == "Page One", "swiping right goes back (\(Int(Date().timeIntervalSince(started) * 1000)) ms for the whole gesture)")
        await swipe(dx: -8)
        await wait(timeout: 3) { tab.pageTitle == "Page Two" && !tab.isLoading }
        check(tab.pageTitle == "Page Two", "swiping left goes forward")
        await swipe(dx: 3, dy: 12)
        try? await Task.sleep(for: .milliseconds(400))
        check(tab.pageTitle == "Page Two", "a mostly vertical scroll doesn't go back")

        tab.load(URL(string: "\(base)/wide.html")!)
        await wait { tab.pageTitle == "Wide Page" && !tab.isLoading }
        _ = try? await wv.evaluateJavaScript("window.scrollTo(1500, 0); 1")
        try? await Task.sleep(for: .milliseconds(200))
        await swipe(dx: 8)
        try? await Task.sleep(for: .milliseconds(400))
        check(tab.pageTitle == "Wide Page", "a page that can still scroll sideways doesn't go back")
        _ = try? await wv.evaluateJavaScript("window.scrollTo(0, 0); 1")
        try? await Task.sleep(for: .milliseconds(200))
        await swipe(dx: 8)
        await wait(timeout: 3) { tab.pageTitle == "Page Two" && !tab.isLoading }
        check(tab.pageTitle == "Page Two", "at its left edge, the same page goes back")
        browser.close(tab)
    }

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
        check(browser.content.linkPeek == nil && peek.hitTest(NSPoint(x: peek.bounds.midX, y: peek.bounds.midY)) == nil,
              "esc closes the peek, and clicks reach the page while it fades out")
        await wait { peek.superview == nil && peek.tab.isSuspended }
        check(peek.superview == nil && peek.tab.isSuspended, "the closed peek's page is discarded once it has faded out")

        browser.content.peek(URL(string: "\(base)/form.html?split")!, from: tab)
        let peeked = browser.content.linkPeek?.tab
        browser.content.promotePeek(split: true)
        check(peeked != nil && browser.tabs.count == before + 1 && browser.split?.tabs.first === tab && browser.split?.tabs.last === peeked
              && peeked?.webView?.window != nil, "a peek promotes to a split beside its page")
        await wait { browser.content.view.subviews.allSatisfy { !($0 is LinkPeek) } }
        check(browser.content.view.subviews.allSatisfy { !($0 is LinkPeek) }, "the promoted peek's overlay fades out and is removed")
        browser.unsplit()
        if let peeked { browser.close(peeked) }
        browser.close(tab)
    }

    /// Dropping a sidebar tab on the page, up/down splits, and splits of three and four tabs.
    private static func dragToSplit(browser: BrowserWindowController, base: String) {
        let a = browser.newTab(url: URL(string: "\(base)/one.html?dropA"))
        let b = browser.newTab(url: URL(string: "\(base)/one.html?dropB"), activate: false)
        let c = browser.newTab(url: URL(string: "\(base)/one.html?dropC"), activate: false)
        let d = browser.newTab(url: URL(string: "\(base)/one.html?dropD"), activate: false)
        let e = browser.newTab(url: URL(string: "\(base)/one.html?dropE"), activate: false)
        check(browser.drop(b, at: .edge(.maxX)) && browser.visibleTabs == [a, b] && browser.activeTab === b && browser.split?.layout == .columns,
              "dropping a tab on the right half splits with it")
        browser.unsplit()
        browser.activate(a)
        check(browser.drop(b, at: .edge(.minY)) && browser.visibleTabs == [a, b] && browser.split?.layout == .rows,
              "dropping a tab on the bottom half splits up and down")
        check(a.webView!.frame.width > b.webView!.frame.height && abs(a.webView!.frame.width - b.webView!.frame.width) < 1,
              "stacked panes share the full width")
        check(browser.drop(c, at: .pane(0)) && browser.visibleTabs == [c, b] && browser.activeTab === c, "dropping on a pane replaces it")
        check(!browser.drop(c, at: .pane(0)), "dropping a tab on its own pane does nothing")
        check(browser.drop(a, at: .edge(.minY)) && browser.visibleTabs == [c, b, a] && browser.split?.layout == .rows,
              "dropping at the bottom edge of a stacked split adds a third pane")
        check(browser.drop(d, at: .edge(.maxX)) && browser.visibleTabs == [c, b, a, d] && browser.split?.layout == .grid,
              "a fourth pane makes a 2×2 grid")
        check(browser.visibleTabs.allSatisfy { $0.webView?.window != nil }, "all four panes have web views on screen")
        check(!browser.drop(e, at: .edge(.maxX)), "a full grid takes no fifth pane")
        let tabIndices = browser.visibleTabs.compactMap { browser.tabs.firstIndex(of: $0) }.sorted()
        check(tabIndices.last! - tabIndices.first! == 3, "a split's tabs sit together in the tab list")

        CommandRouter.perform(.focusPaneAbove, in: browser)
        check(browser.activeTab === b, "focusPaneAbove moves to the pane above")
        CommandRouter.perform(.focusLeftPane, in: browser)
        check(browser.activeTab === c, "focusLeftPane moves to the pane on the left")
        browser.setSplitLayout(.columns)
        check(browser.split?.layout == .columns && browser.visibleTabs.count == 4, "four tabs side by side")
        CommandRouter.perform(.changeSplitLayout, in: browser)
        check(browser.split?.layout == .rows, "changeSplitLayout cycles to the next layout")
        CommandRouter.perform(.removeFromSplit, in: browser)
        check(browser.visibleTabs == [c] && browser.split?.tabs == [b, a, d] && browser.split?.layout == .rows,
              "removing a tab from the split shows it alone and keeps the rest")
        browser.activate(b)
        browser.close(d)
        check(browser.split?.tabs == [b, a] && browser.visibleTabs == [b, a], "closing a pane of three leaves a pair")
        browser.setSplitLayout(.grid)
        check(browser.split?.layout == .rows, "a pair can't be a grid")
        CommandRouter.perform(.addPane, in: browser)
        check(browser.split?.tabs.count == 3 && browser.activeTab?.currentURL == nil, "addPane adds a new tab to the split")
        browser.setSplitLayout(.grid)
        check(browser.split?.layout == .grid, "three tabs as a grid")
        browser.close(browser.activeTab!)

        // Geometry: three-tab grid is one tall pane on the left, two stacked on the right.
        let box = NSRect(x: 0, y: 0, width: 1010, height: 810)
        check(SplitGeometry.frames(count: 4, layout: .grid, dividers: [0.5, 0.5], in: box, gap: 10)
              == [NSRect(x: 0, y: 410, width: 500, height: 400), NSRect(x: 510, y: 410, width: 500, height: 400),
                  NSRect(x: 0, y: 0, width: 500, height: 400), NSRect(x: 510, y: 0, width: 500, height: 400)], "2×2 grid frames")
        check(SplitGeometry.frames(count: 3, layout: .grid, dividers: [0.5, 0.5], in: box, gap: 10)
              == [NSRect(x: 0, y: 0, width: 500, height: 810), NSRect(x: 510, y: 410, width: 500, height: 400),
                  NSRect(x: 510, y: 0, width: 500, height: 400)], "three-tab grid frames")
        check(SplitGeometry.frames(count: 3, layout: .rows, dividers: [0.25, 0.5], in: box, gap: 10).map(\.height) == [198, 197, 395],
              "row frames follow the dividers")
        let page = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let halves = [NSRect(x: 0, y: 0, width: 495, height: 800), NSRect(x: 505, y: 0, width: 495, height: 800)]
        check(SplitDropView.target(at: NSPoint(x: 500, y: 30), frames: [page], in: page, canAddPane: true) == .edge(.minY)
              && SplitDropView.target(at: NSPoint(x: 30, y: 400), frames: [page], in: page, canAddPane: true) == .edge(.minX),
              "over a single page, the nearest edge picks the split direction")
        check(SplitDropView.target(at: NSPoint(x: 700, y: 400), frames: halves, in: page, canAddPane: true) == .pane(1)
              && SplitDropView.target(at: NSPoint(x: 990, y: 400), frames: halves, in: page, canAddPane: true) == .edge(.maxX)
              && SplitDropView.target(at: NSPoint(x: 990, y: 400), frames: halves, in: page, canAddPane: false) == .pane(1),
              "in a split, a pane is replaced, and the outer edge adds a pane while there's room")
        browser.unsplit()
        [a, b, c, e].forEach(browser.close)
    }

    /// The tab list shows a split as one block, and dragging a tab out of it unsplits that tab.
    private static func splitInTabList(browser: BrowserWindowController, base: String) async {
        let p = browser.newTab(url: URL(string: "\(base)/one.html?listP"))
        let q = browser.newTab(url: URL(string: "\(base)/one.html?listQ"), activate: false)
        let r = browser.newTab(url: URL(string: "\(base)/one.html?listR"), activate: false)
        browser.split([p, q, r], layout: .columns, focus: p)
        let first = browser.tabs.firstIndex(of: p)!
        check(browser.sidebar.lastSplitRuns == [first...first + 2], "a split's tabs show as one block in the tab list")
        browser.sidebar.moveRow(from: first + 1, to: first + 2)
        check(browser.split?.tabs == [p, q, r], "reordering inside the block keeps the split")
        browser.sidebar.moveRow(from: browser.tabs.firstIndex(of: r)!, to: 0)
        check(!browser.isPaired(r) && browser.split?.tabs == [p, q] && browser.visibleTabs == [p, q],
              "dragging a tab out of the block takes it out of the split")
        browser.removeFromSplit(p)
        check(browser.split == nil && browser.visibleTabs == [p] && browser.sidebar.lastSplitRuns.isEmpty,
              "taking one of two tabs out ends the split")
        // Let the pages finish loading before closing them, so no half-loaded page races the checks that follow.
        await wait { [p, q, r].allSatisfy { !$0.isLoading && $0.pageTitle == "Page One" } }
        [p, q, r].forEach(browser.close)
    }

    /// The address bar above the page, and the tab list on either side.
    /// The full URL in the bar, the URL breakdown, and the lock's connection details.
    private static func addressBar(browser: BrowserWindowController, base: String) async {
        let bar = browser.content.topBar
        let address = "\(base)/one.html?a=1&b=x+y&flag#top"
        let tab = browser.newTab(url: URL(string: address))
        await wait { !tab.isLoading && tab.currentURL?.absoluteString == address }
        browser.window?.makeFirstResponder(tab.webView)
        bar.updateChrome()
        check(bar.field.stringValue == address, "the address bar shows the full URL (\(bar.field.stringValue))")
        let styled = bar.field.attributedStringValue
        let hostAt = (address as NSString).range(of: "localhost").location
        check(hostAt != NSNotFound && styled.attribute(.foregroundColor, at: hostAt, effectiveRange: nil) as? NSColor == .labelColor
              && styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != .labelColor,
              "the host stands out from the rest of the URL")
        check(Keymap.shared.command(for: KeyChord(string: "cmd+alt+l")!) == .urlBreakdown, "⌥⌘L bound to the URL breakdown")

        CommandRouter.perform(.urlBreakdown, in: browser)
        guard let breakdown = bar.popover?.contentViewController as? URLBreakdownController, bar.popover?.isShown == true else {
            return check(false, "the URL breakdown opens")
        }
        _ = breakdown.view
        check(breakdown.scheme.stringValue == "http" && breakdown.host.stringValue == "localhost" && breakdown.port.stringValue == "8765"
              && breakdown.path.stringValue == "/one.html" && breakdown.fragment.stringValue == "top",
              "the breakdown splits scheme, host, port, path and fragment")
        check(breakdown.parameters.map { "\($0.name)=\($0.value)" } == ["a=1", "b=x+y", "flag="], "the breakdown lists the query parameters (\(breakdown.parameters))")
        check(breakdown.url?.absoluteString == address, "an untouched breakdown gives back the same URL (\(breakdown.url?.absoluteString ?? "nil"))")
        breakdown.setParameter(at: 0, value: "2")
        breakdown.addParam()
        breakdown.setParameter(at: 3, name: "q", value: "a&b c")
        let edited = "\(base)/one.html?a=2&b=x+y&flag&q=a%26b%20c#top"
        check(breakdown.url?.absoluteString == edited, "editing parameters rebuilds the URL and encodes new values (\(breakdown.url?.absoluteString ?? "nil"))")
        breakdown.onOpen?(breakdown.url!, false)
        // The popover animates closed, so isShown can lag the page load.
        await wait { !tab.isLoading && tab.currentURL?.absoluteString == edited && bar.popover?.isShown != true }
        check(tab.currentURL?.absoluteString == edited && bar.popover?.isShown != true,
              "Open loads the edited URL and closes the breakdown (got \(tab.currentURL?.absoluteString ?? "nil"), loading \(tab.isLoading), "
              + "popover shown \(bar.popover?.isShown == true), active tab \(browser.activeTab === tab))")

        CommandRouter.perform(.showSiteInfo, in: browser)
        let site = bar.popover?.contentViewController as? SiteInfoController
        check(site?.status.title == "Local server" && site?.chain.isEmpty == true, "the lock on a local HTTP page says so (\(site?.status.title ?? "nil"))")
        bar.popover?.close()

        // TERN_SMOKE_TLS=<https URL> also checks a real certificate chain (needs the network).
        if let tls = ProcessInfo.processInfo.environment["TERN_SMOKE_TLS"], let url = URL(string: tls) {
            tab.load(url)
            await wait(timeout: 20) { !tab.isLoading && tab.currentURL?.host == url.host && tab.webView?.serverTrust != nil }
            CommandRouter.perform(.showSiteInfo, in: browser)
            let info = bar.popover?.contentViewController as? SiteInfoController
            _ = info?.view
            let leaf = info?.chain.first
            check(info?.status.title == "Connection is secure" && (info?.chain.count ?? 0) >= 2, "the lock shows a secure connection and its chain (\(info?.chain.count ?? 0) certificates)")
            check(leaf?.issuer != "Unknown" && leaf?.notAfter != nil && leaf?.names.contains { url.host!.hasSuffix($0.replacingOccurrences(of: "*.", with: "")) } == true,
                  "the leaf certificate has an issuer, an expiry and the host among its names")
            print("INFO  \(url.host!): \(leaf?.subject ?? "") issued by \(leaf?.issuer ?? "") until \(leaf?.notAfter.map { "\($0)" } ?? "")")
            info?.copyPEM()
            check(NSPasteboard.general.string(forType: .string)?.hasPrefix("-----BEGIN CERTIFICATE-----") == true, "Copy PEM Chain copies PEM")
            bar.popover?.close()
        }
        browser.close(tab)
    }

    private static func windowChrome(browser: BrowserWindowController) async {
        let bar = browser.content.topBar
        let root = browser.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let realWidths = ["TernSidebarWidth", "TernSidebarWidthRight"].map {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") as? [String]
        }

        // The default: the tab list on the right, its first row level with the top bar, no empty band above it.
        let rightFrame = browser.sidebar.view.convert(browser.sidebar.view.bounds, to: nil)
        check(abs(rightFrame.width - BrowserWindowController.defaultSidebarWidth) <= 1,
              "with no saved width, the tab list starts \(Int(BrowserWindowController.defaultSidebarWidth))pt wide (\(Int(rightFrame.width))pt)")
        check(browser.isSidebarOnRight && rightFrame.maxX >= root.bounds.width - 1, "the tab list starts on the right")
        if let first = browser.sidebar.firstRowFrame {
            let (row, block, visible) = first
            // That row sits in the titlebar strip: pressing it must start a tab drag, not move the window.
            let hit = root.superview.flatMap { root.hitTest($0.convert(NSPoint(x: row.midX, y: row.midY), from: nil)) }
            check(hit != nil && hit?.mouseDownCanMoveWindow == false,
                  "pressing the first tab doesn't move the window (\(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
            // The window server drags the window from the titlebar strip itself, around only the rects views claim.
            check(browser.sidebar.windowMoveExclusion.contains(NSPoint(x: row.midX, y: row.maxY - 1)),
                  "the window server doesn't drag the window from the first tab (claimed \(browser.sidebar.windowMoveExclusion), row \(row))")
            // Measured from the real row, not from the constants that placed it.
            let chipTop = row.maxY - browser.sidebar.rowChipInset, barTop = bar.convert(bar.bounds, to: nil).maxY
            check(abs(chipTop - barTop) <= 1, "on the right, the first tab starts level with the address bar (tab \(chipTop), bar \(barTop))")
            check(block.maxY <= visible.maxY + 0.5 && block.maxY < root.bounds.height - 1,
                  "on the right, a split block around the first row isn't cut off at the top (block \(block.maxY), list \(visible.maxY))")
        } else {
            check(false, "on the right, the tab list has a first row")
        }
        check(bar.convert(bar.bounds, to: nil).minX >= 70, "with the tab list on the right, the top bar clears the traffic lights")

        // The rest checks the left side, then switches back.
        browser.setSidebarOnRight(false)
        root.layoutSubtreeIfNeeded()
        check(bar.window != nil && bar.pill.frame.width > browser.sidebar.view.frame.width,
              "the address bar sits above the page and is wider than the sidebar (\(Int(bar.pill.frame.width))pt)")
        let barMid = bar.convert(bar.bounds, to: nil).midY
        if let close = browser.window?.standardWindowButton(.closeButton), let container = close.superview {
            let lightsMid = container.convert(close.frame, to: nil).midY
            check(abs(barMid - lightsMid) <= 1 && bar.frame.minX < 20,
                  "the top bar is centered on the traffic lights (bar \(barMid), lights \(lightsMid))")
        }
        let firstRow = browser.sidebar.view.convert(browser.sidebar.view.bounds, to: nil).maxY - browser.sidebar.contentTop
        let barFrame = bar.convert(bar.bounds, to: nil)
        let pageTop = browser.content.pageFrameInWindow.maxY
        check(abs(firstRow - pageTop) <= 1, "the tab list starts level with the page")
        check(abs((root.bounds.height - barFrame.maxY) - (barFrame.minY - pageTop)) <= 1,
              "the top bar has the same space above and below it (\(Int(root.bounds.height - barFrame.maxY)) / \(Int(barFrame.minY - pageTop)))")

        browser.toggleSidebar()
        try? await Task.sleep(for: .milliseconds(300))
        root.layoutSubtreeIfNeeded()
        check(bar.convert(bar.bounds, to: nil).minX >= 70, "with the sidebar hidden, the top bar clears the traffic lights")
        browser.focusAddressBar()
        check((browser.window?.firstResponder as? NSTextView)?.delegate === bar.field, "⌘L focuses the address bar with the sidebar hidden")
        browser.toggleSidebar()
        try? await Task.sleep(for: .milliseconds(300))
        browser.window?.makeFirstResponder(browser.activeTab?.webView)

        let sidebarWidth = browser.sidebar.view.frame.width
        browser.setSidebarOnRight(true)
        root.layoutSubtreeIfNeeded()
        let sidebarFrame = browser.sidebar.view.convert(browser.sidebar.view.bounds, to: nil)
        check(sidebarFrame.maxX >= root.bounds.width - 1 && browser.content.view.frame.minX < sidebarFrame.minX
              && abs(sidebarFrame.width - sidebarWidth) <= 1,
              "the tab list moves to the right and keeps its width (\(Int(sidebarFrame.width)) vs \(Int(sidebarWidth)))")
        check(bar.convert(bar.bounds, to: nil).minX >= 70, "with the tab list on the right, the top bar clears the traffic lights")
        browser.setSidebarOnRight(false)
        root.layoutSubtreeIfNeeded()
        check(browser.sidebar.view.convert(browser.sidebar.view.bounds, to: nil).minX < 1 && bar.convert(bar.bounds, to: nil).minX > sidebarWidth - 1,
              "and back to the left")
        browser.setSidebarOnRight(true)
        root.layoutSubtreeIfNeeded()

        // Dragged to its narrowest, the tab list goes down to the minimum: nothing inside it holds it wider.
        let before = browser.sidebar.view.frame.width
        browser.setSidebarWidth(100)
        root.layoutSubtreeIfNeeded()
        let narrowest = browser.sidebar.view.frame.width
        check(narrowest <= 101 && !browser.isSidebarCollapsed,
              "the tab list drags down to 100pt (\(Int(narrowest))pt)")
        check(!browser.sidebar.showsMemory, "a narrow tab list hides the memory readout")
        browser.setSidebarWidth(before)
        root.layoutSubtreeIfNeeded()
        if before >= 170 { check(browser.sidebar.showsMemory, "and it comes back when the list widens again") }

        let widthsAfter = ["TernSidebarWidth", "TernSidebarWidthRight"].map {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") as? [String]
        }
        check(widthsAfter == realWidths, "resizing and moving the tab list leaves your own saved widths alone")
    }

    private static func welcome(browser: BrowserWindowController) async {
        CommandRouter.perform(.showWelcome, in: browser)
        let sheet = browser.window?.attachedSheet
        check(sheet?.contentViewController is Welcome, "Welcome to Tern opens the welcome sheet")
        if let welcome = sheet?.contentViewController as? Welcome {
            check(welcome.pageCount == 5 && welcome.page == 0, "the welcome has five pages and starts on the first")
            func key(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: sheet?.windowNumber ?? 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            let cmdK = key("k", code: 40, .command)
            check(Keymap.shared.primaryChord(for: .commandPalette) == KeyChord(event: cmdK) && !welcome.press(cmdK),
                  "⌘K on the first page is left to the keymap")
            welcome.go(to: 2)
            check(welcome.page == 2, "it moves to the shortcuts page")
            check(welcome.press(cmdK) && welcome.press(cmdK) && welcome.practiced == [0],
                  "pressing ⌘K there ticks off the palette lesson once instead of opening the palette")
            check(!welcome.press(key("y", code: 16, .command)), "a shortcut that isn't a lesson is left alone")
            welcome.go(to: 4)
            check(welcome.page == 4, "and on to the last page")
        }
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

    /// !bangs, downloads, Export as PDF, muting a tab, and remembered site permissions.
    private static func browsingBasics(browser: BrowserWindowController, base: String, out: URL) async {
        let engine = BrowserEngine.shared
        let gh = engine.resolve(input: "!gh swift-nio")
        check(gh?.host == "github.com" && gh?.query == "q=swift-nio", "!gh searches GitHub (\(gh?.absoluteString ?? "nil"))")
        check(engine.resolve(input: "swift-nio !gh")?.host == "github.com", "a bang at the end works too")
        check(engine.resolve(input: "!mdn")?.absoluteString == "https://developer.mozilla.org/", "a bang alone opens the site")
        check(engine.resolve(input: "!nope foo")?.host == "duckduckgo.com", "an unknown bang is a normal search")
        check(engine.resolve(input: "!g a&b")?.absoluteString.contains("q=a%26b") == true, "bang queries are escaped")
        try? #"{ "jira": "https://acme.example/browse/%s" }"#.write(to: Bangs.fileURL, atomically: true, encoding: .utf8)
        check(engine.resolve(input: "!jira ABC-1")?.absoluteString == "https://acme.example/browse/ABC-1", "custom bangs from bangs.json")
        try? FileManager.default.removeItem(at: Bangs.fileURL)

        // Downloads
        let bar = browser.content.topBar
        check(bar.downloadsButton.isHidden == DownloadManager.shared.items.isEmpty, "the downloads button shows only once there are downloads")
        let tab = browser.newTab(url: URL(string: "\(base)/downloads.html"))
        await wait { tab.pageTitle == "Downloads" && !tab.isLoading }
        _ = try? await tab.webView?.evaluateJavaScript("document.getElementById('dl').click()")
        await wait { DownloadManager.shared.items.first?.state == .finished }
        let item = DownloadManager.shared.items.first
        let size = (item?.destination).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        check(item?.state == .finished && item?.destination?.deletingLastPathComponent().lastPathComponent == "downloads" && size == 16384,
              "a download lands in the downloads folder (\(item.map(DownloadManager.status) ?? "none"), \(size ?? 0) bytes)")
        check(!bar.downloadsButton.isHidden, "the downloads button appears")
        CommandRouter.perform(.showDownloads, in: browser)
        let list = bar.popover?.contentViewController as? DownloadsController
        check(list?.rowCount == DownloadManager.shared.items.count, "Show Downloads lists them (\(list?.rowCount ?? -1) rows)")
        bar.popover?.close()

        // Export as PDF
        if let webView = tab.webView {
            let pdf = out.appendingPathComponent("page.pdf")
            try? FileManager.default.removeItem(at: pdf)
            let ok = await withCheckedContinuation { done in
                PagePrinter.writePDF(of: webView, title: "Downloads", to: pdf, in: browser.window) { done.resume(returning: $0) }
            }
            let head = (try? FileHandle(forReadingFrom: pdf))?.readData(ofLength: 4)
            check(ok && head == Data("%PDF".utf8), "Export as PDF writes a PDF")
        }

        // Mute
        func pageMuted() -> Bool? {
            guard let webView = tab.webView, let m = class_getInstanceMethod(type(of: webView), NSSelectorFromString("_mediaMutedState")) else { return nil }
            typealias Get = @convention(c) (AnyObject, Selector) -> UInt
            return unsafeBitCast(method_getImplementation(m), to: Get.self)(webView, NSSelectorFromString("_mediaMutedState")) & 1 == 1
        }
        tab.isMuted = true
        if let muted = pageMuted() { check(muted, "muting a tab mutes its page") }
        // Only a tab that isn't shown can be suspended.
        let away = browser.newTab(url: URL(string: "\(base)/two.html?mute"))
        browser.activate(away)
        tab.suspend()
        check(tab.isSuspended, "the muted tab is suspended")
        browser.activate(tab)
        await wait { tab.webView != nil && !tab.isLoading }
        check(tab.isMuted && pageMuted() != false, "a muted tab stays muted after it's suspended")
        browser.close(away)
        CommandRouter.perform(.toggleMuteTab, in: browser)
        check(!tab.isMuted, "Mute or Unmute Tab")

        // Site permissions
        let origin = "http://localhost:8765"
        check(SitePermissions.remembered(.camera, for: origin) == nil, "no permission is remembered by default")
        Preferences.sitePermissions["\(origin)|camera"] = true
        var answer: Bool?
        SitePermissions.ask(.camera, origin: origin, in: browser.window) { answer = $0 }
        check(answer == true, "a remembered answer is used without asking")
        SitePermissions.reset(for: URL(string: "\(origin)/one.html")!)
        check(SitePermissions.remembered(.camera, for: origin) == nil, "Reset Permissions for This Site")
        print("INFO  default browser: \(DefaultBrowser.isDefault ? "Tern" : "another app")")
        browser.close(tab)
    }

    /// A private window keeps nothing: in-memory site data, no history, no session, no extensions.
    private static func privateWindow(base: String) async {
        let url = URL(string: "\(base)/one.html?private-smoke")!
        let window = AppDelegate.shared.openWindow(restoring: [Tab(url: url)], isPrivate: true)
        let tab = window.activeTab!
        await wait { tab.pageTitle == "Page One" && !tab.isLoading }
        check(window.isPrivate && tab.isPrivate, "New Private Window opens a private window")
        check(tab.webView?.configuration.websiteDataStore.isPersistent == false, "private tabs use an in-memory data store")
        check(HistoryStore.shared.entries[url.absoluteString] == nil, "private pages aren't added to history")
        check(window.content.topBar.showsPrivateBadge, "a private window says so in the top bar")
        check(!ExtensionManager.windowsForExtensions.contains { $0 === window }, "extensions don't see private windows")
        let other = window.newTab(url: URL(string: "\(base)/two.html?private-smoke")!)
        await wait { other.pageTitle == "Page Two" && !other.isLoading }
        let cookie = try? await tab.webView?.evaluateJavaScript("document.cookie = 'p=1'; document.cookie")
        let shared = try? await other.webView?.evaluateJavaScript("document.cookie")
        check((cookie as? String) == "p=1" && (shared as? String) == "p=1", "a private window's tabs share their cookies")
        window.window?.performClose(nil)
        await wait { !AppDelegate.shared.windows.contains { $0 === window } }
        check(!AppDelegate.shared.windows.contains { $0 === window }, "closing a private window")
    }

    /// The Requests window: it picks up what the page already loaded, filters, clears, and starts over on reload.
    private static func requests(browser: BrowserWindowController, base: String) async {
        let tab = browser.newTab(url: URL(string: "\(base)/requests.html")!)
        await wait { tab.pageTitle == "Requests" && !tab.isLoading }
        for _ in 0..<40 {
            if ((try? await tab.webView?.evaluateJavaScript("document.getElementById('status').textContent")) as? String) == "Done" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        CommandRouter.perform(.showRequests, in: browser)
        guard let inspector = RequestInspector.inspector(for: tab) else { return check(false, "Requests opens a window for the tab") }
        func has(_ name: String) -> Bool { inspector.entries.contains { $0.url.hasSuffix(name) } }
        await wait { has("style.css") && has("data.json") && has("missing.json") }
        check(inspector.window?.isVisible == true && has("style.css") && has("data.json") && has("missing.json"),
              "Requests lists what the page already loaded (\(inspector.entries.map { URL(string: $0.url)?.lastPathComponent ?? "" }))")
        let missing = inspector.entries.first { $0.url.hasSuffix("missing.json") }
        print("INFO  requests: missing.json status \(missing?.status ?? -1), type \(missing?.type ?? "none")")
        check(missing?.status == 0 || missing?.status == 404, "a failed request shows its status when WebKit reports one")
        inspector.filter = .fetch
        check(!inspector.rows.isEmpty && inspector.rows.allSatisfy { $0.kind == .fetch }, "filtering to Fetch/XHR (\(inspector.rows.count) rows)")
        inspector.filter = .stylesheet
        check(inspector.rows.map { URL(string: $0.url)?.lastPathComponent } == ["style.css"], "filtering to stylesheets")
        inspector.filter = .all
        inspector.clearLog()
        check(inspector.entries.isEmpty, "Clear empties the list")
        let before = tab.loadsEnded
        tab.webView?.reload()
        await wait { tab.loadsEnded > before && !tab.isLoading }
        await wait { has("data.json") && inspector.entries.contains { $0.kind == .document } }
        check(has("data.json") && inspector.entries.contains { $0.kind == .document }, "requests after a reload are listed, with the document itself")
        check(RequestInspector.curl(inspector.entries[0]).hasPrefix("curl 'http://localhost:8765/"), "Copy as cURL")
        browser.close(tab)
        await wait { RequestInspector.inspector(for: tab) == nil }
        check(RequestInspector.inspector(for: tab) == nil && inspector.window?.isVisible != true, "closing the tab closes its Requests window")
    }

    /// Responsive design mode, the JSON viewer, and the reader.
    private static func pageTools(browser: BrowserWindowController, base: String) async {
        let tab = browser.newTab(url: URL(string: "\(base)/one.html?device")!)
        await wait { tab.pageTitle == "Page One" && !tab.isLoading }
        func innerWidth() async -> Int? { (try? await tab.webView?.evaluateJavaScript("window.innerWidth")) as? Int }
        func reloaded(_ change: () -> Void) async {
            let before = tab.loadsEnded
            change()
            await wait { tab.loadsEnded > before && !tab.isLoading }
        }
        await reloaded { CommandRouter.perform(.responsiveDesignMode, in: browser) }
        let device = tab.devicePreview?.size ?? .zero
        check(tab.devicePreview != nil && tab.webView?.frame.width == device.width, "responsive design mode lays the page out at the device's width (\(tab.webView?.frame.width ?? 0) vs \(device.width))")
        let width = await innerWidth()
        check(width == Int(device.width), "the page sees the device's viewport (innerWidth \(width ?? 0))")
        check(tab.webView?.customUserAgent?.contains("iPhone") == true, "and an iPhone user agent")
        CommandRouter.perform(.rotateDevice, in: browser)
        browser.content.view.layoutSubtreeIfNeeded()
        check(tab.webView?.frame.width == min(device.height, (tab.webView?.superview?.bounds.width ?? 0) - 24), "Rotate Device swaps width and height")
        await reloaded { CommandRouter.perform(.responsiveDesignMode, in: browser) }
        check(tab.devicePreview == nil && tab.webView?.customUserAgent?.isEmpty != false && tab.webView?.frame.width == tab.webView?.superview?.bounds.width,
              "leaving responsive design mode restores the page (agent \(tab.webView?.customUserAgent ?? "nil"), width \(tab.webView?.frame.width ?? 0) of \(tab.webView?.superview?.bounds.width ?? 0))")

        // JSON viewer
        tab.load(URL(string: "\(base)/data.json")!)
        await wait { tab.currentURL?.lastPathComponent == "data.json" && !tab.isLoading }
        var viewer: Any?
        await wait {
            tab.webView?.evaluateJavaScript("document.documentElement.dataset.ternJson") { r, _ in viewer = r }
            return viewer as? String == "tree"
        }
        let details = try? await tab.webView?.evaluateJavaScript("document.querySelectorAll('#tern-json-tree details').length")
        check(viewer as? String == "tree" && ((details as? Int) ?? 0) >= 4, "JSON opens in the viewer (\(details ?? "nil") nodes)")

        // Reader
        tab.load(URL(string: "\(base)/article.html")!)
        await wait { tab.pageTitle == "A Long Read | Smoke" && !tab.isLoading }
        CommandRouter.perform(.toggleReader, in: browser)
        await wait { browser.content.reader(for: tab) != nil }
        let reader = browser.content.reader(for: tab)
        check(reader?.article.title == "A Long Read" && (reader?.article.words ?? 0) > 400, "Reader finds the article (\(reader?.article.title ?? "none"), \(reader?.article.words ?? 0) words)")
        check(reader?.article.html.contains("Footer text") == false && reader?.article.html.contains("newsletter") == false, "Reader leaves out the page around it")
        check(reader?.superview != nil, "Reader shows over the page")
        tab.load(URL(string: "\(base)/two.html")!)
        await wait { tab.pageTitle == "Page Two" && !tab.isLoading }
        check(browser.content.reader(for: tab) == nil && reader?.superview == nil, "Reader closes when the tab navigates")
        browser.close(tab)
    }

    /// Pinned tabs that go back to their page, archiving idle tabs, and compact mode.
    private static func tabHousekeeping(browser: BrowserWindowController, base: String) async {
        // Pinned tabs
        let home = URL(string: "\(base)/one.html?pinned")!
        let other = browser.newTab(url: URL(string: "\(base)/two.html?other")!)
        await wait { other.pageTitle == "Page Two" && !other.isLoading }
        let pinned = browser.newTab(url: home)
        await wait { pinned.pageTitle == "Page One" && !pinned.isLoading }
        browser.setPinned(pinned, true)
        check(pinned.pinnedURL == home, "pinning remembers the pinned page")
        pinned.load(URL(string: "\(base)/two.html?wandered")!)
        await wait { pinned.currentURL?.query == "wandered" && !pinned.isLoading }
        check(pinned.hasLeftPinnedURL, "a pinned tab knows it left its page")
        CommandRouter.perform(.closeTab, in: browser)
        await wait { pinned.currentURL == home && !pinned.isLoading }
        check(browser.tabs.contains(pinned) && pinned.currentURL == home, "⌘W on a wandered pinned tab takes it back to its page")
        CommandRouter.perform(.closeTab, in: browser)
        check(browser.tabs.contains(pinned) && pinned.isSuspended && browser.activeTab === other,
              "⌘W on a pinned tab at its page puts it to sleep and shows the previous tab")
        browser.activate(pinned)
        pinned.load(URL(string: "\(base)/two.html?new-home")!)
        await wait { pinned.currentURL?.query == "new-home" && !pinned.isLoading }
        CommandRouter.perform(.repinTab, in: browser)
        check(pinned.pinnedURL?.query == "new-home" && !pinned.hasLeftPinnedURL, "Make This the Pinned Page")
        browser.setPinned(pinned, false)
        check(pinned.pinnedURL == nil, "unpinning forgets the pinned page")
        browser.close(pinned)

        // Archive
        let stale = browser.newTab(url: URL(string: "\(base)/two.html?stale")!, activate: false)
        stale.lastActivated = Date().addingTimeInterval(-3 * 3600)
        let blank = browser.newTab(url: nil, activate: false)
        blank.lastActivated = stale.lastActivated
        let count = browser.tabs.count
        ArchiveStore.shared.sweep(olderThan: 2 * 3600)
        check(!browser.tabs.contains(stale) && browser.tabs.count == count - 1, "a tab idle past the archive time closes")
        check(browser.tabs.contains(blank), "a blank tab the archive couldn't bring back stays open")
        browser.close(blank)
        let entry = ArchiveStore.shared.entries.first
        check(entry?.url == "\(base)/two.html?stale", "and goes to the archive (\(entry?.url ?? "nothing"))")
        ArchiveStore.shared.sweep(olderThan: 2 * 3600)
        check(browser.tabs.contains(other), "recent tabs stay")
        if let entry {
            ArchiveStore.shared.restore(entry, in: browser)
            check(browser.activeTab?.currentURL?.absoluteString == entry.url && ArchiveStore.shared.entries.isEmpty, "opening an archived tab brings it back")
            browser.activeTab.map(browser.close)
        }
        browser.close(other)

        // Compact mode
        let content = browser.content
        CommandRouter.perform(.toggleCompactMode, in: browser)
        browser.window?.layoutIfNeeded()
        let pageTop = content.view.bounds.height - content.pageFrameInWindow.maxY
        check(content.isCompact && content.topBar.isHidden && pageTop <= Theme.gutter + 1, "compact mode hides the top bar and moves the page up (\(pageTop))")
        CommandRouter.perform(.focusAddressBar, in: browser)
        check(content.isBarRevealed && !content.topBar.isHidden, "⌘L shows the bar in compact mode")
        browser.window?.makeFirstResponder(browser.activeTab?.webView)
        await wait { !content.isBarRevealed }
        CommandRouter.perform(.toggleCompactMode, in: browser)
        browser.window?.layoutIfNeeded()
        check(!content.isCompact && !content.topBar.isHidden && content.topBar.alphaValue == 1, "leaving compact mode brings the bar back")
    }

    /// Filter-list conversion, tracking parameters, and blocking on a page with the smoke filter list.
    private static func privacy(browser: BrowserWindowController, base: String) async {
        let rules = FilterList.convert("""
        ||ads.example^$third-party,script
        /track/*$~image
        @@||ads.example/ok.js
        example.com##.promo
        ##.banner
        example.com#@#.banner
        /^regex$/
        ||x.example^$redirect=noop.js
        ##div:has-text(Sponsored)
        """)
        func trigger(_ i: Int) -> [String: Any] { rules.indices.contains(i) ? rules[i]["trigger"] as? [String: Any] ?? [:] : [:] }
        func action(_ i: Int) -> String? { rules.indices.contains(i) ? (rules[i]["action"] as? [String: Any])?["type"] as? String : nil }
        check(rules.count == 6, "filter list: unsupported filters skipped (got \(rules.count) rules)")
        check(trigger(0)["url-filter"] as? String == #"^[^:]+:(//)?([^/]+\.)?ads\.example[^a-zA-Z0-9_.%-]"#
              && trigger(0)["load-type"] as? [String] == ["third-party"] && trigger(0)["resource-type"] as? [String] == ["script"],
              "filter list: host anchor, separator, type and party")
        check((trigger(1)["resource-type"] as? [String])?.contains("image") == false && trigger(1)["url-filter"] as? String == "/track/",
              "filter list: negated type")
        check(trigger(2)["load-context"] as? [String] == ["top-frame"] && action(2) == "ignore-previous-rules", "filter list: pages you open aren't blocked")
        check(trigger(3)["unless-domain"] as? [String] == ["*example.com"] && trigger(4)["if-domain"] as? [String] == ["*example.com"],
              "filter list: element hiding per site, and its exceptions")
        check(action(5) == "ignore-previous-rules", "filter list: exceptions come last")
        // `$~image` expands to every other type, fetch, websocket, ping and other included: WebKit must take them all.
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: rules)) ?? Data(), as: UTF8.self)
        let compiled: Bool = await withCheckedContinuation { done in
            WKContentRuleListStore.default()!.compileContentRuleList(forIdentifier: "smoke-types", encodedContentRuleList: json) { list, error in
                if let error { print("INFO  rule list error: \(error)") }
                done.resume(returning: list != nil)
            }
        }
        check(compiled, "filter list: converted rules compile, every resource type included")

        check(TrackingParameters.strip(URL(string: "https://a.com/p?utm_source=x&id=2&fbclid=y#top")!)?.absoluteString == "https://a.com/p?id=2#top",
              "tracking parameters stripped, the rest kept")
        check(TrackingParameters.strip(URL(string: "https://a.com/?utm_medium=a")!)?.absoluteString == "https://a.com/"
              && TrackingParameters.strip(URL(string: "https://a.com/?q=utm_source")!) == nil, "tracking parameters: whole query, and values left alone")

        let blocker = ContentBlocker.shared
        let page = URL(string: "\(base)/ads.html")!
        check(!blocker.isEnabled(for: page) && blocker.isEnabled(for: URL(string: "https://www.example.com/")), "blocking is off on localhost, on elsewhere")
        blocker.toggle(for: URL(string: "https://example.com/a"))
        check(!blocker.isEnabled(for: URL(string: "https://www.example.com/b")), "turning a site off covers its www. host")
        blocker.toggle(for: URL(string: "https://example.com/a"))

        await blocker.update()
        check(blocker.installed["smoke"] != nil && blocker.installed["tern"] != nil, "filter lists compiled")
        let tab = browser.newTab(url: page)
        await wait { tab.pageTitle == "Ads" && !tab.isLoading }
        func probe() async -> String? {
            try? await tab.webView?.evaluateJavaScript("(window.ternAd ? 'ad' : 'none') + ',' + getComputedStyle(document.querySelector('.tern-test-ad')).display") as? String
        }
        func loaded(_ action: () -> Void) async {
            let before = tab.loadsEnded
            action()
            await wait { tab.loadsEnded > before && !tab.isLoading }
        }
        let unblocked = await probe()
        check(unblocked == "ad,block", "a local dev server loads everything (got \(unblocked ?? "nil"))")
        await loaded { CommandRouter.perform(.toggleSiteBlocking, in: browser) }
        let blocked = await probe()
        check(blocker.isEnabled(for: page) && blocked == "none,none", "Toggle Ad Blocking blocks the script and hides the element (got \(blocked ?? "nil"))")
        await loaded { tab.load(URL(string: "\(base)/one.html?utm_source=smoke&keep=1")!) }
        await wait { tab.pageTitle == "Page One" && !tab.isLoading }
        check(tab.currentURL?.query == "keep=1", "tracking parameters removed before the page loads (got \(tab.currentURL?.query ?? "nil"))")
        blocker.toggle(for: page)
        await loaded { tab.load(URL(string: "\(base)/one.html?utm_source=dev")!) }
        check(tab.currentURL?.query == "utm_source=dev", "with blocking off, links keep their parameters")
        browser.close(tab)
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
              "tabs open waits for the load (\(opened.out.prefix(400)))")
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
        let others = browser.tabs.filter { $0.id.uuidString != id }.prefix(2).map(\.id.uuidString)
        let trio = await tern(["tabs", "split", "--tabIds", ([id] + others).joined(separator: ","), "--layout", "grid"])
        check(browser.split?.tabs.map(\.id.uuidString) == [id] + others && browser.split?.layout == .grid
              && (trio.json?["split"] as? [String: Any])?["layout"] as? String == "grid", "tabs split with tabIds and a layout (\(trio.out.prefix(120)))")
        let pairGrid = await tern(["tabs", "split", "--tabIds", "\(id),\(others[0])", "--layout", "grid"])
        check(pairGrid.status == 1 && browser.split?.tabs.count == 3, "tabs split refuses a grid of two")
        let twice = await tern(["tabs", "split", "--tabIds", "\(id),\(id)"])
        check(twice.status == 1, "tabs split refuses the same tab twice")
        _ = await tern(["tabs", "split", "--leftTabId", id, "--rightTabId", others[0]])
        check(browser.split?.tabs.map(\.id.uuidString) == [id, others[0]] && browser.split?.layout == .columns,
              "tabs split with leftTabId and rightTabId")
        browser.unsplit()

        let unknown = await tern(["tabs", "frobnicate"])
        check(unknown.status == 1 && unknown.out.contains("-32601"), "unknown method is an error")

        // agentOwnTabsOnly: tabs the agent didn't open are read-only.
        let defaults = UserDefaults.tern
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
