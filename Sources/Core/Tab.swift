import AppKit
import WebKit

/// A tab owns its WKWebView lazily. Restored and background tabs hold only a URL, a title and
/// WebKit's opaque `interactionState` (back/forward list + scroll), so 200 restored tabs cost ~nothing
/// until they're opened. `suspend()` drops the web view again and keeps the state.
@MainActor
final class Tab: NSObject {
    let id: UUID
    weak var owner: BrowserWindowController?

    private(set) var webView: WKWebView?
    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// Bumped whenever a navigation finishes or fails, so callers can wait for "this load".
    private(set) var loadsEnded = 0
    var lastActivated = Date()
    /// Console and network history for the agent API (filled only while it runs).
    lazy var agentLog = AgentTabLog()
    /// An agent acted on this tab in the last few seconds; the UI rings it.
    var isAgentDriving = false

    private var pendingState: Any?
    private var observations: [NSKeyValueObservation] = []

    var isSuspended: Bool { webView == nil }
    var isActive: Bool { owner?.activeTab === self }
    /// On screen: the active tab, or the other half of its split. Never suspended.
    var isVisible: Bool { owner?.visibleTabs.contains(self) ?? false }

    var displayTitle: String {
        if let t = pageTitle, !t.isEmpty { return t }
        return currentURL?.host ?? currentURL?.absoluteString ?? "New Tab"
    }

    /// Serializable back/forward state for session restore.
    var interactionStateData: Data? { (webView?.interactionState ?? pendingState) as? Data }

    init(url: URL?, title: String? = nil, interactionState: Data? = nil, id: UUID = UUID()) {
        self.id = id
        self.currentURL = url
        self.pageTitle = title
        self.pendingState = interactionState
        self.favicon = FaviconLoader.cached(for: url)
        super.init()
    }

    /// Wraps a web view WebKit created for `window.open` / `target=_blank`.
    init(adopting webView: WKWebView, url: URL?) {
        self.id = UUID()
        self.currentURL = url
        super.init()
        attach(webView)
    }

    @discardableResult
    func materialize() -> WKWebView {
        if let webView { return webView }
        let wv = TernWebView(frame: .zero, configuration: BrowserEngine.shared.configuration(for: currentURL))
        attach(wv)
        if let state = pendingState {
            wv.interactionState = state
            pendingState = nil
        } else if let currentURL {
            wv.load(URLRequest(url: currentURL))
        } else {
            wv.loadHTMLString(StartPage.html, baseURL: nil)
        }
        return wv
    }

    func load(_ url: URL) {
        currentURL = url
        pendingState = nil
        if let webView { webView.load(URLRequest(url: url)) }
        changed([.URL])
    }

    /// Releases the web view (and with it the page's memory) while keeping history.
    func suspend() {
        guard let wv = webView, !isVisible else { return }
        pendingState = wv.interactionState
        observations.removeAll()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.stopLoading()
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        owner?.tabDidChange(self)
    }

    /// Tears the tab down for good (tab closed or window closing).
    func discard() {
        observations.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        owner = nil
    }

    /// Suspends unless the page is doing something the user would notice (audio, camera, mic).
    func suspendIfIdle() {
        guard let wv = webView, !isVisible,
              wv.cameraCaptureState == .none, wv.microphoneCaptureState == .none else { return }
        wv.requestMediaPlaybackState { [weak self] state in
            if state != .playing { self?.suspend() }
        }
    }

    private func attach(_ wv: WKWebView) {
        wv.isInspectable = true
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        (wv as? TernWebView)?.onFocus = { [weak self] in
            guard let self else { return }
            self.owner?.paneDidFocus(self)
        }
        observations = [
            wv.observe(\.title) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.pageTitle = wv.title; self?.changed([.title]) }
            },
            wv.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = wv.url else { return }
                    if url.host != self.currentURL?.host { self.favicon = FaviconLoader.cached(for: url) }
                    // The start page is about:blank; keep the address bar empty for it.
                    self.currentURL = url.absoluteString == "about:blank" ? nil : url
                    self.changed([.URL])
                }
            },
            wv.observe(\.isLoading) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading; self?.changed([.loading]) }
            },
            wv.observe(\.estimatedProgress) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = wv.estimatedProgress
                    if self.isVisible { self.owner?.content.update(for: self) }
                }
            },
        ]
        webView = wv
    }

    private func changed(_ props: WKWebExtension.TabChangedProperties) {
        owner?.tabDidChange(self)
        AgentServer.shared.tabDidChange(self)
        if owner != nil {
            BrowserEngine.shared.extensionController.didChangeTabProperties(props, for: self)
        }
    }
}

/// Tells its tab when the user clicks into it, so split-view focus follows the mouse.
final class TernWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    private static let inAppSchemes: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript", "webkit-extension"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }

        // mailto:, vscode://, zoommtg:// … go to the system.
        if let scheme = url.scheme?.lowercased(), !Self.inAppSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        // ⌘-click / middle-click opens a background tab (⇧ to bring it to front).
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 4 {
            owner?.newTab(url: url, activate: action.modifierFlags.contains(.shift), after: self)
            return decisionHandler(.cancel)
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadsEnded += 1
        Metrics.markPageLoaded()
        FaviconLoader.load(for: webView) { [weak self] image in
            self?.favicon = image
            if let self { self.owner?.tabDidChange(self) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadsEnded += 1
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadsEnded += 1
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Crashed or jetsammed content process: reload lazily when the user looks at the tab.
        if isVisible { webView.reload() } else { suspend() }
    }
}

// MARK: - UI (popups, dialogs, file pickers)

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let wv = TernWebView(frame: .zero, configuration: configuration)
        let tab = Tab(adopting: wv, url: action.request.url)
        owner?.insert(tab, after: self, activate: true)
        return wv
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = owner?.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = owner?.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

// MARK: - Downloads

@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Makes the Downloads stack in the Dock bounce, like Safari.
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Tern download failed: \(error.localizedDescription)")
    }
}
