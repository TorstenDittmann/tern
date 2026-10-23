import Foundation
import Darwin

// `tern`: command-line client for Tern's agent API. Each call is one JSON-RPC request over the
// app's Unix socket; the result is printed as JSON (or as plain lines with --plain).

let usage = """
usage: tern <namespace> <verb> [value] [--param value ...] [--plain]
       tern run <command>              shorthand for commands run
       tern call <method> [json]       send any method with raw JSON params
       tern hello                      check the connection
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

Turn the API on with "Enable Agent API" in Tern's command palette (⌘K).
"""

/// Positional values fill these params, in order, for methods that have obvious ones.
let positionalParams: [String: [String]] = [
    "tabs.open": ["url"], "tabs.navigate": ["url"], "windows.open": ["url"],
    "tabs.activate": ["tabId"], "tabs.close": ["tabId"],
    "tabs.back": ["tabId"], "tabs.forward": ["tabId"], "tabs.reload": ["tabId"],
    "commands.run": ["command"],
    "page.click": ["ref"], "page.type": ["ref", "text"], "page.press": ["key"],
    "page.select": ["ref", "values"], "page.scroll": ["ref"], "page.eval": ["js"],
    "page.waitFor": ["text"], "page.text": ["format"], "page.screenshot": ["path"],
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

var args = Array(CommandLine.arguments.dropFirst())
var plain = false, json = false
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

// MARK: Socket

func socketPath() -> String {
    if let path = ProcessInfo.processInfo.environment["TERN_SOCKET"] { return path }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Tern/agent.sock").path
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
}

let path = socketPath()
guard let fd = connectSocket(path) else {
    fail("Can't reach Tern at \(path).\nIs Tern running, with \"Enable Agent API\" turned on in the command palette (⌘K)?", code: 2)
}

let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
var line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
line.append(0x0A)
line.withUnsafeBytes { raw in
    var offset = 0
    while offset < raw.count {
        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n <= 0 { fail("Lost the connection to Tern while sending") }
        offset += n
    }
}

var response = Data()
var chunk = [UInt8](repeating: 0, count: 64 * 1024)
while !response.contains(0x0A) {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { fail("Tern closed the connection without replying") }
    response.append(contentsOf: chunk[0..<n])
}
close(fd)

// MARK: Output

guard let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
    fail("Tern sent a reply that isn't JSON")
}
if let error = reply["error"] as? [String: Any] {
    fail("error \(error["code"] ?? ""): \(error["message"] ?? "unknown")")
}
let result = reply["result"] ?? NSNull()

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
