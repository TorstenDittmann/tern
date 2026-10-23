import AppKit
import WebKit

// What `browser.tabs.*` and `browser.windows.*` see. WebKit calls these lazily, so they stay cheap.

extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner?.tabs.firstIndex(of: self) ?? NSNotFound
    }

    /// Suspended tabs have no web view; extensions treat them like Chrome's discarded tabs.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { pageTitle }
    func url(for context: WKWebExtensionContext) -> URL? { currentURL }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { isActive }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let wv = materialize()
        if fromOrigin { wv.reloadFromOrigin() } else { wv.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        materialize().goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        materialize().goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.activate(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.close(self)
        completionHandler(nil)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let owner else { return completionHandler(nil, nil) }
        let copy = Tab(url: currentURL, title: pageTitle, interactionState: interactionStateData)
        owner.insert(copy, after: self, activate: configuration.shouldBeActive)
        completionHandler(copy, nil)
    }

    /// Backs `tabs.captureVisibleTab`.
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        guard let webView else { return completionHandler(nil, nil) }
        webView.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }
}

extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
                        completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window else { return completionHandler(nil) }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .maximized: if !window.isZoomed { window.zoom(nil) }
        default:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        completionHandler(nil)
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.close()
        completionHandler(nil)
    }
}
