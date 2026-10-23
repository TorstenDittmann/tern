/// The page a new tab shows: quiet, matches the card color, teaches the three keys that matter, and
/// offers your bookmarks and most visited sites as tiles.
@MainActor
enum StartPage {
    /// Shortcut hints come from the live keymap, so rebinding updates the page.
    private static func keys(_ c: Command) -> String {
        (Keymap.shared.primaryChord(for: c)?.glyphs ?? []).map { "<kbd>\($0)</kbd>" }.joined()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func tile(url: String, title: String) -> String {
        guard let parsed = URL(string: url), HistoryStore.isRecordable(parsed), let host = parsed.host else { return "" }
        let letter = escape(String((title.first { $0.isLetter || $0.isNumber } ?? host.first ?? "?")).uppercased())
        let icon = escape("\(parsed.scheme ?? "https")://\(host)\(parsed.port.map { ":\($0)" } ?? "")/favicon.ico")
        return """
        <a class="tile" href="\(escape(url))" title="\(escape(url))">
          <span class="icon"><b>\(letter)</b><img src="\(icon)" alt="" onerror="this.remove()" onload="this.previousElementSibling.remove()"></span>
          <span class="name">\(escape(title))</span>
        </a>
        """
    }

    /// Bookmarks first, then the most visited pages that aren't bookmarked.
    private static var tiles: String {
        let bookmarks = BookmarkStore.shared.all.prefix(8)
        let frequent = HistoryStore.shared.ranked(limit: 40)
            .filter { !BookmarkStore.shared.contains(URL(string: $0.url)) }
            .prefix(bookmarks.isEmpty ? 8 : 4)
        var html = ""
        if !bookmarks.isEmpty {
            html += "<h2>Bookmarks</h2><nav>" + bookmarks.map { tile(url: $0.url, title: $0.title) }.joined() + "</nav>"
        }
        if !frequent.isEmpty {
            html += "<h2>Frequently Visited</h2><nav>" + frequent.map {
                tile(url: $0.url, title: $0.title?.isEmpty == false ? $0.title! : HistoryStore.bare($0.url))
            }.joined() + "</nav>"
        }
        return html
    }

    static var html: String { """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>New Tab</title>
    <meta name="color-scheme" content="light dark">
    <style>
      :root { --bg: #ffffff; --fg: #1d1d1f; --muted: #86868b; --cap: rgba(0,0,0,.06); --capBorder: rgba(0,0,0,.08); }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #1e1e1e; --fg: #f5f5f7; --muted: #8e8e93; --cap: rgba(255,255,255,.08); --capBorder: rgba(255,255,255,.08); }
      }
      html, body { height: 100%; margin: 0; }
      body { background: var(--bg); color: var(--fg); font: 13px/1.4 -apple-system, system-ui, sans-serif;
             display: grid; place-items: center; -webkit-user-select: none; cursor: default; }
      main { text-align: center; transform: translateY(-6vh); }
      .mark { font: 600 34px/1 ui-rounded, -apple-system, system-ui; letter-spacing: -0.02em; opacity: .9; }
      .mark span { color: var(--muted); font-weight: 500; }
      ul { list-style: none; padding: 0; margin: 28px 0 0; display: grid; gap: 10px; color: var(--muted); }
      li { display: grid; grid-template-columns: 112px 150px; align-items: center; gap: 14px; }
      li .keys { justify-self: end; display: flex; gap: 4px; }
      li .label { text-align: left; }
      kbd { font: 500 12px -apple-system, system-ui; min-width: 22px; height: 22px; padding: 0 6px; box-sizing: border-box;
            display: inline-grid; place-items: center; border-radius: 6px; background: var(--cap);
            box-shadow: inset 0 0 0 0.5px var(--capBorder); color: var(--fg); }
      h2 { font: 600 11px/1 -apple-system, system-ui; color: var(--muted); text-transform: uppercase; letter-spacing: .06em;
           margin: 34px 0 12px; }
      nav { display: grid; grid-template-columns: repeat(4, 96px); gap: 10px; justify-content: center; }
      .tile { display: grid; justify-items: center; gap: 7px; padding: 12px 6px 10px; border-radius: 10px;
              color: var(--fg); text-decoration: none; cursor: pointer; }
      .tile:hover { background: var(--cap); }
      .icon { width: 36px; height: 36px; border-radius: 9px; background: var(--cap); display: grid; place-items: center;
              box-shadow: inset 0 0 0 0.5px var(--capBorder); overflow: hidden; }
      .icon b { font: 600 15px/1 ui-rounded, -apple-system, system-ui; color: var(--muted); }
      .icon img { width: 20px; height: 20px; }
      .name { font-size: 11.5px; max-width: 90px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    </style></head>
    <body><main>
      <div class="mark">tern<span>.</span></div>
      <ul>
        <li><span class="keys">\(keys(.focusAddressBar))</span><span class="label">Search or enter address</span></li>
        <li><span class="keys">\(keys(.commandPalette))</span><span class="label">Command palette</span></li>
        <li><span class="keys">\(keys(.tabPicker))</span><span class="label">Switch tabs</span></li>
      </ul>
      \(tiles)
    </main></body></html>
    """
}
}
