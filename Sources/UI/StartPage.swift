/// The page a new tab shows: quiet, matches the card color, and teaches the three keys that matter.
@MainActor
enum StartPage {
    /// Shortcut hints come from the live keymap, so rebinding updates the page.
    private static func keys(_ c: Command) -> String {
        (Keymap.shared.primaryChord(for: c)?.glyphs ?? []).map { "<kbd>\($0)</kbd>" }.joined()
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
    </style></head>
    <body><main>
      <div class="mark">tern<span>.</span></div>
      <ul>
        <li><span class="keys">\(keys(.focusAddressBar))</span><span class="label">Search or enter address</span></li>
        <li><span class="keys">\(keys(.commandPalette))</span><span class="label">Command palette</span></li>
        <li><span class="keys">\(keys(.tabPicker))</span><span class="label">Switch tabs</span></li>
      </ul>
    </main></body></html>
    """
}
}
