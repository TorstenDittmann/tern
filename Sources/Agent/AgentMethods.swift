import AppKit
import WebKit

/// The browser-level methods of the agent API: `tern.*`, `commands.*`, `windows.*` and `tabs.*`.
/// Everything runs on the main actor, the same way menu items and key bindings do.
@MainActor
enum AgentMethods {
    static let apiVersion = 1

    typealias Handler = @MainActor (AgentParams) async throws -> Any

    private static let table: [String: Handler] = browserMethods
        .merging(AgentPageMethods.table) { mine, _ in mine }
        .merging(AgentLogMethods.table) { mine, _ in mine }

    private static let browserMethods: [String: Handler] = [
        "tern.hello": hello,
        "tern.metrics": metrics,
        "commands.list": listCommands,
        "commands.run": runCommand,
        "windows.list": listWindows,
        "windows.open": openWindow,
        "tabs.list": listTabs,
        "tabs.open": openTab,
        "tabs.activate": activateTab,
        "tabs.close": closeTab,
        "tabs.navigate": navigate,
        "tabs.back": { try await history($0, needs: \.canGoBack, "go back to") { $0.goBack() } },
        "tabs.forward": { try await history($0, needs: \.canGoForward, "go forward to") { $0.goForward() } },
        "tabs.reload": { try await history($0) { $0.reload() } },
        "tabs.split": split,
        "tabs.pin": pin,
        "history.search": searchHistory,
        "history.clear": { _ in HistoryStore.shared.clear(); return ["ok": true] },
    ]

    static func call(_ method: String, _ params: AgentParams) async throws -> Any {
        guard let handler = table[method] else { throw AgentError.methodNotFound(method) }
        return try await handler(params)
    }

    // MARK: Scope

    /// Tabs opened through the API. With `agentOwnTabsOnly` on, agents can act on these and
    /// only read the rest. Off by default: agents drive any tab, including logged-in ones.
    private static var agentTabs: Set<UUID> = []
    private static var ownTabsOnly: Bool { UserDefaults.standard.bool(forKey: "agentOwnTabsOnly") }

    static func checkControl(_ tab: Tab) throws {
        if ownTabsOnly, !agentTabs.contains(tab.id) { throw AgentError.notAllowed }
        AgentActivity.shared.touch(tab)
    }

    // MARK: tern / commands

    private static func hello(_ p: AgentParams) async throws -> Any {
        let info: [String: Any] = [
            "name": "Tern",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "apiVersion": apiVersion,
            "methods": table.keys.sorted(),
        ]
        return info
    }

    /// Launch timings and memory, for benchmarks.
    private static func metrics(_ p: AgentParams) async throws -> Any {
        let tabs = AppDelegate.shared.allTabs
        let result: [String: Any] = [
            "launch": Metrics.launch(),
            "memory": Metrics.memory(),
            "tabs": tabs.count,
            "loadedTabs": tabs.filter { $0.webView != nil }.count,
        ]
        return result
    }

    /// Runs `action` and draws the windows it changed, returning how long that took in ms.
    /// Page content composites asynchronously in WebKit's own process and isn't included.
    private static func timed(_ action: () -> Void) -> Double {
        let start = DispatchTime.now()
        action()
        for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
        return (Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 10_000).rounded() / 100
    }

    private static func listCommands(_ p: AgentParams) async throws -> Any {
        Command.allCases.map { command -> [String: Any] in
            [
                "name": command.rawValue,
                "title": command.title,
                "binding": orNull(Keymap.shared.primaryChord(for: command)?.description),
            ]
        }
    }

    private static func runCommand(_ p: AgentParams) async throws -> Any {
        let name = try p.requiredString("command")
        guard let command = Command(rawValue: name) else { throw AgentError.invalidParams("Unknown command \(name)") }
        let browser = try p.string("windowId").map(window) ?? currentBrowser
        if let tab = browser?.activeTab, command.actsOnActiveTab { try checkControl(tab) }
        if command == .closeWindow { try browser?.tabs.forEach(checkControl) } // every tab in it goes
        let duration = timed { CommandRouter.perform(command, in: browser) }
        return ["ok": true, "durationMs": duration]
    }

    // MARK: windows

    private static func listWindows(_ p: AgentParams) async throws -> Any {
        AppDelegate.shared.windows.map { describe($0) }
    }

    private static func openWindow(_ p: AgentParams) async throws -> Any {
        let url = try p.string("url").map(resolve)
        let browser = AppDelegate.shared.openWindow(restoring: url.map { [Tab(url: $0)] } ?? [])
        if let tab = browser.activeTab {
            agentTabs.insert(tab.id)
            if url != nil { try await waitForLoad(tab, p) }
        }
        return describe(browser)
    }

    // MARK: tabs

    private static func listTabs(_ p: AgentParams) async throws -> Any {
        let windows = try p.string("windowId").map { [try window($0)] } ?? AppDelegate.shared.windows
        return windows.flatMap(\.tabs).map { describe($0) }
    }

    private static func openTab(_ p: AgentParams) async throws -> Any {
        let url = try p.string("url").map(resolve)
        let background = try p.bool("background") ?? false
        let browser = try p.string("windowId").map(window) ?? currentBrowser ?? AppDelegate.shared.openWindow()
        let tab = browser.newTab(url: url, activate: !background)
        agentTabs.insert(tab.id)
        if url != nil {
            if background { tab.materialize() } // background tabs load lazily otherwise
            try await waitForLoad(tab, p)
        }
        return describe(tab)
    }

    private static func activateTab(_ p: AgentParams) async throws -> Any {
        let tab = try findTab(p, required: true)
        let duration = timed {
            tab.owner?.activate(tab)
            tab.owner?.window?.makeKeyAndOrderFront(nil)
        }
        var result = describe(tab)
        result["durationMs"] = duration
        return result
    }

    private static func closeTab(_ p: AgentParams) async throws -> Any {
        let tab = try findTab(p, required: true)
        try checkControl(tab)
        tab.owner?.close(tab)
        agentTabs.remove(tab.id)
        return ["ok": true]
    }

    private static func navigate(_ p: AgentParams) async throws -> Any {
        let tab = try findTab(p)
        try checkControl(tab)
        let url = try resolve(p.requiredString("url"))
        tab.load(url)
        if tab.webView == nil { tab.materialize() } // a suspended tab only stores the URL
        try await waitForLoad(tab, p)
        return describe(tab)
    }

    /// `needs`: when false, WebKit would do nothing and send no callback, so fail fast instead of timing out.
    private static func history(_ p: AgentParams, needs: KeyPath<WKWebView, Bool>? = nil, _ what: String = "",
                                _ action: (WKWebView) -> Void) async throws -> Any {
        let tab = try findTab(p)
        try checkControl(tab)
        let wasSuspended = tab.isSuspended
        let webView = tab.materialize()
        if let needs {
            // A suspended tab restores its back/forward list asynchronously; give it a moment.
            if wasSuspended {
                let deadline = Date().addingTimeInterval(2)
                while !webView[keyPath: needs], Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            }
            if !webView[keyPath: needs] { throw AgentError(code: -32006, message: "No page to \(what)") }
        }
        action(webView)
        try await waitForLoad(tab, p)
        return describe(tab)
    }

    private static func split(_ p: AgentParams) async throws -> Any {
        let left = try findTab(id: p.requiredString("leftTabId"))
        let right = try findTab(id: p.requiredString("rightTabId"))
        guard let browser = left.owner, browser === right.owner else {
            throw AgentError.invalidParams("Both tabs must be in the same window")
        }
        try checkControl(left)
        try checkControl(right)
        browser.split(left, with: right, focus: left)
        return describe(browser)
    }

    private static func pin(_ p: AgentParams) async throws -> Any {
        let tab = try findTab(p, required: true)
        try checkControl(tab)
        tab.owner?.setPinned(tab, try p.bool("pinned") ?? true)
        return describe(tab)
    }

    // MARK: history

    /// Pages from history, best match first (or by frecency without a query).
    private static func searchHistory(_ p: AgentParams) async throws -> Any {
        let query = try p.string("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let limit = try max(1, p.integer("limit") ?? 20)
        let entries = HistoryStore.shared.ranked()
        let matched = query.isEmpty ? entries : entries.compactMap { e -> (Int, HistoryStore.Entry)? in
            guard let s = [CommandPalette.score(query, e.title ?? ""), CommandPalette.score(query, HistoryStore.bare(e.url))]
                .compactMap({ $0 }).max() else { return nil }
            return (s + Frecency.bonus(e.frecency), e)
        }.sorted { $0.0 > $1.0 }.map(\.1)
        return matched.prefix(limit).map { e -> [String: Any] in
            [
                "url": e.url,
                "title": orNull(e.title),
                "visits": e.visits,
                "lastVisit": (e.lastVisit.timeIntervalSince1970 * 1000).rounded(),
                "frecency": e.frecency.rounded(),
            ]
        }
    }

    // MARK: Helpers

    private static var currentBrowser: BrowserWindowController? {
        AppDelegate.shared.keyBrowser ?? AppDelegate.shared.windows.last
    }

    private static func window(_ id: String) throws -> BrowserWindowController {
        guard let browser = AppDelegate.shared.windows.first(where: { $0.id.uuidString == id }) else {
            throw AgentError.invalidParams("No window with id \(id)")
        }
        return browser
    }

    private static func findTab(id: String) throws -> Tab {
        guard let tab = AppDelegate.shared.allTabs.first(where: { $0.id.uuidString == id }) else {
            throw AgentError.tabNotFound(id)
        }
        return tab
    }

    /// The tab named by `tabId`, or the active tab of the frontmost window.
    static func findTab(_ p: AgentParams, required: Bool = false) throws -> Tab {
        if let id = try p.string("tabId") { return try findTab(id: id) }
        if required { throw AgentError.invalidParams("Missing tabId") }
        guard let tab = currentBrowser?.activeTab else { throw AgentError(code: -32001, message: "No open tab") }
        return tab
    }

    /// Accepts anything the address bar does: full URLs, `localhost:3000`, bare hosts.
    private static func resolve(_ input: String) throws -> URL {
        guard let url = BrowserEngine.shared.resolve(input: input) else { throw AgentError.invalidParams("Not a URL: \(input)") }
        return url
    }

    /// `wait`: "none", "load" (default) or "idle" (load, then 500 ms of quiet).
    static func waitForLoad(_ tab: Tab, _ p: AgentParams) async throws {
        let mode = try p.string("wait") ?? "load"
        guard ["none", "load", "idle"].contains(mode) else { throw AgentError.invalidParams("wait must be none, load or idle") }
        guard mode != "none" else { return }
        let timeout = (try p.number("timeoutMs") ?? 30_000) / 1000
        let deadline = Date().addingTimeInterval(timeout)
        let before = tab.loadsEnded, started = Date()
        // The previous page's didFinish can land just after its isLoading went false, so only a
        // load that ends after this one was seen starting counts.
        var startedAt: Int?
        var stoppedAt: Date?
        while true {
            if tab.isLoading {
                if startedAt == nil { startedAt = tab.loadsEnded }
                stoppedAt = nil
            } else if let startedAt {
                if tab.loadsEnded > startedAt { break }
                // Stopped without a finish callback (Stop, suspended, crashed): don't wait for one forever.
                if let stoppedAt, Date() > stoppedAt.addingTimeInterval(1) { break }
                if stoppedAt == nil { stoppedAt = Date() }
            } else if tab.loadsEnded > before, Date() > started.addingTimeInterval(0.3) {
                break // started and ended between two polls
            }
            guard Date() < deadline else { throw AgentError.timeout("\(tab.currentURL?.absoluteString ?? "the page") to load") }
            try await Task.sleep(for: .milliseconds(25))
        }
        if mode == "idle" { try await Task.sleep(for: .milliseconds(500)) }
    }

    /// After a click or key press: if it started a navigation, wait for it like `wait` says.
    static func settle(_ tab: Tab, loadsBefore: Int, _ p: AgentParams) async throws {
        try await Task.sleep(for: .milliseconds(150))
        guard tab.isLoading || tab.loadsEnded != loadsBefore else { return }
        let mode = try p.string("wait") ?? "load"
        guard mode != "none" else { return }
        let deadline = Date().addingTimeInterval((try p.number("timeoutMs") ?? 30_000) / 1000)
        while tab.isLoading {
            guard Date() < deadline else { throw AgentError.timeout("\(tab.currentURL?.absoluteString ?? "the page") to load") }
            try await Task.sleep(for: .milliseconds(25))
        }
        if mode == "idle" { try await Task.sleep(for: .milliseconds(500)) }
    }

    /// JSON null for a missing value.
    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func describe(_ tab: Tab) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "windowId": orNull(tab.owner?.id.uuidString),
            "index": orNull(tab.owner?.tabs.firstIndex(of: tab)),
            "url": orNull(tab.currentURL?.absoluteString),
            "title": tab.displayTitle,
            "loading": tab.isLoading,
            "suspended": tab.isSuspended,
            "active": tab.isActive,
            "visible": tab.isVisible,
            "openedByAgent": agentTabs.contains(tab.id),
            "pinned": tab.isPinned,
        ]
    }

    private static func describe(_ browser: BrowserWindowController) -> [String: Any] {
        [
            "id": browser.id.uuidString,
            "key": browser.window?.isKeyWindow ?? false,
            "activeTabId": orNull(browser.activeTab?.id.uuidString),
            "tabIds": browser.tabs.map(\.id.uuidString),
            "split": orNull(browser.split.map { ["leftTabId": $0.left.id.uuidString, "rightTabId": $0.right.id.uuidString] }),
        ]
    }
}

private extension Command {
    /// Commands that change the active tab or its page, gated by `agentOwnTabsOnly`.
    var actsOnActiveTab: Bool {
        switch self {
        case .closeTab, .duplicateTab, .reload, .hardReload, .stopLoading, .goBack, .goForward,
             .moveTabUp, .moveTabDown, .togglePinTab, .toggleSplit, .splitWith, .splitWithPreviousTab, .swapPanes,
             .zoomIn, .zoomOut, .zoomReset, .linkHints: true
        default: false
        }
    }
}
