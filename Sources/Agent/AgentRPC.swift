import Foundation

/// A JSON-RPC error with one of the codes from the agent API design.
struct AgentError: Error {
    let code: Int
    let message: String

    static func invalidParams(_ message: String) -> AgentError { AgentError(code: -32602, message: message) }
    static func methodNotFound(_ method: String) -> AgentError { AgentError(code: -32601, message: "Unknown method \(method)") }
    static func tabNotFound(_ id: String) -> AgentError { AgentError(code: -32001, message: "No tab with id \(id)") }
    static func timeout(_ what: String) -> AgentError { AgentError(code: -32003, message: "Timed out waiting for \(what)") }
    static let notAllowed = AgentError(code: -32005, message: "Agents may only control tabs they opened (agentOwnTabsOnly is on)")
}

/// Decodes one request line, runs it, and encodes the reply. Notifications (no `id`) get no reply.
@MainActor
enum AgentRPC {
    static func handle(_ line: Data) async -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return encode(id: NSNull(), error: AgentError(code: -32700, message: "Parse error"))
        }
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return encode(id: id ?? NSNull(), error: AgentError(code: -32600, message: "Invalid request"))
        }
        let params: [String: Any]
        switch request["params"] {
        case nil, is NSNull: params = [:]
        case let p as [String: Any]: params = p
        default: return encode(id: id ?? NSNull(), error: .invalidParams("params must be an object"))
        }

        do {
            let result = try await AgentMethods.call(method, AgentParams(params))
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            guard let id else { return nil }
            let e = error as? AgentError ?? AgentError(code: -32603, message: String(describing: error))
            return encode(id: id, error: e)
        }
    }

    private static func encode(id: Any, error: AgentError) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return encode(id: object["id"] ?? NSNull(), error: AgentError(code: -32603, message: "Result is not valid JSON"))
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}

/// Typed access to a request's params, with readable errors for missing or mistyped ones.
struct AgentParams {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) throws -> String? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        // The CLI turns numeric-looking arguments into numbers; accept them where text is expected.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        throw AgentError.invalidParams("\(key) must be a string")
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw AgentError.invalidParams("Missing \(key)") }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let b = value as? Bool else { throw AgentError.invalidParams("\(key) must be true or false") }
        return b
    }

    func number(_ key: String) throws -> Double? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        // JSON true/false also arrive as NSNumber; only CFBoolean tells them apart.
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw AgentError.invalidParams("\(key) must be a number")
        }
        return n.doubleValue
    }

    /// A whole number; fractions are cut off, and values `Int` can't hold are rejected rather than trapping.
    func integer(_ key: String) throws -> Int? {
        guard let n = try number(key) else { return nil }
        guard let i = Int(exactly: n.rounded(.towardZero)) else { throw AgentError.invalidParams("\(key) is out of range") }
        return i
    }
}
