import AppKit
import WebKit

/// Console and network history for agents. While the API runs, a small page-world script reports
/// console calls, uncaught errors and fetch/XHR requests; each tab keeps the last 500 of each.
/// Nothing is installed while the API is off, so normal browsing pays nothing for it.
@MainActor
final class AgentMonitor: NSObject, WKScriptMessageHandler {
    static let shared = AgentMonitor()
    static let handlerName = "ternMonitor"

    private var installed = false
    private lazy var userScript = WKUserScript(source: Self.source, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page)

    private var controller: WKUserContentController { BrowserEngine.shared.webViewConfiguration.userContentController }

    /// Pages loaded from now on report to us; already open pages start after their next load.
    func install() {
        guard !installed else { return }
        installed = true
        controller.addUserScript(userScript)
        controller.add(self, contentWorld: .page, name: Self.handlerName)
    }

    func uninstall() {
        guard installed else { return }
        installed = false
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        let others = controller.userScripts.filter { $0 !== userScript }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let webView = message.webView,
              let tab = AppDelegate.shared.allTabs.first(where: { $0.webView === webView })
        else { return }
        var entry = body
        entry.removeValue(forKey: "kind")
        entry["page"] = tab.currentURL?.absoluteString ?? NSNull()
        switch kind {
        case "console":
            let stored = tab.agentLog.append(.console, entry)
            AgentServer.shared.broadcast("console.message", stored.merging(["tabId": tab.id.uuidString]) { a, _ in a })
        case "network":
            let stored = tab.agentLog.append(.network, entry)
            AgentServer.shared.broadcast("network.request", stored.merging(["tabId": tab.id.uuidString]) { a, _ in a })
        default:
            break
        }
    }

    /// Wraps the page's own console, fetch and XHR. Runs before any page script.
    private static let source = #"""
    (() => {
      if (window.__ternMonitor) return;
      Object.defineProperty(window, '__ternMonitor', { value: true });
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ternMonitor;
      if (!handler) return;
      const post = (m) => { try { handler.postMessage(m); } catch (_) {} };
      const now = () => Math.round(performance.now());
      const fmt = (v) => {
        if (typeof v === 'string') return v;
        if (v instanceof Error) return v.stack ? `${v}\n${v.stack}` : String(v);
        try { const s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (_) { return String(v); }
      };
      const absolute = (u) => { try { return new URL(u, location.href).href; } catch (_) { return String(u); } };

      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) {
          post({ kind: 'console', level, text: args.map(fmt).join(' ').slice(0, 10000), source: 'console' });
          return original.apply(this, args);
        };
      }
      addEventListener('error', (e) => {
        if (!(e instanceof ErrorEvent)) return; // resource load errors carry no message
        const where = e.filename ? ` (${e.filename}:${e.lineno}:${e.colno})` : '';
        post({ kind: 'console', level: 'error', text: (e.message || 'Error') + where, source: 'exception' });
      });
      addEventListener('unhandledrejection', (e) => {
        post({ kind: 'console', level: 'error', text: 'Unhandled rejection: ' + fmt(e.reason), source: 'exception' });
      });

      const fetch = window.fetch;
      if (fetch) window.fetch = function (input, init) {
        const started = now();
        const isRequest = typeof Request !== 'undefined' && input instanceof Request;
        const method = String((init && init.method) || (isRequest ? input.method : 'GET')).toUpperCase();
        const url = absolute(isRequest ? input.url : input);
        const promise = fetch.apply(this, arguments);
        promise.then(
          (r) => post({ kind: 'network', type: 'fetch', method, url, status: r.status, ok: r.ok, durationMs: now() - started }),
          (e) => post({ kind: 'network', type: 'fetch', method, url, status: 0, ok: false, error: String(e), durationMs: now() - started }));
        return promise;
      };

      const requests = new WeakMap();
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        requests.set(this, { method: String(method).toUpperCase(), url: absolute(url) });
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const info = requests.get(this);
        if (info) {
          const started = now();
          this.addEventListener('loadend', () => {
            const failed = this.status === 0;
            post({ kind: 'network', type: 'xhr', method: info.method, url: info.url, status: this.status,
                   ok: this.status >= 200 && this.status < 300, error: failed ? 'request failed' : null,
                   durationMs: now() - started });
          }, { once: true });
        }
        return send.apply(this, arguments);
      };
    })();
    """#
}

/// The last 500 console messages and network requests of one tab. Every entry gets a sequence
/// number, so a reader can ask for "everything after the last one I saw".
@MainActor
final class AgentTabLog {
    static let capacity = 500

    enum Kind { case console, network }

    private(set) var console: [[String: Any]] = []
    private(set) var network: [[String: Any]] = []
    private var nextSeq = 1

    func entries(_ kind: Kind) -> [[String: Any]] { kind == .console ? console : network }

    func clear(_ kind: Kind) {
        if kind == .console { console.removeAll() } else { network.removeAll() }
    }

    @discardableResult
    func append(_ kind: Kind, _ entry: [String: Any]) -> [String: Any] {
        var stored = entry
        stored["seq"] = nextSeq
        stored["time"] = Date().timeIntervalSince1970 * 1000
        nextSeq += 1
        switch kind {
        case .console:
            console.append(stored)
            if console.count > Self.capacity { console.removeFirst() }
        case .network:
            network.append(stored)
            if network.count > Self.capacity { network.removeFirst() }
        }
        return stored
    }
}
