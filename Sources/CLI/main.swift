import Foundation
import Darwin

// `tern`: command-line client for Tern's agent API. Each call is one JSON-RPC request over the
// app's Unix socket; the result is printed as JSON (or as plain lines with --plain).

let usage = """
usage: tern <namespace> <verb> [value] [--param value ...] [--plain]
       tern run <command>              shorthand for commands run
       tern call <method> [json]       send any method with raw JSON params
       tern hello                      check the connection
       tern mcp                        run as an MCP server on stdin/stdout
       --json prints the raw JSON result, --plain prints lists as lines

examples:
  tern tabs open localhost:3000 --wait idle
  tern tabs list --plain
  tern tabs navigate https://example.com --tabId <id>
  tern run toggleSplit
  tern commands list --plain
  tern page snapshot                     the page as text, with refs like e12
  tern page click e12
  tern page type e3 "ada@example.com" --submit true
  tern page screenshot shot.png
  tern console read --level error        what the page logged (also uncaught errors)
  tern network list --failedOnly true    fetch/XHR requests the page made
  tern events subscribe console.message  stream events as JSON lines (--count n, --timeoutMs ms)

Turn the API on with "Enable Agent API" in Tern's command palette (⌘K).
"""

/// Positional values fill these params, in order, for methods that have obvious ones.
let positionalParams: [String: [String]] = [
    "tabs.open": ["url"], "tabs.navigate": ["url"], "windows.open": ["url"],
    "tabs.activate": ["tabId"], "tabs.close": ["tabId"], "tabs.pin": ["tabId"],
    "tabs.back": ["tabId"], "tabs.forward": ["tabId"], "tabs.reload": ["tabId"],
    "commands.run": ["command"],
    "page.click": ["ref"], "page.type": ["ref", "text"], "page.press": ["key"],
    "page.select": ["ref", "values"], "page.scroll": ["ref"], "page.eval": ["js"],
    "page.waitFor": ["text"], "page.text": ["format"], "page.screenshot": ["path"],
    "network.list": ["urlMatches"], "events.subscribe": ["events"], "events.unsubscribe": ["events"],
    "history.search": ["query"],
]

/// Results whose main content is text print it as-is (a snapshot reads better than escaped JSON).
let textResultKeys = ["snapshot", "text"]

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// "true", "false", "null" and numbers become JSON values; everything else stays a string.
func value(_ raw: String) -> Any {
    switch raw {
    case "true": return true
    case "false": return false
    case "null": return NSNull()
    case _ where raw.hasPrefix("[") || raw.hasPrefix("{"):
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? raw
    default:
        if let n = Double(raw), raw.first.map({ $0.isNumber || $0 == "-" }) == true { return n }
        return raw
    }
}

// MARK: Arguments

if CommandLine.arguments.dropFirst().first == "mcp" { MCPServer().run() }

var args = Array(CommandLine.arguments.dropFirst())
var plain = false, json = false
var eventCount: Int?
if let i = args.firstIndex(of: "--count"), i + 1 < args.count {
    eventCount = Int(args[i + 1])
    args.removeSubrange(i...(i + 1))
}
args.removeAll { arg in
    switch arg {
    case "--plain": plain = true; return true
    case "--json": json = true; return true
    default: return false
    }
}
guard let first = args.first, !["-h", "--help", "help"].contains(first) else { print(usage); exit(0) }

var method: String
var params: [String: Any] = [:]
var rest: [String]

switch first {
case "hello":
    method = "tern.hello"; rest = Array(args.dropFirst())
case "run":
    guard args.count >= 2 else { fail(usage, code: 64) }
    method = "commands.run"; params["command"] = args[1]; rest = Array(args.dropFirst(2))
case "call":
    guard args.count >= 2 else { fail(usage, code: 64) }
    method = args[1]
    if args.count >= 3 {
        guard let json = try? JSONSerialization.jsonObject(with: Data(args[2].utf8)) as? [String: Any] else {
            fail("params must be a JSON object", code: 64)
        }
        params = json
    }
    rest = Array(args.dropFirst(3))
default:
    guard args.count >= 2 else { fail(usage, code: 64) }
    method = "\(args[0]).\(args[1])"; rest = Array(args.dropFirst(2))
}

var i = 0
while i < rest.count {
    let arg = rest[i]
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        guard i + 1 < rest.count else { fail("missing value for \(arg)", code: 64) }
        params[key] = value(rest[i + 1])
        i += 2
    } else if let key = positionalParams[method]?.first(where: { params[$0] == nil }) {
        params[key] = key == "values" ? value(arg) : arg
        i += 1
    } else {
        fail("unexpected argument \(arg)\n\n\(usage)", code: 64)
    }
}

// The app resolves paths from its own working directory, so send absolute ones.
if let path = params["path"] as? String, !path.hasPrefix("/"), !path.hasPrefix("~") {
    params["path"] = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
}

// MARK: Request

let path = socketPath()
guard let fd = connectSocket(path) else {
    fail("Can't reach Tern at \(path).\nIs Tern running, with \"Enable Agent API\" turned on in the command palette (⌘K)?", code: 2)
}

// A subscription with timeoutMs stops listening once that long passes without an event.
if method == "events.subscribe", let ms = params["timeoutMs"] as? Double {
    var limit = timeval(tv_sec: Int(ms / 1000), tv_usec: Int32(ms.truncatingRemainder(dividingBy: 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
}

let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
var line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
line.append(0x0A)
guard writeAll(fd, line) else { fail("Lost the connection to Tern while sending") }
let reader = LineReader(fd: fd)

// Events can arrive just before the reply to `events.subscribe`; keep them for the stream below.
var early: [Data] = []
var reply: [String: Any] = [:]
while true {
    guard let message = reader.next() else { fail("Tern closed the connection without replying") }
    guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
        fail("Tern sent a reply that isn't JSON")
    }
    if object["id"] == nil { early.append(message); continue }
    reply = object
    break
}

// MARK: Output

if let error = reply["error"] as? [String: Any] {
    fail("error \(error["code"] ?? ""): \(error["message"] ?? "unknown")")
}
let result = reply["result"] ?? NSNull()

// `events subscribe` keeps the connection open and prints each notification as one JSON line.
if method == "events.subscribe" {
    FileHandle.standardError.write(Data("Listening for \((result as? [String: Any])?["subscribed"] ?? "events")…\n".utf8))
    var received = 0
    while eventCount.map({ received < $0 }) ?? true, let line = early.isEmpty ? reader.next() : early.removeFirst() {
        print(String(decoding: line, as: UTF8.self))
        fflush(stdout)
        received += 1
    }
    close(fd)
    exit(0)
}
close(fd)

func text(_ v: Any) -> String {
    switch v {
    case let s as String: return s
    case is NSNull: return ""
    case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
    default:
        let data = (try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

if !json, let object = result as? [String: Any],
   let key = textResultKeys.first(where: { object[$0] is String }) {
    print(object[key] as! String)
} else if !json, method == "console.read" || method == "network.list",
          let entries = (result as? [String: Any])?["entries"] as? [[String: Any]] {
    // One line per entry, like a log.
    for e in entries {
        if method == "console.read" {
            print("[\(e["level"].map(text) ?? "log")] \(e["text"].map(text) ?? "")")
        } else {
            let failure = (e["error"] as? String).map { "  (\($0))" } ?? ""
            print("\(e["status"].map(text) ?? "-") \(e["method"].map(text) ?? "") \(e["url"].map(text) ?? "")  \(e["durationMs"].map(text) ?? "?")ms\(failure)")
        }
    }
} else if plain {
    // One line per item: the fields people scan for, tab-separated.
    let columns = ["id", "name", "title", "binding", "url"]
    switch result {
    case let items as [[String: Any]]:
        for item in items { print(columns.compactMap { item[$0].map(text) }.joined(separator: "\t")) }
    case let items as [Any]:
        items.forEach { print(text($0)) }
    case let object as [String: Any]:
        for key in object.keys.sorted() { print("\(key)\t\(text(object[key]!))") }
    default:
        print(text(result))
    }
} else if JSONSerialization.isValidJSONObject(result),
          let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
    print(String(decoding: data, as: UTF8.self))
} else {
    print(text(result))
}
