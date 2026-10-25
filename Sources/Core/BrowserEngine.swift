import AppKit
import WebKit

/// Process-wide WebKit state: one data store, one extension controller, one base configuration.
/// Every tab's WKWebView shares these, so WebKit can reuse web content processes and caches.
@MainActor
final class BrowserEngine {
    static let shared = BrowserEngine()

    let dataStore = WKWebsiteDataStore.default()
    let extensionController: WKWebExtensionController

    /// Search used when the address bar input isn't a URL. `%s` is replaced with the query.
    var searchTemplate: String { Preferences.searchTemplate }

    private init() {
        let config = WKWebExtensionController.Configuration.default()
        config.defaultWebsiteDataStore = dataStore
        extensionController = WKWebExtensionController(configuration: config)
    }

    /// Base configuration for page tabs. WKWebView copies it at init, so sharing one instance is safe.
    lazy var webViewConfiguration: WKWebViewConfiguration = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.webExtensionController = extensionController
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.allowsAirPlayForMediaPlayback = true
        c.suppressesIncrementalRendering = false
        // Without a Safari-like suffix, some sites (Google, Slack) serve degraded pages to WKWebView.
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Turns on the "Inspect Element" context menu item for every page.
        c.preferences.setValue(true, forKey: "developerExtrasEnabled")
        c.userContentController.addUserScript(JSONViewer.userScript)
        PasswordManager.shared.install(in: c.userContentController)
        return c
    }()

    /// Extension pages (options, popups opened in tabs) must use the extension's own configuration.
    func configuration(for url: URL?) -> WKWebViewConfiguration {
        if let url, url.scheme == "webkit-extension",
           let ctx = extensionController.extensionContext(for: url),
           let config = ctx.webViewConfiguration {
            return config
        }
        return webViewConfiguration
    }

    func resolve(input raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = Bangs.url(for: input) { return url }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data", "webkit-extension"].contains(scheme) {
            return url
        }
        let looksLikeHost = !input.contains(" ") && (
            input.contains(".") || input.hasPrefix("localhost") || input.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?"#, options: .regularExpression) != nil
        )
        if looksLikeHost {
            let isLocal = input.hasPrefix("localhost") || input.hasPrefix("127.") || input.hasPrefix("0.0.0.0") || input.contains(".local") || input.contains(".test")
            return URL(string: (isLocal ? "http://" : "https://") + input)
        }
        let q = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }
}

/// Small in-memory favicon cache keyed by host, so tabs on the same site share one image.
@MainActor
enum FaviconLoader {
    private static let cache = NSCache<NSString, NSImage>()
    private static let script = """
    (() => { const l = document.querySelector('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
      return l ? l.href : new URL('/favicon.ico', location.href).href })()
    """

    static func cached(for url: URL?) -> NSImage? {
        guard let host = url?.host else { return nil }
        return cache.object(forKey: host as NSString)
    }

    static func load(for webView: WKWebView, completion: @escaping (NSImage) -> Void) {
        guard let host = webView.url?.host else { return }
        if let img = cache.object(forKey: host as NSString) { completion(img); return }
        webView.evaluateJavaScript(script) { result, _ in
            guard let s = result as? String, let iconURL = URL(string: s) else { return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: iconURL),
                      let image = NSImage(data: data) else { return }
                image.size = NSSize(width: 16, height: 16)
                cache.setObject(image, forKey: host as NSString)
                completion(image)
            }
        }
    }
}
