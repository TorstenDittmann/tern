import AppKit
import WebKit

/// A tab owns its WKWebView lazily. Restored and background tabs hold only a URL, a title and
/// WebKit's opaque `interactionState` (back/forward list + scroll), so 200 restored tabs cost ~nothing
/// until they're opened. `suspend()` drops the web view again and keeps the state.
@MainActor
final class Tab: NSObject {
    let id: UUID
    weak var owner: BrowserWindowController?
    /// For a tab that has no owner yet (a link peek): the window whose data store it uses.
    weak var homeWindow: BrowserWindowController?

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
    /// Pinned tabs stay at the top of the list, in their own block, and survive "Close Other Tabs".
    var isPinned = false
    /// Where a pinned tab belongs. ⌘W on a pinned tab that wandered off takes it back here.
    var pinnedURL: URL?
    /// A pinned tab is somewhere other than its pinned page.
    var hasLeftPinnedURL: Bool {
        guard isPinned, let pinnedURL, let currentURL else { return false }
        return currentURL.absoluteString != pinnedURL.absoluteString
    }
    /// Muted tabs stay muted when they're suspended and restored.
    var isMuted = false {
        didSet { guard isMuted != oldValue else { return }; applyMute(); owner?.tabDidChange(self) }
    }
    /// Responsive design mode: the device this tab's page is laid out as, or nil.
    var devicePreview: DevicePreview? {
        didSet {
            guard devicePreview != oldValue else { return }
            if let preview = devicePreview { DevicePreview.lastPreset = preview.preset }
            if let webView { DeviceEmulation.apply(devicePreview, to: webView) }
            owner?.tabDidChange(self)
        }
    }
    /// The page is playing sound right now (muted or not).
    private(set) var isPlayingAudio = false
    private weak var audioObserved: WKWebView?

    private var pendingState: Any?
    /// Where tracking parameters were last removed on the way to, until that load finishes, so a
    /// redirect back to the tracked URL can't loop.
    private var lastStripped: URL?
    private var observations: [NSKeyValueObservation] = []

    var isSuspended: Bool { webView == nil }
    /// In a private window: no history, and a data store that's thrown away with the window.
    var isPrivate: Bool { (owner ?? homeWindow)?.isPrivate ?? false }
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
        let wv = TernWebView(frame: .zero, configuration: (owner ?? homeWindow)?.webViewConfiguration(for: currentURL)
            ?? BrowserEngine.shared.configuration(for: currentURL))
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
        stopObservingAudio()
        isPlayingAudio = false
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
        stopObservingAudio()
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
        // Swipes go back and forward at once, without Safari's page slide.
        SwipeNavigator.configure(wv)
        wv.allowsMagnification = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        (wv as? TernWebView)?.onFocus = { [weak self] in
            guard let self else { return }
            self.owner?.paneDidFocus(self)
        }
        observations = [
            wv.observe(\.title) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.pageTitle = wv.title
                    self?.changed([.title])
                    if self?.isPrivate == false { HistoryStore.shared.updateTitle(wv.title, for: wv.url) }
                }
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
        observeAudio(wv)
        if isMuted { applyMute() }
        if devicePreview != nil { DeviceEmulation.apply(devicePreview, to: wv) }
    }

    // MARK: Sound

    // WebKit's public API can pause media but not mute it, or say whether a page is playing sound.
    // `_setPageMuted:` and `_isPlayingAudio` are SPI that Safari uses; both are checked for first.
    private nonisolated static let isPlayingAudioKey = "_isPlayingAudio"

    private func observeAudio(_ wv: WKWebView) {
        guard wv.responds(to: NSSelectorFromString(Self.isPlayingAudioKey)) else { return }
        wv.addObserver(self, forKeyPath: Self.isPlayingAudioKey, options: [.initial, .new], context: nil)
        audioObserved = wv
    }

    private func stopObservingAudio() {
        audioObserved?.removeObserver(self, forKeyPath: Self.isPlayingAudioKey)
        audioObserved = nil
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.isPlayingAudioKey else { return }
        let playing = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isPlayingAudio != playing else { return }
                self.isPlayingAudio = playing
                self.owner?.tabDidChange(self)
            }
        }
    }

    private func applyMute() {
        guard let wv = webView else { return }
        let sel = NSSelectorFromString("_setPageMuted:")
        guard let method = class_getInstanceMethod(type(of: wv), sel) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        // _WKMediaMutedState: 1 mutes audio; camera and microphone are left alone.
        unsafeBitCast(method_getImplementation(method), to: SetMuted.self)(wv, sel, isMuted ? 1 : 0)
    }

    private func changed(_ props: WKWebExtension.TabChangedProperties) {
        owner?.tabDidChange(self)
        AgentServer.shared.tabDidChange(self)
        if let owner, !owner.isPrivate {
            BrowserEngine.shared.extensionController.didChangeTabProperties(props, for: self)
        }
    }
}

/// Tells its tab when the user clicks into it, so split-view focus follows the mouse, and turns
/// two-finger swipes into instant back/forward.
final class TernWebView: WKWebView {
    var onFocus: (() -> Void)?
    lazy var swipe = SwipeNavigator(webView: self)

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        swipe.scrollWheel(event)
        super.scrollWheel(with: event)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    private static let inAppSchemes: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript", "webkit-extension"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let decide = { (policy: WKNavigationActionPolicy) in decisionHandler(policy, preferences) }
        guard let url = action.request.url else { return decide(.allow) }

        // mailto:, vscode://, zoommtg:// … go to the system.
        if let scheme = url.scheme?.lowercased(), !Self.inAppSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return decide(.cancel)
        }
        // ⌥-click peeks at a link without leaving the page (Safari would download it).
        if action.navigationType == .linkActivated, owner != nil,
           action.modifierFlags.intersection([.command, .shift, .option, .control]) == .option,
           HistoryStore.isRecordable(url), let browser = owner {
            browser.content.peek(url, from: self)
            return decide(.cancel)
        }
        // ⌘-click / middle-click opens a background tab (⇧ to bring it to front).
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 4 {
            owner?.newTab(url: url, activate: action.modifierFlags.contains(.shift), after: self)
            return decide(.cancel)
        }
        if action.targetFrame?.isMainFrame == true {
            let blocking = ContentBlocker.shared.isEnabled(for: url)
            ContentBlocker.apply(blocking, to: preferences)
            // Links and typed addresses lose their click IDs before they load. Back/forward and
            // form posts are left as they are.
            if blocking, action.navigationType == .linkActivated || action.navigationType == .other,
               action.request.httpMethod ?? "GET" == "GET", action.request.httpBody == nil,
               let clean = TrackingParameters.strip(url), clean != lastStripped {
                // A server that redirects back to the tracked URL gets it on the second round, not a loop.
                lastStripped = clean
                decide(.cancel)
                webView.load(URLRequest(url: clean))
                return
            }
        }
        decide(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadsEnded += 1
        lastStripped = nil
        Metrics.markPageLoaded()
        if let url = webView.url, !isPrivate { HistoryStore.shared.recordVisit(url, title: webView.title) }
        FaviconLoader.load(for: webView) { [weak self] image in
            self?.favicon = image
            if let self { self.owner?.tabDidChange(self) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadsEnded += 1
        clearStrippedUnlessCancelled(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadsEnded += 1
        clearStrippedUnlessCancelled(error)
    }

    /// A load that really failed (offline, bad host) ends the redirect guard; the cancel that
    /// strips the tracked URL, or a new load taking over, doesn't.
    private func clearStrippedUnlessCancelled(_ error: Error) {
        let e = error as NSError
        let cancelled = (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102)
        if !cancelled { lastStripped = nil }
    }

    /// HTTP basic and digest auth get a sign-in sheet; certificates and everything else, WebKit's default.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) else {
            return completionHandler(.performDefaultHandling, nil)
        }
        AuthPrompt.ask(challenge, in: owner?.window) { credential in
            // Cancel shows the server's own 401 page, like Safari.
            completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
        }
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

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        SitePermissions.ask(.init(type), origin: SitePermissions.origin(origin), in: owner?.window, isPrivate: isPrivate) { decisionHandler($0 ? .grant : .deny) }
    }

    // Geolocation has no public delegate method on macOS; these are the WKUIDelegatePrivate ones
    // (the newer one first). Without them WebKit denies every request.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func requestGeolocationPermission(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        SitePermissions.ask(.location, origin: SitePermissions.origin(origin), in: owner?.window, isPrivate: isPrivate) { decisionHandler($0 ? .grant : .deny) }
    }

    @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
    func requestGeolocationPermission(_ webView: WKWebView, frame: WKFrameInfo, decisionHandler: @escaping (Bool) -> Void) {
        SitePermissions.ask(.location, origin: SitePermissions.origin(frame.securityOrigin), in: owner?.window, isPrivate: isPrivate, completion: decisionHandler)
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = owner?.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}
