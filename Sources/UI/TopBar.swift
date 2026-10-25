import AppKit
import WebKit

/// The bar above the page: sidebar toggle, back, forward, reload, an address pill that takes
/// the rest of the width, and a split view button. It lines up with the traffic lights, and makes room for them when the
/// sidebar is hidden or on the right.
@MainActor
final class TopBar: NSView {
    static let height: CGFloat = 26
    /// Window top to page top before the traffic lights have been measured: the same 3pt above and below the bar.
    static let defaultContentTop: CGFloat = 32

    weak var browser: BrowserWindowController?

    let pill = AddressPill()
    var field: AddressField { pill.field }
    /// What was typed before the last change, to complete only while typing forward.
    var lastTypedAddress = ""
    private lazy var sidebarLeft = HoverButton(symbol: "sidebar.left", label: "Toggle Sidebar", target: self, action: #selector(sidebarClicked))
    private lazy var sidebarRight = HoverButton(symbol: "sidebar.right", label: "Toggle Sidebar", target: self, action: #selector(sidebarClicked))
    private lazy var backButton = HoverButton(symbol: "chevron.backward", label: "Back", target: self, action: #selector(backClicked))
    private lazy var forwardButton = HoverButton(symbol: "chevron.forward", label: "Forward", target: self, action: #selector(forwardClicked))
    private lazy var reloadButton = HoverButton(symbol: "arrow.clockwise", label: "Reload", target: self, action: #selector(reloadClicked))
    private(set) lazy var splitButton = HoverButton(symbol: "rectangle.split.2x1", label: "Split View", target: self, action: #selector(splitClicked))
    /// Shown once something has been downloaded this session; lit while a download runs.
    private(set) lazy var downloadsButton = HoverButton(symbol: "arrow.down.circle", label: "Downloads", target: self, action: #selector(downloadsClicked))

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.delegate = self
        pill.onStar = { [weak self] in
            guard let tab = self?.browser?.activeTab else { return }
            BookmarkStore.shared.toggle(tab.currentURL, title: tab.pageTitle)
        }
        pill.onSite = { [weak self] in self?.showSiteInfo() }
        pill.onBreakdown = { [weak self] in self?.showURLBreakdown() }
        NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateChrome() }
        }
        NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDownloadsButton() }
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [sidebarLeft, backButton, forwardButton, reloadButton, pill, downloadsButton, splitButton, sidebarRight])
        stack.spacing = 2
        stack.setCustomSpacing(8, after: reloadButton)
        stack.setCustomSpacing(8, after: pill)
        stack.setCustomSpacing(4, after: downloadsButton)
        stack.setCustomSpacing(4, after: splitButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setSidebarSide(right: false)
        updateDownloadsButton()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateDownloadsButton() {
        let manager = DownloadManager.shared
        downloadsButton.isHidden = manager.items.isEmpty
        let running = manager.runningCount
        downloadsButton.contentTintColor = running > 0 ? Theme.accent : .secondaryLabelColor
        downloadsButton.image = Theme.symbol(running > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        let keys = Keymap.shared.primaryChord(for: .showDownloads).map { " (\($0))" } ?? ""
        downloadsButton.toolTip = (running > 0 ? "Downloads: \(running) in progress" : "Downloads") + keys
    }

    /// The downloads popover, from the downloads button (or the address bar while the button is hidden).
    func showDownloads() {
        if popover?.contentViewController is DownloadsController, popover?.isShown == true { popover?.close(); return }
        let controller = DownloadsController()
        controller.browser = browser
        present(controller, from: downloadsButton.isHidden ? pill : downloadsButton)
    }

    /// The toggle sits on the sidebar's side.
    func setSidebarSide(right: Bool) {
        sidebarLeft.isHidden = right
        sidebarRight.isHidden = !right
    }

    func focusAddressField() { window?.makeFirstResponder(field) }

    func updateChrome() {
        let tab = browser?.activeTab
        pill.show(url: tab?.currentURL, bookmarked: BookmarkStore.shared.contains(tab?.currentURL))
        backButton.isEnabled = tab?.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab?.webView?.canGoForward ?? false
        let loading = tab?.isLoading == true
        reloadButton.image = Theme.symbol(loading ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = loading ? "Stop" : "Reload"
        // Lit while the page is split.
        let split = (browser?.visibleTabs.count ?? 1) > 1
        splitButton.contentTintColor = split ? Theme.accent : .secondaryLabelColor
        let keys = Keymap.shared.primaryChord(for: .toggleSplit).map { " (\($0))" } ?? ""
        splitButton.toolTip = (split ? "End Split View" : "Split View") + keys
    }

    /// The lock's popover: whether the connection is encrypted, and the certificate chain.
    func showSiteInfo() {
        guard let tab = browser?.activeTab, let url = tab.currentURL else { return }
        let info = SiteInfoController(url: url, trust: tab.webView?.serverTrust, secureContentOnly: tab.webView?.hasOnlySecureContent ?? false)
        present(info, from: pill.siteButton)
    }

    /// The URL breakdown: scheme, host, port, path, query parameters and fragment, editable.
    func showURLBreakdown() {
        guard let tab = browser?.activeTab, let url = tab.currentURL else { return }
        let breakdown = URLBreakdownController(url: url)
        breakdown.onOpen = { [weak self] url, newTab in
            self?.popover?.close()
            self?.browser?.open(input: url.absoluteString, inNewTab: newTab)
        }
        present(breakdown, from: pill.breakdownButton.isHidden ? pill : pill.breakdownButton)
    }

    private(set) var popover: NSPopover?

    private func present(_ controller: NSViewController, from view: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        self.popover = popover
    }

    @objc private func sidebarClicked() { browser?.toggleSidebar() }
    @objc private func downloadsClicked() { showDownloads() }
    @objc private func splitClicked() { browser.map { CommandRouter.perform(.toggleSplit, in: $0) } }
    @objc private func backClicked() { browser?.activeTab?.webView?.goBack() }
    @objc private func forwardClicked() { browser?.activeTab?.webView?.goForward() }
    @objc private func reloadClicked() {
        guard let wv = browser?.activeTab?.webView else { return }
        if wv.isLoading { wv.stopLoading() } else { wv.reload() }
    }
}

extension TopBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            browser?.open(input: field.stringValue, inNewTab: newTab)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(browser?.activeTab?.webView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let url = browser?.activeTab?.currentURL
        pill.show(url: url, bookmarked: BookmarkStore.shared.contains(url))
    }

    func controlTextDidBeginEditing(_ obj: Notification) { lastTypedAddress = "" }

    /// Inline completion from history, like Safari's: typing "gi" fills in "thub.com/", selected,
    /// so the next keystroke replaces it and ⌫ removes it.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === field, let editor = field.currentEditor() as? NSTextView else { return }
        let typed = field.stringValue
        let previous = lastTypedAddress
        lastTypedAddress = typed
        let length = (typed as NSString).length
        guard length > (previous as NSString).length, editor.selectedRange() == NSRange(location: length, length: 0),
              let completion = HistoryStore.shared.completion(for: typed),
              completion.lowercased().hasPrefix(typed.lowercased()) else { return }
        let full = typed + completion.dropFirst(typed.count)
        field.stringValue = full
        editor.setSelectedRange(NSRange(location: length, length: (full as NSString).length - length))
    }
}


/// Rounded field with the full URL, a site button (the lock) on the left that opens the connection
/// and certificate details, and a URL breakdown and bookmark star on the right.
final class AddressPill: FilledView {
    let field = AddressField()
    /// The star at the end of the pill: adds or removes the page as a bookmark (⌘D).
    var onStar: (() -> Void)?
    /// The lock (or globe) at the start of the pill.
    var onSite: (() -> Void)?
    var onBreakdown: (() -> Void)?
    private(set) lazy var siteButton = HoverButton(symbol: "lock.fill", size: 11, label: "Connection and Certificate", target: self, action: #selector(siteClicked))
    private(set) lazy var breakdownButton = HoverButton(symbol: "chevron.down", size: 10, label: "URL Breakdown (⌥⌘L)", target: self, action: #selector(breakdownClicked))
    private lazy var star = HoverButton(symbol: "star", size: 11, label: "Bookmark This Page (⌘D)", target: self, action: #selector(starClicked))
    private var url: URL?
    private var bookmarked = false

    init() {
        super.init(frame: .zero)
        fill = Theme.fieldFill
        border = Theme.hairline
        radius = 8

        siteButton.contentTintColor = .tertiaryLabelColor
        breakdownButton.contentTintColor = .tertiaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.monoFont(12.5)
        field.placeholderString = "Search or enter URL"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = false
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        let trailing = NSStackView(views: [breakdownButton, star])
        trailing.spacing = 0
        for v in [siteButton, field, trailing] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            siteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            siteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: siteButton.trailingAnchor),
            field.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(url: nil, bookmarked: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(url: URL?, bookmarked: Bool) {
        self.url = url
        self.bookmarked = bookmarked
        star.image = Theme.symbol(bookmarked ? "star.fill" : "star", size: 11)
        star.contentTintColor = bookmarked ? .systemYellow : .tertiaryLabelColor
        star.toolTip = bookmarked ? "Remove Bookmark (⌘D)" : "Bookmark This Page (⌘D)"
        updateButtons(editing: field.isEditing)
        guard !field.isEditing else { return }
        field.attributedStringValue = Theme.addressString(for: url, font: field.font ?? Theme.monoFont(12.5))
        field.toolTip = url?.absoluteString
        let secure = url?.scheme == "https"
        siteButton.image = Theme.symbol(url == nil ? "magnifyingglass" : (secure ? "lock.fill" : "globe"), size: 11, weight: .semibold)
        siteButton.toolTip = secure ? "Connection and Certificate" : (url == nil ? nil : "Connection Details")
    }

    private func updateButtons(editing: Bool) {
        star.isHidden = editing || !(url.map(HistoryStore.isRecordable) ?? false)
        breakdownButton.isHidden = editing || url?.host == nil
    }

    private func setFocused(_ focused: Bool) {
        fill = focused ? Theme.fieldFocusedFill : Theme.fieldFill
        border = focused ? Theme.accent : Theme.hairline
        if focused {
            field.stringValue = url?.absoluteString ?? ""
            siteButton.image = Theme.symbol("magnifyingglass", size: 11, weight: .semibold)
        }
        updateButtons(editing: focused)
    }

    @objc private func starClicked() { onStar?() }
    @objc private func siteClicked() { if !field.isEditing { onSite?() } }
    @objc private func breakdownClicked() { onBreakdown?() }

    // Clicking anywhere on the pill focuses the field.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

final class AddressField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        // Scroll while editing; truncate with an ellipsis otherwise.
        cell?.isScrollable = true
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            DispatchQueue.main.async { self.currentEditor()?.selectAll(nil) }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        cell?.isScrollable = false
        onFocusChange?(false)
    }
}

