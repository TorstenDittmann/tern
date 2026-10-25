import AppKit
import WebKit

/// Reader (⌥⌘R): the page's article, without the rest of the page, set in a calm column over the tab.
/// The article is found by a small Readability-style scorer run in its own content world; the reader
/// view shows a copy with JavaScript off. Links open in the tab, and the reader closes once the tab
/// navigates away.
@MainActor
enum Reader {
    struct Article {
        let title: String
        let byline: String
        let site: String
        let html: String
        let words: Int
    }

    static let world = WKContentWorld.world(name: "tern-reader")

    static func extract(from webView: WKWebView) async -> Article? {
        let value: Any? = await withCheckedContinuation { done in
            webView.evaluateJavaScript(script, in: nil, in: world) { done.resume(returning: try? $0.get()) }
        }
        guard let result = value as? [String: Any], let html = result["html"] as? String else { return nil }
        return Article(title: result["title"] as? String ?? "", byline: result["byline"] as? String ?? "",
                       site: result["site"] as? String ?? "", html: html, words: result["words"] as? Int ?? 0)
    }

    /// Scores blocks by the paragraph text they hold, less their link text, and takes the best one.
    static let script = #"""
    (() => {
      const doc = document.cloneNode(true);
      doc.querySelectorAll("img[data-src], img[data-lazy-src]").forEach(i => i.setAttribute("src", i.dataset.src || i.dataset.lazySrc));
      doc.querySelectorAll("script, style, noscript, iframe, form, nav, header, footer, aside, button, input, select, textarea, svg, canvas, dialog, template, link, meta, [role=navigation], [role=banner], [role=complementary], [role=dialog], [aria-hidden=true], [hidden]").forEach(e => e.remove());
      const unlikely = /comment|sidebar|footer|promo|related|share|social|newsletter|subscribe|advert|sponsor|cookie|banner|popup|modal|breadcrumb|menu/i;
      let best = null, bestScore = 0;
      doc.querySelectorAll("article, main, [role=main], section, div, td").forEach(el => {
        let text = 0;
        el.querySelectorAll(":scope > p, :scope > div > p, :scope > pre, :scope > blockquote, :scope > ul, :scope > ol, :scope > h2, :scope > h3, :scope > figure, :scope > table")
          .forEach(p => { text += p.textContent.trim().length; });
        if (text < 200) return;
        const total = el.textContent.length || 1;
        let links = 0;
        el.querySelectorAll("a").forEach(a => { links += a.textContent.length; });
        let score = text * (1 - Math.min(links / total, 0.9));
        if (el.tagName === "ARTICLE" || el.tagName === "MAIN" || el.getAttribute("role") === "main") score *= 1.4;
        if (unlikely.test((el.className || "") + " " + (el.id || ""))) score *= 0.2;
        if (score > bestScore) { bestScore = score; best = el; }
      });
      if (!best || bestScore < 500) return null;
      best.querySelectorAll("*").forEach(e => {
        if (e.tagName !== "PRE" && unlikely.test((e.className || "") + " " + (e.id || "")) && e.textContent.length < 400) { e.remove(); return; }
        for (const a of [...e.attributes]) {
          if (!["href", "src", "srcset", "alt", "title", "colspan", "rowspan", "lang", "dir"].includes(a.name)) e.removeAttribute(a.name);
        }
      });
      const meta = (sel) => document.querySelector(sel)?.getAttribute("content")?.trim() || "";
      const h1 = best.querySelector("h1");
      const title = meta('meta[property="og:title"]') || h1?.textContent.trim() || document.title.trim();
      if (h1 && h1.textContent.trim() === title) h1.remove();
      const words = best.textContent.trim().split(/\s+/).length;
      return { title, byline: meta('meta[name="author"]'), site: meta('meta[property="og:site_name"]') || location.hostname,
               html: best.innerHTML, words };
    })()
    """#

    static func html(for article: Article) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let minutes = max(1, Int((Double(article.words) / 230).rounded()))
        let meta = [article.site, article.byline, "\(minutes) min read"].filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(escape(article.title))</title>
        <style>
          :root { color-scheme: light dark; --fg: #1d1f22; --muted: #6b7078; --bg: #fbfaf7; --line: rgba(0,0,0,.1); --link: #2e8b4a; --code: rgba(0,0,0,.05); }
          @media (prefers-color-scheme: dark) { :root { --fg: #e4e2dd; --muted: #8f939a; --bg: #15171a; --line: #2a2d32; --link: #9be8a6; --code: rgba(255,255,255,.06); } }
          html { background: var(--bg); color: var(--fg); }
          body { max-width: 680px; margin: 0 auto; padding: 56px 28px 96px; font: 19px/1.65 ui-serif, "New York", Georgia, serif; }
          header { margin-bottom: 36px; padding-bottom: 20px; border-bottom: 1px solid var(--line); }
          .meta { font: 13px -apple-system, system-ui, sans-serif; color: var(--muted); letter-spacing: .01em; }
          h1 { font-size: 2em; line-height: 1.2; margin: .3em 0 0; letter-spacing: -.01em; }
          h2, h3, h4 { line-height: 1.3; margin: 1.6em 0 .5em; }
          a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
          img, video, figure { max-width: 100%; height: auto; } figure { margin: 1.6em 0; }
          figcaption { font: 13px -apple-system, system-ui, sans-serif; color: var(--muted); margin-top: .5em; }
          blockquote { margin: 1.4em 0; padding-left: 1.1em; border-left: 3px solid var(--line); color: var(--muted); }
          pre, code { font: 14px/1.5 ui-monospace, "SF Mono", Menlo, monospace; background: var(--code); border-radius: 6px; }
          code { padding: .1em .3em; } pre { padding: 14px 16px; overflow-x: auto; } pre code { background: none; padding: 0; }
          table { border-collapse: collapse; font-size: .85em; } td, th { border: 1px solid var(--line); padding: 6px 10px; }
          hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
        </style></head><body>
        <header><div class="meta">\(meta)</div><h1>\(escape(article.title))</h1></header>
        <article>\(article.html)</article>
        </body></html>
        """
    }
}

/// The reader's page: a separate web view over the tab's page, with JavaScript off.
final class ReaderView: NSView, WKNavigationDelegate {
    /// The page the article came from; the reader closes once the tab is somewhere else.
    let source: URL
    let article: Reader.Article
    let webView: WKWebView
    var onOpenLink: ((URL, _ newTab: Bool) -> Void)?

    init(article: Reader.Article, source: URL) {
        self.source = source
        self.article = article
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
        // The base URL lets relative image and link URLs resolve against the article's page.
        webView.loadHTMLString(Reader.html(for: article), baseURL: source)
    }
    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        // In-page anchors scroll the reader; everything else goes back to the tab.
        if url.fragment != nil, url.absoluteString.hasPrefix(source.absoluteString.components(separatedBy: "#")[0] + "#") {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        onOpenLink?(url, action.modifierFlags.contains(.command) || action.buttonNumber == 4)
    }
}
