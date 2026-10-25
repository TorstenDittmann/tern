import WebKit

/// JSON responses (`application/json`, `+json`) open as a collapsible tree with a raw view, instead of
/// one long line of text. A user script in its own content world swaps WebKit's plain-text page for the
/// viewer; anything that isn't a JSON document, or doesn't parse, is left alone.
@MainActor
enum JSONViewer {
    static let world = WKContentWorld.world(name: "tern-json")

    static let userScript = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)

    static let source = #"""
    (() => {
      if (!/(^|[\/+])json(\b|$)/i.test(document.contentType || "")) return;
      const body = document.body;
      if (!body || body.children.length !== 1 || body.firstElementChild.tagName !== "PRE") return;
      const raw = body.firstElementChild.textContent;
      if (raw.length > 8e6) return;
      let data;
      try { data = JSON.parse(raw); } catch (e) { return; }

      let nodes = 0;
      (function count(v) { if (v && typeof v === "object") for (const k in v) { nodes++; if (nodes < 5000) count(v[k]); } })(data);
      const openDepth = nodes > 3000 ? 1 : nodes > 800 ? 2 : 99;

      const el = (tag, cls, text) => {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text !== undefined) e.textContent = text;
        return e;
      };
      const keyLabel = (key, isIndex) => key === undefined ? null
        : el("span", isIndex ? "i" : "k", isIndex ? key + ": " : JSON.stringify(key) + ": ");
      const scalar = (v) => {
        if (v === null) return el("span", "z", "null");
        switch (typeof v) {
          case "string":
            if (/^https?:\/\/\S+$/.test(v)) {
              const a = el("a", "s", JSON.stringify(v));
              a.href = v;
              return a;
            }
            return el("span", "s", JSON.stringify(v));
          case "number": return el("span", "n", String(v));
          case "boolean": return el("span", "b", String(v));
          default: return el("span", "z", String(v));
        }
      };
      const render = (v, key, isIndex, depth) => {
        if (v === null || typeof v !== "object") {
          const line = el("div", "line");
          const k = keyLabel(key, isIndex); if (k) line.append(k);
          line.append(scalar(v));
          return line;
        }
        const isArray = Array.isArray(v);
        const entries = isArray ? v.map((x, i) => [i, x]) : Object.entries(v);
        const open = isArray ? "[" : "{", close = isArray ? "]" : "}";
        if (entries.length === 0) {
          const line = el("div", "line");
          const k = keyLabel(key, isIndex); if (k) line.append(k);
          line.append(el("span", "p", open + close));
          return line;
        }
        const details = el("details");
        details.open = depth < openDepth;
        const summary = el("summary");
        const k = keyLabel(key, isIndex); if (k) summary.append(k);
        summary.append(el("span", "p", open));
        summary.append(el("span", "c", " " + entries.length + (isArray ? (entries.length === 1 ? " item" : " items") : (entries.length === 1 ? " key" : " keys")) + " " + close));
        details.append(summary);
        const children = el("div", "kids");
        for (const [ck, cv] of entries) children.append(render(cv, ck, isArray, depth + 1));
        details.append(children);
        details.append(el("div", "line p end", close));
        return details;
      };

      const style = el("style");
      style.textContent = `
        :root { color-scheme: light dark; --fg: #1d1f22; --muted: #7a7f87; --key: #8a3ab9; --str: #2e8b4a; --num: #b4570f;
                --bool: #1f6fd1; --bar: #f5f6f7; --line: rgba(0,0,0,.09); --hover: rgba(0,0,0,.045); --accent: #2e8b4a; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #e6e8eb; --muted: #8b9098; --key: #d2a8ff; --str: #9be8a6; --num: #ffb57a; --bool: #79b8ff;
                  --bar: #121417; --line: #24272c; --hover: rgba(255,255,255,.045); --accent: #9be8a6; }
        }
        html, body { margin: 0; background: Canvas; color: var(--fg); }
        #tern-json-bar { position: sticky; top: 0; display: flex; gap: 4px; align-items: center; padding: 6px 10px;
          background: var(--bar); border-bottom: 1px solid var(--line); font: 12px -apple-system, system-ui, sans-serif; z-index: 1; }
        #tern-json-bar button { font: inherit; color: var(--fg); background: none; border: 0; border-radius: 6px; padding: 4px 9px; cursor: default; }
        #tern-json-bar button:hover { background: var(--hover); }
        #tern-json-bar button.on { color: var(--accent); background: var(--hover); font-weight: 600; }
        #tern-json-bar .spacer { flex: 1; }
        #tern-json-bar .meta { color: var(--muted); font: 11px ui-monospace, Menlo, monospace; }
        #tern-json-tree, #tern-json-raw { font: 12.5px/1.55 ui-monospace, "SF Mono", Menlo, monospace; padding: 10px 14px 40px; }
        #tern-json-raw { white-space: pre-wrap; word-break: break-all; margin: 0; }
        .kids { padding-left: 1.4em; border-left: 1px solid var(--line); margin-left: .3em; }
        details > summary { list-style: none; cursor: default; border-radius: 4px; }
        details > summary::-webkit-details-marker { display: none; }
        details > summary::before { content: "▸"; display: inline-block; width: 1em; margin-left: -1em; color: var(--muted); transition: transform .1s; }
        details[open] > summary::before { transform: rotate(90deg); }
        details[open] > summary > .c { display: none; }
        details:not([open]) > .end { display: none; }
        summary:hover, .line:hover { background: var(--hover); }
        .line { border-radius: 4px; }
        .k { color: var(--key); } .i { color: var(--muted); } .s { color: var(--str); } .n { color: var(--num); }
        .b, .z { color: var(--bool); } .p, .c { color: var(--muted); }
        a.s { text-decoration: none; } a.s:hover { text-decoration: underline; }
        [hidden] { display: none !important; }
      `;

      const bar = el("div"); bar.id = "tern-json-bar";
      const tree = el("div"); tree.id = "tern-json-tree";
      tree.append(render(data, undefined, false, 0));
      const rawView = el("pre"); rawView.id = "tern-json-raw"; rawView.hidden = true;
      rawView.textContent = raw;
      const button = (label, action) => { const b = el("button", "", label); b.addEventListener("click", action); bar.append(b); return b; };
      const prettyButton = button("Tree", () => show(false));
      const rawButton = button("Raw", () => show(true));
      const formatButton = button("Format", () => { rawView.textContent = rawView.textContent === raw ? JSON.stringify(data, null, 2) : raw; });
      bar.append(el("span", "spacer"));
      const collapse = button("Collapse All", () => tree.querySelectorAll("details").forEach(d => d.open = false));
      const expand = button("Expand All", () => tree.querySelectorAll("details").forEach(d => d.open = true));
      button("Copy", (e) => {
        navigator.clipboard.writeText(raw).then(() => { e.target.textContent = "Copied"; setTimeout(() => e.target.textContent = "Copy", 1200); });
      });
      const size = raw.length < 1024 ? raw.length + " B" : raw.length < 1048576 ? (raw.length / 1024).toFixed(1) + " KB" : (raw.length / 1048576).toFixed(1) + " MB";
      bar.append(el("span", "meta", size));
      const show = (rawMode) => {
        tree.hidden = rawMode; rawView.hidden = !rawMode;
        prettyButton.classList.toggle("on", !rawMode); rawButton.classList.toggle("on", rawMode);
        formatButton.hidden = !rawMode; collapse.hidden = rawMode; expand.hidden = rawMode;
      };
      show(false);

      (document.head || document.documentElement).append(style);
      body.replaceChildren(bar, tree, rawView);
      document.documentElement.dataset.ternJson = "tree";
    })();
    """#
}
