import Foundation
import WebKit

/// Ad and tracker blocking, on by default. EasyList (ads) and EasyPrivacy (trackers) are downloaded,
/// converted to WebKit content rules and compiled once; WebKit keeps the compiled lists on disk, so a
/// launch only looks them up. Lists refresh in the background every few days.
///
/// Blocking is per site: local dev servers are left alone unless you turn it on for them, and any
/// other site can be turned off. The same switch covers stripping tracking parameters from links.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    struct Source { let id: String; let url: URL }

    /// One rule list each: WebKit caps a list at 150,000 rules, and EasyList alone is over half that.
    private(set) var sources = [
        Source(id: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Source(id: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]
    /// The lists' own "Expires: 4 days".
    static let refreshInterval: TimeInterval = 4 * 86_400

    /// Rules that need no download: third-party pings (`<a ping>`, beacons) never do anything for you.
    static let builtInRules = #"[{"trigger":{"url-filter":".*","resource-type":["ping"],"load-type":["third-party"]},"action":{"type":"block"}}]"#

    private let store = WKContentRuleListStore.default()
    private(set) var installed: [String: WKContentRuleList] = [:]
    private var updating: Task<Void, Never>?
    private var timer: Timer?
    private var controller: WKUserContentController { BrowserEngine.shared.webViewConfiguration.userContentController }

    private init() {
        // The smoke test compiles a small local list instead, under its own identifier.
        if SmokeTest.isRunning, let path = ProcessInfo.processInfo.environment["TERN_SMOKE_FILTERS"] {
            sources = [Source(id: "smoke", url: URL(fileURLWithPath: path))]
        }
    }

    func start() {
        Task {
            do { install(try await compile("tern", Self.builtInRules), "tern") }
            catch { NSLog("Tern content blocker: built-in rules failed to compile: \(error)") }
            await update()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await ContentBlocker.shared.update() }
        }
    }

    // MARK: Per site

    /// Whether blocking and link cleaning apply to pages on this URL's host.
    func isEnabled(for url: URL?) -> Bool {
        guard Preferences.blocksTrackers else { return false }
        guard let site = Self.site(url) else { return true }
        return Self.isLocal(site) == Preferences.blockingExceptions.contains(site)
    }

    func toggle(for url: URL?) {
        guard let site = Self.site(url) else { return }
        var exceptions = Preferences.blockingExceptions
        if exceptions.remove(site) == nil { exceptions.insert(site) }
        Preferences.blockingExceptions = exceptions
    }

    /// Sites are hosts without a leading "www.", so turning it off on one covers both spellings.
    static func site(_ url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test")
            || host.hasPrefix("127.") || host == "0.0.0.0" || host == "::1" || host == "[::1]"
    }

    /// Turns the content rule lists on or off for one navigation. `_contentBlockersEnabled` is SPI
    /// (Safari's "Disable Content Blockers"); WebKit has no public per-page switch.
    static func apply(_ enabled: Bool, to preferences: WKWebpagePreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setContentBlockersEnabled:")) else { return }
        preferences.setValue(enabled, forKey: "contentBlockersEnabled")
    }

    // MARK: Lists

    /// Installs the compiled lists, and downloads and compiles any that are missing or stale.
    func update(force: Bool = false) async {
        if let updating { return await updating.value }
        let task = Task {
            for source in sources {
                if installed[source.id] == nil, let list = await lookUp(source.id) { install(list, source.id) }
                let age = Date().timeIntervalSince1970 - (Preferences.blocklistsUpdated[source.id] ?? 0)
                guard force || installed[source.id] == nil || age > Self.refreshInterval, Preferences.blocksTrackers || force else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: source.url)
                    let json = try await Task.detached(priority: .utility) { try FilterList.json(from: data) }.value
                    let started = Date()
                    let list = try await compile(source.id, json)
                    NSLog("Tern content blocker: compiled \(source.id) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    install(list, source.id)
                    Preferences.blocklistsUpdated[source.id] = Date().timeIntervalSince1970
                } catch {
                    NSLog("Tern content blocker: \(source.id) not updated: \(error.localizedDescription)")
                }
            }
        }
        updating = task
        await task.value
        updating = nil
    }

    private func install(_ list: WKContentRuleList, _ id: String) {
        if let old = installed[id] { controller.remove(old) }
        controller.add(list)
        installed[id] = list
    }

    private func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { done in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in done.resume(returning: list) }
        }
    }

    private func compile(_ id: String, _ json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { done in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let list { done.resume(returning: list) } else { done.resume(throwing: error ?? CocoaError(.featureUnsupported)) }
            }
        }
    }
}

// MARK: - Filter lists

/// Converts Adblock Plus filter lists (EasyList syntax) to WebKit content rules. It covers what
/// EasyList and EasyPrivacy mostly use: network filters with type, party and domain options,
/// exceptions, and element hiding. Rules WebKit can't express (regexes, scriptlets, `$csp`,
/// `$redirect`, procedural selectors) are skipped rather than approximated.
enum FilterList {
    typealias Rule = [String: Any]

    static func json(from data: Data) throws -> String {
        let rules = convert(String(decoding: data, as: UTF8.self))
        guard !rules.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }

    /// Order matters: an `ignore-previous-rules` action only undoes the rules above it. So blocks
    /// come first, then a rule that lets top-level pages load (EasyPrivacy's `/analytics.` must not
    /// block a page you open), then element hiding, then the exceptions.
    static func convert(_ text: String) -> [Rule] {
        var blocks: [Rule] = [], pageBlocks: [Rule] = [], hiding: [Rule] = [], hidingOff: [Rule] = [], exceptions: [Rule] = []
        var generic: [String] = [], genericOff: [String: [String]] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), line.allSatisfy(\.isASCII) else { continue }
            if ["#?#", "#$#", "#%#", "#@$#", "#@?#", "#@%#"].contains(where: { line.contains($0) }) { continue }

            if let r = line.range(of: "#@#") {
                let selector = String(line[r.upperBound...])
                guard let (on, _) = domains(line[..<r.lowerBound], separator: ","), !on.isEmpty else { continue }
                genericOff[selector, default: []] += on
                continue
            }
            if let r = line.range(of: "##") {
                let selector = String(line[r.upperBound...])
                guard isUsable(selector) else { continue }
                let scope = line[..<r.lowerBound]
                if scope.isEmpty { generic.append(selector); continue }
                guard let (on, off) = domains(scope, separator: ",") else { continue }
                var trigger: Rule = ["url-filter": ".*"]
                if on.isEmpty { trigger["unless-domain"] = off } else { trigger["if-domain"] = on }
                hiding.append(rule(trigger, ["type": "css-display-none", "selector": selector]))
                continue
            }
            guard let filter = network(line) else { continue }
            switch filter.kind {
            case .block: blocks.append(filter.rule)
            case .blockPage: pageBlocks.append(filter.rule)
            case .allow: exceptions.append(filter.rule)
            case .allowHiding: hidingOff.append(filter.rule)
            }
        }

        let genericRules = generic.map { selector -> Rule in
            var trigger: Rule = ["url-filter": ".*"]
            if let off = genericOff[selector] { trigger["unless-domain"] = off }
            return rule(trigger, ["type": "css-display-none", "selector": selector])
        }
        let pagesLoad = rule(["url-filter": ".*", "resource-type": ["document"], "load-context": ["top-frame"]], ["type": "ignore-previous-rules"])
        return blocks + [pagesLoad] + pageBlocks + genericRules + hiding + hidingOff + exceptions
    }

    private static func rule(_ trigger: Rule, _ action: Rule) -> Rule { ["trigger": trigger, "action": action] }

    private enum Kind { case block, blockPage, allow, allowHiding }

    /// ABP request types → WebKit resource types.
    private static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch", "websocket": "websocket", "ping": "ping",
        "other": "other", "object": "other", "subdocument": "document", "frame": "document", "popup": "popup",
    ]
    /// What a filter without a type covers, for working out `~script` and the like. Top-level pages
    /// are let through by a rule after the blocks.
    private static let defaultTypes: Set<String> = ["script", "image", "style-sheet", "font", "media", "fetch", "websocket", "ping", "other", "document", "svg-document"]

    private static func network(_ line: String) -> (kind: Kind, rule: Rule)? {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }
        var options: [Substring] = []
        if let dollar = body.lastIndex(of: "$"), !body[dollar...].contains("/") {
            options = body[body.index(after: dollar)...].split(separator: ",")
            body = body[..<dollar]
        }
        // Regular-expression filters use syntax WebKit's matcher doesn't have.
        if body.count > 1, body.hasPrefix("/"), body.hasSuffix("/") { return nil }

        var trigger: Rule = [:]
        var included = Set<String>(), excluded = Set<String>()
        var page = false, hidingOnly = false, hasDomain = false
        for option in options {
            let o = option.lowercased()
            let negated = o.hasPrefix("~")
            let name = negated ? String(o.dropFirst()) : o
            switch name {
            case "third-party", "3p": trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p": trigger["load-type"] = [negated ? "third-party" : "first-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case "important": break
            case "document", "doc":
                guard !negated else { return nil }
                page = true
            case "elemhide", "ehide", "generichide", "ghide":
                guard isException, !negated else { return nil }
                hidingOnly = true
            case _ where name.hasPrefix("domain="):
                guard let (on, off) = domains(name.dropFirst(7), separator: "|") else { return nil }
                if on.isEmpty { trigger["unless-domain"] = off } else { trigger["if-domain"] = on }
                hasDomain = true
            default:
                guard let type = types[name] else { return nil } // $csp, $redirect, $removeparam…
                if negated { excluded.insert(type) } else { included.insert(type) }
            }
        }
        guard let filter = pattern(body) else { return nil }

        // A page-wide exception: nothing in this list applies on pages that match.
        if isException && (page || hidingOnly) {
            guard !hasDomain, included.isEmpty, excluded.isEmpty, filter != ".*" else { return nil }
            var t: Rule = ["url-filter": ".*", "if-top-url": [filter]]
            if hidingOnly && !page { t["resource-type"] = ["document"] } // the page load carries its element hiding
            return (.allowHiding, rule(t, ["type": "ignore-previous-rules"]))
        }
        if page && !isException {
            guard included.isEmpty, excluded.isEmpty else { return nil }
            trigger["resource-type"] = ["document"]
            trigger["load-context"] = ["top-frame"]
        } else {
            let resolved = included.isEmpty ? defaultTypes.subtracting(excluded) : included.subtracting(excluded)
            guard !resolved.isEmpty else { return nil }
            if !included.isEmpty || !excluded.isEmpty { trigger["resource-type"] = resolved.sorted() }
            if included == ["document"] { trigger["load-context"] = ["child-frame"] }
        }
        // An empty pattern matches every URL: only fine when the options narrow it to some sites.
        if filter == ".*" && !hasDomain { return nil }
        trigger["url-filter"] = filter
        return (isException ? .allow : page ? .blockPage : .block, rule(trigger, ["type": isException ? "ignore-previous-rules" : "block"]))
    }

    /// ABP pattern → WebKit's regex subset. `||` anchors at a host boundary, `|` at the start or end,
    /// `^` stands for a separator, `*` for anything.
    static func pattern(_ abp: Substring) -> String? {
        var p = abp, out = ""
        if p.hasPrefix("||") { out = #"^[^:]+:(//)?([^/]+\.)?"#; p = p.dropFirst(2) }
        else if p.hasPrefix("|") { out = "^"; p = p.dropFirst() }
        let anchoredEnd = p.hasSuffix("|")
        if anchoredEnd { p = p.dropLast() }
        for c in p {
            switch c {
            case "*": if !out.hasSuffix(".*") { out += ".*" }
            case "^": out += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "{", "}", "(", ")", "[", "]", "\\", "$", "|": out += "\\\(c)"
            default:
                guard c.isASCII, !c.isWhitespace else { return nil }
                out.append(c)
            }
        }
        if out.hasPrefix(".*") { out.removeFirst(2) }
        if out.hasSuffix(".*") && !anchoredEnd { out.removeLast(2) }
        if anchoredEnd { out += "$" }
        return out.isEmpty || out == "^" ? ".*" : out
    }

    /// "a.com,~b.a.com" → if-domain or unless-domain entries, which match subdomains too. WebKit can't
    /// do both in one rule, and `example.*` has no WebKit spelling, so those filters are skipped.
    private static func domains(_ list: Substring, separator: Character) -> (on: [String], off: [String])? {
        var on: [String] = [], off: [String] = []
        for entry in list.split(separator: separator) {
            let negated = entry.hasPrefix("~")
            let name = (negated ? entry.dropFirst() : entry).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            if negated { off.append("*" + name) } else { on.append("*" + name) }
        }
        guard on.isEmpty != off.isEmpty else { return nil }
        return (on, off)
    }

    /// Plain CSS only: no extended syntax (`:-abp-has`, `:has-text`, `:style`…), which WebKit would reject.
    private static func isUsable(_ selector: String) -> Bool {
        guard !selector.isEmpty, !selector.contains("{") else { return false }
        return ![":-abp-", ":has-text(", ":contains(", ":xpath(", ":upward(", ":remove(", ":style(", ":matches-",
                 ":min-text-length(", ":watch-attr(", ":others(", ":if(", ":if-not(", ":nth-ancestor(", "+js("]
            .contains(where: { selector.contains($0) })
    }
}

// MARK: - Tracking parameters

/// Click and campaign IDs that only exist to follow you from site to site.
enum TrackingParameters {
    static let names: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "igshid",
        "li_fat_id", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "_openstat", "srsltid",
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = (name.removingPercentEncoding ?? name).lowercased()
        return n.hasPrefix("utm_") || names.contains(n)
    }

    /// The URL without its tracking parameters, or nil when it has none. Works on the string so the
    /// rest of the query keeps its exact encoding and order.
    static func strip(_ url: URL) -> URL? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let s = url.absoluteString
        guard let q = s.firstIndex(of: "?") else { return nil }
        let end = s[q...].firstIndex(of: "#") ?? s.endIndex
        let parts = s[s.index(after: q)..<end].split(separator: "&", omittingEmptySubsequences: false)
        let kept = parts.filter { !isTracking(String($0.prefix { $0 != "=" })) }
        guard kept.count < parts.count else { return nil }
        return URL(string: String(s[..<q]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + s[end...])
    }
}
