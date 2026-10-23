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
        browser.activate(left)
        check(browser.visibleTabs.count == 2, "returning to a paired tab restores the split")
        right.suspend()
        check(!right.isSuspended, "visible split pane is never suspended")
        CommandRouter.perform(.closeTab, in: browser)
        check(browser.split == nil && browser.activeTab === right, "closing one pane ends split, focuses the other")
        CommandRouter.perform(.splitWithPreviousTab, in: browser)
        check(browser.visibleTabs.count == 2, "split with previous tab")
        CommandRouter.perform(.toggleSplit, in: browser)
        check(browser.split == nil && browser.visibleTabs.count == 1, "⌘\\ again unsplits")
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

    /// Drives the agent API through the embedded `tern` CLI, the way an agent would.
    private static func agentAPI(browser: BrowserWindowController, base: String) async {
        guard AgentServer.shared.isRunning else { return check(false, "agent API listening (TERN_SOCKET set by make smoke)") }
        let before = browser.tabs.count

        let hello = await tern(["hello"])
        check(hello.status == 0 && (hello.json?["apiVersion"] as? Int) == 1, "tern hello (\(hello.out.prefix(80)))")

        let opened = await tern(["tabs", "open", "\(base)/one.html", "--windowId", browser.id.uuidString])
        let id = opened.json?["id"] as? String ?? ""
        check(opened.json?["title"] as? String == "Page One" && opened.json?["openedByAgent"] as? Bool == true,
              "tabs open waits for the load")
        check(browser.tabs.count == before + 1 && browser.activeTab?.id.uuidString == id, "tabs open adds an active tab")

        let list = await tern(["tabs", "list", "--plain"])
        check(list.status == 0 && list.out.contains(id), "tabs list --plain")

        let nav = await tern(["tabs", "navigate", "\(base)/two.html", "--tabId", id])
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
    private static func tern(_ args: [String]) async -> CLIResult {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tern")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return await withCheckedContinuation { done in
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                done.resume(returning: CLIResult(status: p.terminationStatus, out: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch {
                done.resume(returning: CLIResult(status: -1, out: "\(error)"))
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
