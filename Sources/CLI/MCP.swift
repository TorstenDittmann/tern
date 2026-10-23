import Foundation
import Darwin

// `tern mcp`: a Model Context Protocol server on stdin/stdout. Each tool call becomes one agent
// API request over Tern's socket, so it works the same as the CLI and needs no extra setup:
//
//     claude mcp add tern -- tern mcp

struct MCPTool {
    let name: String
    let method: String
    let description: String
    let properties: [String: [String: Any]]
    var required: [String] = []
    /// Tools that never change anything. The log tools aren't: their `clear` drops entries.
    var readOnly = false

    var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly],
        ]
    }
}

private func string(_ description: String, enum values: [String]? = nil) -> [String: Any] {
    var schema: [String: Any] = ["type": "string", "description": description]
    if let values { schema["enum"] = values }
    return schema
}
private func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
private func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
private func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

private let tabId = string("Tab id from tabs_list. Defaults to the active tab of the frontmost window.")
private let ref = string("Element ref from page_snapshot, like e12.")
private let waitMode = string("What to wait for if this navigates: load (default), idle (load plus 500 ms of quiet) or none.",
                          enum: ["load", "idle", "none"])
private let timeoutMs = number("How long to wait, in milliseconds (default 30000).")
private let scope = string("CSS selector to limit the result to one part of the page.")
private let since = integer("Only entries after this seq: pass `last` from the previous read to get what's new.")
private let limit = integer("At most this many entries (default 100).")
private let clear = boolean("Drop the returned entries from Tern's buffer afterwards.")

let mcpTools: [MCPTool] = [
    MCPTool(name: "tabs_list", method: "tabs.list",
            description: "List open tabs with id, title, URL, and whether each is active, loading or opened by an agent.",
            properties: ["windowId": string("Only tabs of this window.")], readOnly: true),
    MCPTool(name: "tabs_open", method: "tabs.open",
            description: "Open a URL in a new tab and wait for it to load. Accepts anything the address bar does, like localhost:3000.",
            properties: ["url": string("URL, host or localhost:port."), "background": boolean("Open without switching to it."),
                         "windowId": string("Window to open it in."), "wait": waitMode, "timeoutMs": timeoutMs],
            required: ["url"]),
    MCPTool(name: "tabs_navigate", method: "tabs.navigate",
            description: "Load a URL in a tab and wait for it.",
            properties: ["url": string("URL, host or localhost:port."), "tabId": tabId, "wait": waitMode, "timeoutMs": timeoutMs],
            required: ["url"]),
    MCPTool(name: "tabs_activate", method: "tabs.activate", description: "Show a tab and bring its window to the front.",
            properties: ["tabId": tabId], required: ["tabId"]),
    MCPTool(name: "tabs_close", method: "tabs.close", description: "Close a tab.",
            properties: ["tabId": tabId], required: ["tabId"]),
    MCPTool(name: "tabs_back", method: "tabs.back", description: "Go back in a tab's history and wait for the page.",
            properties: ["tabId": tabId, "wait": waitMode, "timeoutMs": timeoutMs]),
    MCPTool(name: "tabs_forward", method: "tabs.forward", description: "Go forward in a tab's history and wait for the page.",
            properties: ["tabId": tabId, "wait": waitMode, "timeoutMs": timeoutMs]),
    MCPTool(name: "tabs_reload", method: "tabs.reload", description: "Reload a tab and wait for it.",
            properties: ["tabId": tabId, "wait": waitMode, "timeoutMs": timeoutMs]),
    MCPTool(name: "tabs_split", method: "tabs.split", description: "Show two tabs of the same window side by side.",
            properties: ["leftTabId": string("Tab for the left pane."), "rightTabId": string("Tab for the right pane.")],
            required: ["leftTabId", "rightTabId"]),
    MCPTool(name: "page_snapshot", method: "page.snapshot",
            description: "The page as an indented outline of headings, text, links and form controls. Interactive elements get refs like e12 for page_click, page_type and friends. Refs stay valid until the page navigates.",
            properties: ["tabId": tabId, "scope": scope, "maxLines": integer("Cut the outline after this many lines.")],
            readOnly: true),
    MCPTool(name: "page_text", method: "page.text", description: "The page's text, as plain text, markdown or HTML.",
            properties: ["tabId": tabId, "format": string("text (default), markdown or html.", enum: ["text", "markdown", "html"]),
                         "scope": scope],
            readOnly: true),
    MCPTool(name: "page_click", method: "page.click",
            description: "Click an element by ref with a real mouse event, and wait if it navigates.",
            properties: ["ref": ref, "tabId": tabId, "modifiers": string("Held keys, like cmd or shift+alt."),
                         "wait": waitMode, "timeoutMs": timeoutMs],
            required: ["ref"]),
    MCPTool(name: "page_type", method: "page.type", description: "Type text into a field by ref, replacing what's there unless clear is false.",
            properties: ["ref": ref, "text": string("Text to type."), "tabId": tabId,
                         "clear": boolean("Replace the field's value (default true)."),
                         "submit": boolean("Press Enter afterwards."), "wait": waitMode],
            required: ["ref", "text"]),
    MCPTool(name: "page_press", method: "page.press", description: "Press a key or chord, like enter, escape, tab, cmd+a or shift+arrowdown.",
            properties: ["key": string("Key or chord."), "tabId": tabId, "wait": waitMode], required: ["key"]),
    MCPTool(name: "page_select", method: "page.select", description: "Choose options of a select element by value or label.",
            properties: ["ref": ref, "values": ["type": "array", "items": ["type": "string"], "description": "Values or labels to select."],
                         "tabId": tabId],
            required: ["ref", "values"]),
    MCPTool(name: "page_scroll", method: "page.scroll", description: "Scroll an element into view by ref, or scroll the page by dx/dy pixels.",
            properties: ["ref": ref, "dx": number("Horizontal pixels."), "dy": number("Vertical pixels."), "tabId": tabId]),
    MCPTool(name: "page_eval", method: "page.eval",
            description: "Run JavaScript in the page and return the result as JSON. Takes an expression (document.title) or a function body with return. Promises are awaited.",
            properties: ["js": string("Expression or function body."), "args": ["description": "Value available to the code as `args`."],
                         "tabId": tabId],
            required: ["js"]),
    MCPTool(name: "page_wait_for", method: "page.waitFor", description: "Wait until text appears, a selector matches, or the URL matches a regex.",
            properties: ["text": string("Text to wait for."), "selector": string("CSS selector to wait for."),
                         "urlMatches": string("Regex the URL must match."), "tabId": tabId, "timeoutMs": timeoutMs],
            readOnly: true),
    MCPTool(name: "page_screenshot", method: "page.screenshot",
            description: "Screenshot the visible part of a tab, or one element by ref. Returns the image, or writes a PNG when path is set.",
            properties: ["tabId": tabId, "ref": ref, "path": string("Absolute path to write the PNG to instead.")]),
    MCPTool(name: "page_audit", method: "page.audit",
            description: "Quick accessibility audit: images without alt text, unlabeled controls and buttons, empty links, missing lang and title, skipped heading levels.",
            properties: ["tabId": tabId, "scope": scope], readOnly: true),
    MCPTool(name: "console_read", method: "console.read",
            description: "What the page logged with console.*, plus uncaught errors and unhandled rejections. Recorded while the agent API is on.",
            properties: ["tabId": tabId, "level": string("Only this level.", enum: ["log", "info", "warn", "error", "debug"]),
                         "since": since, "limit": limit, "clear": clear]),
    MCPTool(name: "network_list", method: "network.list",
            description: "fetch and XMLHttpRequest calls the page made, with method, URL, status and duration.",
            properties: ["tabId": tabId, "failedOnly": boolean("Only failed requests and 4xx/5xx responses."),
                         "urlMatches": string("Regex the URL must match."), "since": since, "limit": limit, "clear": clear]),
    MCPTool(name: "history_search", method: "history.search",
            description: "Pages from Tern's history, best match first, or most frequently and recently visited without a query.",
            properties: ["query": string("Words from the title or address."), "limit": integer("At most this many pages (default 20).")],
            readOnly: true),
    MCPTool(name: "commands_list", method: "commands.list", description: "Tern's commands (the ones in the ⌘K palette) with their shortcuts.",
            properties: [:], readOnly: true),
    MCPTool(name: "commands_run", method: "commands.run", description: "Run a Tern command by name, like toggleSplit or newTab.",
            properties: ["command": string("Command name from commands_list.")], required: ["command"]),
]

final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools = Dictionary(uniqueKeysWithValues: mcpTools.map { ($0.name, $0) })

    func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            // Notifications (no id), like notifications/initialized, need no answer.
            guard let id = message["id"], !(id is NSNull) else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            do {
                send(["jsonrpc": "2.0", "id": id, "result": try handle(method, params)])
            } catch let error as MCPError {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
            }
        }
        exit(0)
    }

    private func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "tern", "version": "1.0"],
                "instructions": """
                Drives the Tern browser. Start with tabs_open (or tabs_list), then page_snapshot to read the page \
                and get element refs, and act with page_click, page_type and page_press. Use console_read and \
                network_list to debug what the page did. Tern must be running with "Enable Agent API" turned on.
                """,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": mcpTools.map(\.definition)]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools[name] else {
                throw MCPError(code: -32602, message: "Unknown tool \(params["name"] ?? "")")
            }
            return call(tool, params["arguments"] as? [String: Any] ?? [:])
        default:
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Tool failures are results with isError, so the model sees them and can recover.
    private func call(_ tool: MCPTool, _ arguments: [String: Any]) -> [String: Any] {
        let reply: [String: Any]
        do { reply = try request(tool.method, arguments) } catch {
            return ["content": [text("\(error)")], "isError": true]
        }
        if let error = reply["error"] as? [String: Any] {
            return ["content": [text("error \(error["code"] ?? ""): \(error["message"] ?? "unknown")")], "isError": true]
        }
        let result = reply["result"] ?? NSNull()
        if let object = result as? [String: Any] {
            if let snapshot = (object["snapshot"] ?? object["text"]) as? String { return ["content": [text(snapshot)]] }
            if let data = object["data"] as? String, let mime = object["mimeType"] as? String {
                var rest = object
                rest["data"] = nil
                let image: [String: Any] = ["type": "image", "data": data, "mimeType": mime]
                return ["content": [image, text(json(rest))]]
            }
        }
        return ["content": [text(json(result))]]
    }

    /// One request per connection, so a restarted Tern is picked up on the next call.
    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let path = socketPath()
        guard let fd = connectSocket(path) else {
            throw MCPError(code: -32000, message: "Can't reach Tern at \(path). Is Tern running, with \"Enable Agent API\" turned on in the command palette (⌘K)?")
        }
        defer { close(fd) }
        var line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        line.append(0x0A)
        guard writeAll(fd, line) else { throw MCPError(code: -32000, message: "Lost the connection to Tern while sending") }
        let reader = LineReader(fd: fd)
        while let message = reader.next() {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                throw MCPError(code: -32000, message: "Tern sent a reply that isn't JSON")
            }
            if object["id"] != nil { return object }
        }
        throw MCPError(code: -32000, message: "Tern closed the connection without replying")
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct MCPError: Error, CustomStringConvertible {
    let code: Int
    let message: String
    var description: String { message }
}
