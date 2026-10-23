import AppKit
import WebKit

/// ⌘J: label every link, button and field on screen with a short letter code; typing a code clicks it.
/// Hold ⇧ on the last letter to open a link in a background tab, ⌥ to peek at it. Esc, a click or
/// any ⌘-shortcut cancels. The labels live in a private content world, out of the page's reach.
@MainActor
final class LinkHints {
    private(set) static var active: LinkHints?
    static let world = WKContentWorld.world(name: "tern-hints")

    private weak var tab: Tab?
    private var typed = ""
    private var mouseMonitor: Any?

    private init(tab: Tab) { self.tab = tab }

    /// Shows hints on the focused pane. Returns how many there are (0: nothing to hint, no mode).
    @discardableResult
    static func start(in browser: BrowserWindowController) async -> Int {
        active?.cancel()
        guard let tab = browser.activeTab, let webView = tab.webView else { return 0 }
        let count = (try? await call(webView, "show", [:])) as? Int ?? 0
        guard count > 0 else { NSSound.beep(); return 0 }
        let hints = LinkHints(tab: tab)
        hints.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { LinkHints.active?.cancel() }
            return event
        }
        active = hints
        return count
    }

    /// Takes every key while hints are up. Returns false for keys the app should still handle.
    func handle(_ event: NSEvent) -> Bool {
        guard let tab, tab.isActive, let webView = tab.webView, event.window === webView.window else {
            cancel()
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { cancel(); return false }

        switch event.keyCode {
        case 53: cancel(); return true // esc
        case 51: // ⌫
            if !typed.isEmpty { typed.removeLast(); filter(webView) }
            return true
        default: break
        }
        guard let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1,
              Self.alphabet.contains(c) else { return true }
        typed += c
        Task { await self.advance(webView, background: flags.contains(.shift), peek: flags.contains(.option)) }
        return true
    }

    func cancel() {
        if let webView = tab?.webView { webView.callAsyncJavaScript(Self.body, arguments: ["method": "hide", "args": [String: Any]()], in: nil, in: Self.world) { _ in } }
        finish()
    }

    private func finish() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if Self.active === self { Self.active = nil }
    }

    private func filter(_ webView: WKWebView) {
        webView.callAsyncJavaScript(Self.body, arguments: ["method": "filter", "args": ["typed": typed]], in: nil, in: Self.world) { _ in }
    }

    /// Narrows the hints to what's been typed; on an exact match, acts on that element.
    private func advance(_ webView: WKWebView, background: Bool, peek: Bool) async {
        let result = (try? await Self.call(webView, "filter", ["typed": typed])) as? [String: Any] ?? [:]
        let matches = result["matches"] as? Int ?? 0
        if matches == 0 { typed.removeLast(); filter(webView); return NSSound.beep() }
        guard let target = result["hit"] as? [String: Any], let tab else { return }
        finish()
        let href = (target["href"] as? String).flatMap(URL.init(string:)).flatMap { HistoryStore.isRecordable($0) ? $0 : nil }
        if let href, peek, let browser = tab.owner {
            browser.content.peek(href, from: tab)
        } else if let href, background, let browser = tab.owner {
            browser.newTab(url: href, activate: false, after: tab)
        } else if let x = target["x"] as? Double, let y = target["y"] as? Double, AgentPageMethods.canSendEvents(to: tab) {
            webView.window?.makeFirstResponder(webView)
            AgentPageMethods.sendClick(to: webView, at: AgentPageMethods.windowPoint(webView, x: x, y: y), modifiers: [])
        } else {
            _ = try? await Self.call(webView, "click", [:])
        }
    }

    private static func call(_ webView: WKWebView, _ method: String, _ args: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { done in
            webView.callAsyncJavaScript(body, arguments: ["method": method, "args": args], in: nil, in: world) { done.resume(with: $0) }
        }
    }

    // MARK: Page side

    /// Home-row first, like Vimium; every label has the same length, so none is a prefix of another.
    static let alphabet = "sadfjklewcmpgh"

    private static let body = """
    const hints = globalThis.__ternHints || (globalThis.__ternHints = \(script));
    const result = hints[method](args);
    return result === undefined ? null : result;
    """

    private static let script = #"""
    (() => {
      const ALPHABET = 'sadfjklewcmpgh';
      const CLICKABLE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,label[for],' +
        '[role=button],[role=link],[role=tab],[role=checkbox],[role=radio],[role=switch],[role=menuitem],' +
        '[role=option],[onclick],[tabindex]:not([tabindex="-1"]),[contenteditable=""],[contenteditable=true]';
      let host = null, items = [], picked = null;

      function visibleTargets() {
        const vw = innerWidth, vh = innerHeight, seen = new Set(), out = [];
        for (const el of document.querySelectorAll(CLICKABLE)) {
          if (el.disabled || (el.checkVisibility && !el.checkVisibility({ visibilityProperty: true }))) continue;
          const rects = [...el.getClientRects()].filter(r => r.width > 1 && r.height > 1);
          const r = rects.find(r => r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw);
          if (!r) continue;
          const x = Math.min(Math.max(r.left + Math.min(r.width / 2, 12), 1), vw - 1);
          const y = Math.min(Math.max(r.top + r.height / 2, 1), vh - 1);
          const hit = document.elementFromPoint(x, y);
          if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) continue; // covered
          // A button inside a link (or the reverse) gets one hint, for the outer element.
          if ([...seen].some(s => s.contains(el))) continue;
          seen.add(el);
          out.push({ el, r, x, y });
        }
        return out;
      }

      function labels(n) {
        let len = 1;
        while (ALPHABET.length ** len < n) len++;
        return Array.from({ length: n }, (_, i) => {
          let s = '';
          for (let k = 0; k < len; k++) { s = ALPHABET[i % ALPHABET.length] + s; i = Math.floor(i / ALPHABET.length); }
          return s;
        });
      }

      function show() {
        hide();
        const targets = visibleTargets();
        if (!targets.length) return 0;
        host = document.createElement('tern-hints');
        host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647';
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = `<style>
          span { position: fixed; font: 700 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
            padding: 2px 4px; border-radius: 4px; background: #ffd54a; color: #1b1b1b;
            box-shadow: 0 1px 3px rgba(0,0,0,.35), 0 0 0 1px rgba(0,0,0,.25); text-transform: uppercase;
            letter-spacing: .5px; transform: translate(-2px, -2px); }
          span[hidden] { display: none; }
          b { color: #a07400; font-weight: 700; }
        </style>`;
        const names = labels(targets.length);
        items = targets.map((t, i) => {
          const tag = document.createElement('span');
          tag.textContent = names[i];
          tag.style.left = Math.max(0, t.r.left) + 'px';
          tag.style.top = Math.max(0, t.r.top) + 'px';
          root.appendChild(tag);
          return { ...t, label: names[i], tag };
        });
        document.documentElement.appendChild(host);
        return items.length;
      }

      function filter({ typed }) {
        let matches = 0, hit = null;
        for (const item of items) {
          const on = item.label.startsWith(typed);
          item.tag.hidden = !on;
          if (!on) continue;
          matches++;
          item.tag.innerHTML = `<b>${typed}</b>${item.label.slice(typed.length)}`;
          if (item.label === typed) hit = item;
        }
        if (!hit) return { matches };
        picked = hit.el;
        hide();
        const r = picked.getBoundingClientRect();
        return { matches, hit: { href: picked.closest('a[href]')?.href ?? null,
          x: r.left + Math.min(r.width / 2, 12), y: r.top + r.height / 2 } };
      }

      function click() {
        if (!picked) return false;
        picked.focus?.();
        picked.click();
        return true;
      }

      function hide() {
        host?.remove();
        host = null;
        items = [];
      }

      return { show, filter, click, hide };
    })()
    """#
}
