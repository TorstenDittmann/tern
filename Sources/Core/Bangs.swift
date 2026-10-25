import Foundation

/// DuckDuckGo-style !bangs in the address bar and ⌘K: `!gh swift-nio` (or `swift-nio !gh`) searches
/// GitHub, and a bang on its own opens the site. Add your own, or override a built-in, in
/// `~/.config/tern/bangs.json`:
///
///     { "jira": "https://acme.atlassian.net/browse/%s", "gh": "https://github.com/search?q=%s&type=code" }
@MainActor
enum Bangs {
    struct Bang: Equatable {
        let trigger: String
        let name: String
        /// `%s` is replaced with the query.
        let template: String

        /// The site itself, for a bang without a query.
        var home: URL? {
            guard let url = URL(string: template.replacingOccurrences(of: "%s", with: "")),
                  let scheme = url.scheme, let host = url.host else { return nil }
            return URL(string: "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "") + "/")
        }

        func url(for query: String) -> URL? {
            guard !query.isEmpty else { return home }
            let q = query.addingPercentEncoding(withAllowedCharacters: Bangs.queryAllowed) ?? query
            return URL(string: template.replacingOccurrences(of: "%s", with: q))
        }
    }

    static let builtIn: [Bang] = [
        Bang(trigger: "g", name: "Google", template: "https://www.google.com/search?q=%s"),
        Bang(trigger: "gi", name: "Google Images", template: "https://www.google.com/search?tbm=isch&q=%s"),
        Bang(trigger: "maps", name: "Google Maps", template: "https://www.google.com/maps/search/%s"),
        Bang(trigger: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        Bang(trigger: "k", name: "Kagi", template: "https://kagi.com/search?q=%s"),
        Bang(trigger: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%s"),
        Bang(trigger: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
        Bang(trigger: "mdn", name: "MDN", template: "https://developer.mozilla.org/search?q=%s"),
        Bang(trigger: "caniuse", name: "Can I use", template: "https://caniuse.com/?search=%s"),
        Bang(trigger: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q=%s"),
        Bang(trigger: "npm", name: "npm", template: "https://www.npmjs.com/search?q=%s"),
        Bang(trigger: "pypi", name: "PyPI", template: "https://pypi.org/search/?q=%s"),
        Bang(trigger: "crates", name: "crates.io", template: "https://crates.io/search?q=%s"),
        Bang(trigger: "rs", name: "Docs.rs", template: "https://docs.rs/releases/search?query=%s"),
        Bang(trigger: "go", name: "Go Packages", template: "https://pkg.go.dev/search?q=%s"),
        Bang(trigger: "spi", name: "Swift Package Index", template: "https://swiftpackageindex.com/search?query=%s"),
        Bang(trigger: "apple", name: "Apple Developer", template: "https://developer.apple.com/search/?q=%s"),
        Bang(trigger: "docker", name: "Docker Hub", template: "https://hub.docker.com/search?q=%s"),
        Bang(trigger: "hn", name: "Hacker News", template: "https://hn.algolia.com/?q=%s"),
        Bang(trigger: "r", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
        Bang(trigger: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        Bang(trigger: "w", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/Special:Search?search=%s"),
        Bang(trigger: "x", name: "X", template: "https://x.com/search?q=%s"),
        Bang(trigger: "a", name: "Amazon", template: "https://www.amazon.com/s?k=%s"),
        Bang(trigger: "tr", name: "Google Translate", template: "https://translate.google.com/?sl=auto&tl=en&op=translate&text=%s"),
    ]

    /// Query characters that would change the template URL's meaning (`&`, `+`, `#`, `=`, `/`, `?`) are escaped.
    nonisolated static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+#=/?")
        return set
    }()

    /// Set by the smoke test, so it never reads your own bangs.
    static var fileOverride: URL?

    static var fileURL: URL {
        fileOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tern/bangs.json")
    }

    private static var custom: [String: Bang] = [:]
    private static var customLoadedAt: Date?

    /// Built-ins, then the user's file over them. The file is read again when it changes.
    static func lookup(_ trigger: String) -> Bang? {
        reloadIfChanged()
        let t = trigger.lowercased()
        return custom[t] ?? builtIn.first { $0.trigger == t }
    }

    /// "!gh swift-nio" or "swift-nio !gh" → GitHub, "swift-nio". A known bang alone gives an empty query.
    static func parse(_ input: String) -> (bang: Bang, query: String)? {
        let words = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return nil }
        for index in Set([words.startIndex, words.endIndex - 1]) {
            let word = words[index]
            guard word.count > 1, word.hasPrefix("!"), let bang = lookup(String(word.dropFirst())) else { continue }
            var rest = words
            rest.remove(at: index)
            return (bang, rest.joined(separator: " "))
        }
        return nil
    }

    static func url(for input: String) -> URL? {
        guard let (bang, query) = parse(input) else { return nil }
        return bang.url(for: query)
    }

    private static func reloadIfChanged() {
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != customLoadedAt else { return }
        customLoadedAt = modified
        custom = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in json where !key.hasPrefix("_") {
            guard let template = value as? String, template.contains("%s"), let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
                  let host = url.host else { NSLog("Tern bangs: \(key) needs a URL with %s"); continue }
            let trigger = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "! "))
            let name = builtIn.first { $0.trigger == trigger }?.name ?? host.replacingOccurrences(of: "www.", with: "")
            custom[trigger] = Bang(trigger: trigger, name: name, template: template)
        }
    }
}
