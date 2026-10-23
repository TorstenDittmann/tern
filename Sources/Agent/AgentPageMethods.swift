import AppKit
import WebKit

/// The `page.*` methods: read a page as a snapshot with element refs, then act on those refs.
/// Clicks and key presses are real `NSEvent`s sent to the web view (pages see `isTrusted: true`)
/// whenever the tab is on screen, and fall back to DOM events when it isn't.
@MainActor
enum AgentPageMethods {
    static let world = WKContentWorld.world(name: "tern-agent")

    static let table: [String: AgentMethods.Handler] = [
        "page.snapshot": snapshot,
        "page.text": pageText,
        "page.click": click,
        "page.type": typeText,
        "page.press": press,
        "page.scroll": scroll,
        "page.select": select,
        "page.eval": eval,
        "page.waitFor": waitFor,
        "page.screenshot": screenshot,
        "page.audit": audit,
    ]

    // MARK: Reading

    private static func snapshot(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        var args: [String: Any] = [:]
        if let scope = try p.string("scope") { args["scope"] = scope }
        if let max = try p.number("maxLines") { args["maxLines"] = Int(max) }
        return try await run(tab, "snapshot", args)
    }

    private static func pageText(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        var args: [String: Any] = ["format": try p.string("format") ?? "text"]
        if let scope = try p.string("scope") { args["scope"] = scope }
        return try await run(tab, "text", args)
    }

    private static func audit(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        var args: [String: Any] = [:]
        if let scope = try p.string("scope") { args["scope"] = scope }
        return try await run(tab, "audit", args)
    }

    // MARK: Acting

    private static func click(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        try AgentMethods.checkControl(tab)
        let ref = try p.requiredString("ref")
        let webView = try await ready(tab)
        let loadsBefore = tab.loadsEnded
        let rect = try await run(tab, "rect", ["ref": ref]) as? [String: Any] ?? [:]
        var native = false

        if try p.bool("native") ?? true, canSendEvents(to: tab),
           let x = rect["x"] as? Double, let y = rect["y"] as? Double {
            _ = try await run(tab, "armClick", ["ref": ref])
            sendClick(to: webView, at: windowPoint(webView, x: x, y: y), modifiers: try modifiers(p.string("modifiers")))
            native = try await clickLanded(tab, loadsBefore: loadsBefore)
        }
        if !native { _ = try await run(tab, "click", ["ref": ref]) }

        try await AgentMethods.settle(tab, loadsBefore: loadsBefore, p)
        var result = AgentMethods.describe(tab)
        result["native"] = native
        if rect["covered"] as? Bool == true { result["warning"] = "Another element covered the center of \(ref)" }
        return result
    }

    private static func typeText(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        try AgentMethods.checkControl(tab)
        let ref = try p.requiredString("ref")
        let text = try p.requiredString("text")
        let clear = try p.bool("clear") ?? true
        let webView = try await ready(tab)
        var native = false

        if try p.bool("native") ?? true, canSendEvents(to: tab) {
            webView.window?.makeFirstResponder(webView)
            _ = try await run(tab, "focus", ["ref": ref, "clear": clear])
            webView.insertText(text)
            try await Task.sleep(for: .milliseconds(50))
            let value = try await run(tab, "valueOf", ["ref": ref]) as? String ?? ""
            native = clear ? value == text : value.hasSuffix(text)
            // insertText didn't land (an unusual editor, or focus moved): fill the field through the DOM.
            if !native { _ = try await run(tab, "fill", ["ref": ref, "text": text, "clear": clear]) }
        } else {
            _ = try await run(tab, "fill", ["ref": ref, "text": text, "clear": clear])
        }

        if try p.bool("submit") ?? false {
            let loadsBefore = tab.loadsEnded
            try await sendKey("enter", to: tab, native: native)
            try await AgentMethods.settle(tab, loadsBefore: loadsBefore, p)
        }
        var result = AgentMethods.describe(tab)
        result["native"] = native
        return result
    }

    private static func press(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        try AgentMethods.checkControl(tab)
        let key = try p.requiredString("key")
        _ = try await ready(tab)
        let loadsBefore = tab.loadsEnded
        let native = try p.bool("native") ?? true && canSendEvents(to: tab)
        try await sendKey(key, to: tab, native: native)
        try await AgentMethods.settle(tab, loadsBefore: loadsBefore, p)
        var result = AgentMethods.describe(tab)
        result["native"] = native
        return result
    }

    private static func scroll(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        var args: [String: Any] = ["dx": try p.number("dx") ?? 0, "dy": try p.number("dy") ?? 0]
        if let ref = try p.string("ref") { args["ref"] = ref }
        return try await run(tab, "scroll", args)
    }

    private static func select(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        try AgentMethods.checkControl(tab)
        let ref = try p.requiredString("ref")
        let values: [String]
        switch p.raw["values"] {
        // The CLI turns `2` into a number; NSNumber's stringValue gives "2", not "2.0".
        case let list as [Any]: values = list.map { ($0 as? NSNumber)?.stringValue ?? "\($0)" }
        case let one as String: values = [one]
        case let one as NSNumber: values = [one.stringValue]
        default: throw AgentError.invalidParams("values must be a string or a list of strings")
        }
        return ["selected": try await run(tab, "select", ["ref": ref, "values": values])]
    }

    /// Runs `js` in the page's own world. It's an expression, or a function body that uses `return`;
    /// `await` works, and `args` holds the `args` param.
    private static func eval(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        try AgentMethods.checkControl(tab)
        let js = try p.requiredString("js")
        let webView = try await ready(tab)
        let args: [String: Any] = ["args": p.raw["args"] ?? NSNull()]
        // Compile the expression form without running it (the code after `return` is parsed, never
        // executed). Statements like `const …; return x` or `throw …` fail to parse and run as a body.
        var expression = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if expression.hasSuffix(";") { expression.removeLast() } // `document.title;` is still an expression
        let probe = "return true;\n(async () => { return (\n\(expression)\n); });"
        let isExpression: Bool
        do { _ = try await callJS(webView, probe, [:], in: .page); isExpression = true } catch { isExpression = false }
        return try await callJS(webView, evalWrapper(isExpression ? "return (\n\(expression)\n);" : js), args, in: .page)
    }

    private static func evalWrapper(_ body: String) -> String {
        """
        const __ternResult = await (async () => {
        \(body)
        })();
        return __ternResult === undefined ? null : __ternResult;
        """
    }

    private static func waitFor(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        let text = try p.string("text"), selector = try p.string("selector"), urlPattern = try p.string("urlMatches")
        guard text != nil || selector != nil || urlPattern != nil else {
            throw AgentError.invalidParams("Pass text, selector or urlMatches")
        }
        let regex = try urlPattern.map { (pattern: String) throws -> NSRegularExpression in
            do { return try NSRegularExpression(pattern: pattern) } catch { throw AgentError.invalidParams("urlMatches is not a valid regex") }
        }
        let deadline = Date().addingTimeInterval((try p.number("timeoutMs") ?? 30_000) / 1000)
        var args: [String: Any] = [:]
        if let text { args["text"] = text }
        if let selector { args["selector"] = selector }

        while true {
            var ok = true
            if let regex {
                let url = tab.currentURL?.absoluteString ?? ""
                ok = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            }
            if ok, !args.isEmpty {
                // Mid-navigation the page world is being replaced; treat that as "not yet".
                ok = (try? await run(tab, "check", args, waitForLoad: false)) as? Bool ?? false
            }
            if ok { return AgentMethods.describe(tab) }
            guard Date() < deadline else { throw AgentError.timeout(waitDescription(text, selector, urlPattern)) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func screenshot(_ p: AgentParams) async throws -> Any {
        let tab = try AgentMethods.findTab(p)
        let webView = try await ready(tab)
        guard webView.window != nil else {
            throw AgentError(code: -32007, message: "The tab isn't on screen. Show it first with tabs.activate.")
        }
        let config = WKSnapshotConfiguration()
        if let ref = try p.string("ref") {
            let r = try await run(tab, "rect", ["ref": ref]) as? [String: Any] ?? [:]
            let scale = webView.pageZoom * webView.magnification
            let left = (r["left"] as? Double ?? 0) * scale, top = (r["top"] as? Double ?? 0) * scale
            let width = (r["width"] as? Double ?? 0) * scale, height = (r["height"] as? Double ?? 0) * scale
            config.rect = NSRect(x: left, y: webView.isFlipped ? top : webView.bounds.height - top - height, width: width, height: height)
        }
        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw AgentError(code: -32603, message: "Couldn't encode the screenshot")
        }
        var result: [String: Any] = ["width": rep.pixelsWide, "height": rep.pixelsHigh, "mimeType": "image/png"]
        if let path = try p.string("path") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { try png.write(to: url) } catch { throw AgentError(code: -32603, message: "Couldn't write \(url.path): \(error.localizedDescription)") }
            result["path"] = url.path
        } else {
            result["data"] = png.base64EncodedString()
        }
        return result
    }

    // MARK: Plumbing

    /// Materializes a suspended tab (and lets it load) so its page can be scripted.
    private static func ready(_ tab: Tab) async throws -> WKWebView {
        let wasSuspended = tab.isSuspended
        let webView = tab.materialize()
        // A background tab has never been laid out; give it a window-sized frame so the page lays out.
        if webView.frame.isEmpty {
            webView.frame = tab.owner?.content.view.bounds.nonEmpty ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        if wasSuspended || tab.isLoading { try await AgentMethods.settle(tab, loadsBefore: -1, AgentParams([:])) }
        return webView
    }

    private static func run(_ tab: Tab, _ method: String, _ args: [String: Any], waitForLoad: Bool = true) async throws -> Any {
        let webView = waitForLoad ? try await ready(tab) : tab.materialize()
        return try await callJS(webView, AgentScript.call, ["method": method, "args": args], in: world)
    }

    private static func callJS(_ webView: WKWebView, _ body: String, _ arguments: [String: Any], in world: WKContentWorld) async throws -> Any {
        do {
            let result: Any = try await withCheckedThrowingContinuation { done in
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                    switch result {
                    case .success(let value): done.resume(returning: value)
                    case .failure(let error): done.resume(throwing: error)
                    }
                }
            }
            return jsonSafe(result)
        } catch {
            throw translate(error)
        }
    }

    /// WebKit errors carry the JS exception text; stale refs get their own code.
    static func translate(_ error: Error) -> Error {
        if error is AgentError { return error }
        let info = (error as NSError).userInfo
        let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        if message.contains("stale ref") { return AgentError(code: -32002, message: message) }
        return AgentError(code: -32004, message: message)
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case is String, is NSNumber, is NSNull: return value
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        default: return String(describing: value)
        }
    }

    private static func waitDescription(_ text: String?, _ selector: String?, _ url: String?) -> String {
        [text.map { "text \"\($0)\"" }, selector.map { "selector \($0)" }, url.map { "a URL matching \($0)" }]
            .compactMap { $0 }.joined(separator: " and ")
    }

    // MARK: Native input

    /// Events only reach a web view that's in a visible window and on screen.
    private static func canSendEvents(to tab: Tab) -> Bool {
        guard let webView = tab.webView, let window = webView.window else { return false }
        return window.isVisible && tab.isVisible && !webView.isHiddenOrHasHiddenAncestor
    }

    /// CSS pixels in the viewport → the web view's window coordinates.
    private static func windowPoint(_ webView: WKWebView, x: Double, y: Double) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        let local = NSPoint(x: x * scale, y: webView.isFlipped ? y * scale : webView.bounds.height - y * scale)
        return webView.convert(local, to: nil)
    }

    private static func sendClick(to webView: WKWebView, at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let window = webView.window else { return }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let e = event(.mouseMoved) { webView.mouseMoved(with: e) }
        if let e = event(.leftMouseDown) { webView.mouseDown(with: e) }
        if let e = event(.leftMouseUp) { webView.mouseUp(with: e) }
    }

    /// True once the element saw the click, or the page started navigating because of it.
    private static func clickLanded(_ tab: Tab, loadsBefore: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if tab.isLoading || tab.loadsEnded != loadsBefore { return true }
            if (try? await run(tab, "wasClicked", [:], waitForLoad: false)) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    private static func sendKey(_ chord: String, to tab: Tab, native: Bool) async throws {
        guard native, let webView = tab.webView, let window = webView.window else {
            _ = try await run(tab, "pressFallback", ["key": chord.lowercased()])
            return
        }
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last, let key = KeyCodes.lookup(name) else {
            throw AgentError.invalidParams("Unknown key \(chord)")
        }
        let flags = try modifiers(parts.dropLast().joined(separator: "+"))
        let characters = flags.contains(.shift) ? key.characters.uppercased() : key.characters
        window.makeFirstResponder(webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: key.characters,
                                               isARepeat: false, keyCode: key.code) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private static func modifiers(_ spec: String?) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in (spec ?? "").lowercased().split(whereSeparator: { $0 == "+" || $0 == "," }) {
            switch part {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: throw AgentError.invalidParams("Unknown modifier \(part)")
            }
        }
        return flags
    }
}

private extension NSRect {
    var nonEmpty: NSRect? { isEmpty ? nil : self }
}

/// macOS virtual key codes (ANSI layout) and the characters each key types.
private enum KeyCodes {
    struct Key { let code: UInt16; let characters: String }

    private static func function(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    private static let named: [String: Key] = [
        "enter": Key(code: 36, characters: "\r"), "return": Key(code: 36, characters: "\r"),
        "tab": Key(code: 48, characters: "\t"), "space": Key(code: 49, characters: " "),
        "escape": Key(code: 53, characters: "\u{1b}"), "esc": Key(code: 53, characters: "\u{1b}"),
        "backspace": Key(code: 51, characters: "\u{7f}"),
        "delete": Key(code: 117, characters: function(NSDeleteFunctionKey)),
        "left": Key(code: 123, characters: function(NSLeftArrowFunctionKey)),
        "right": Key(code: 124, characters: function(NSRightArrowFunctionKey)),
        "down": Key(code: 125, characters: function(NSDownArrowFunctionKey)),
        "up": Key(code: 126, characters: function(NSUpArrowFunctionKey)),
        "home": Key(code: 115, characters: function(NSHomeFunctionKey)),
        "end": Key(code: 119, characters: function(NSEndFunctionKey)),
        "pageup": Key(code: 116, characters: function(NSPageUpFunctionKey)),
        "pagedown": Key(code: 121, characters: function(NSPageDownFunctionKey)),
    ]

    private static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    static func lookup(_ name: String) -> Key? {
        if let key = named[name] { return key }
        guard name.count == 1, let c = name.first, let code = ansi[c] else { return nil }
        return Key(code: code, characters: name)
    }
}
