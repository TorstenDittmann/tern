import Foundation

/// `console.*`, `network.*` and `events.*`: what a page logged and fetched, and live notifications.
@MainActor
enum AgentLogMethods {
    static let table: [String: AgentMethods.Handler] = [
        "console.read": { try read(.console, $0) },
        "network.list": { try read(.network, $0) },
        "events.subscribe": subscribe,
        "events.unsubscribe": unsubscribe,
    ]

    static let events = ["tab.updated", "console.message", "network.request"]

    /// Entries after `since` (a seq from an earlier read), newest last, at most `limit`.
    private static func read(_ kind: AgentTabLog.Kind, _ p: AgentParams) throws -> Any {
        let tab = try AgentMethods.findTab(p)
        let since = try p.number("since").map { Int($0) } ?? 0
        let limit = try max(1, p.number("limit").map { Int($0) } ?? 100)
        let level = try p.string("level")
        let failedOnly = try p.bool("failedOnly") ?? false
        let regex = try p.string("urlMatches").map { pattern -> NSRegularExpression in
            do { return try NSRegularExpression(pattern: pattern) } catch { throw AgentError.invalidParams("urlMatches is not a valid regex") }
        }

        let log = tab.agentLog
        let matching = log.entries(kind).filter { entry in
            guard (entry["seq"] as? Int ?? 0) > since else { return false }
            if let level, entry["level"] as? String != level { return false }
            if failedOnly, entry["ok"] as? Bool != false { return false }
            if let regex {
                let url = entry["url"] as? String ?? ""
                if regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) == nil { return false }
            }
            return true
        }
        let entries = Array(matching.suffix(limit))
        if try p.bool("clear") == true { log.clear(kind) }
        let result: [String: Any] = [
            "tabId": tab.id.uuidString,
            "entries": entries,
            "last": entries.last?["seq"] ?? since,
            "monitoring": AgentServer.shared.isRunning,
        ]
        return result
    }

    private static func requestedEvents(_ p: AgentParams) throws -> [String] {
        let names: [String]
        switch p.raw["events"] {
        case nil, is NSNull: names = ["*"]
        case let one as String: names = one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case let many as [String]: names = many
        default: throw AgentError.invalidParams("events must be a list of event names")
        }
        if let unknown = names.first(where: { $0 != "*" && !events.contains($0) }) {
            throw AgentError.invalidParams("Unknown event \(unknown). Events: \(events.joined(separator: ", "))")
        }
        return names
    }

    /// Notifications arrive on this connection as JSON-RPC requests without an id.
    private static func subscribe(_ p: AgentParams) async throws -> Any {
        guard let connection = AgentContext.connection else { throw AgentError(code: -32000, message: "No connection") }
        let names = try requestedEvents(p)
        let wasSubscribed = !connection.subscriptions.isEmpty
        connection.subscriptions.formUnion(names)
        if !wasSubscribed { AgentActivity.shared.subscribersChanged() }
        return ["subscribed": connection.subscriptions.sorted(), "events": events]
    }

    private static func unsubscribe(_ p: AgentParams) async throws -> Any {
        guard let connection = AgentContext.connection else { throw AgentError(code: -32000, message: "No connection") }
        if p.raw["events"] == nil { connection.subscriptions.removeAll() }
        else { connection.subscriptions.subtract(try requestedEvents(p)) }
        AgentActivity.shared.subscribersChanged()
        return ["subscribed": connection.subscriptions.sorted()]
    }
}
