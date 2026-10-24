import AppKit
import WebKit

/// The bar above the page: sidebar toggle, back, forward, reload, and an address pill that takes
/// the rest of the width. It lines up with the traffic lights, and makes room for them when the
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.delegate = self
        pill.onStar = { [weak self] in
            guard let tab = self?.browser?.activeTab else { return }
            BookmarkStore.shared.toggle(tab.currentURL, title: tab.pageTitle)
        }
        NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateChrome() }
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [sidebarLeft, backButton, forwardButton, reloadButton, pill, sidebarRight])
        stack.spacing = 2
        stack.setCustomSpacing(8, after: reloadButton)
        stack.setCustomSpacing(8, after: pill)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setSidebarSide(right: false)
    }
    required init?(coder: NSCoder) { fatalError() }

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
    }

    @objc private func sidebarClicked() { browser?.toggleSidebar() }
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


/// Rounded field that shows just the host ("github.com") and the full URL while editing.
final class AddressPill: FilledView {
    let field = AddressField()
    /// The star at the end of the pill: adds or removes the page as a bookmark (⌘D).
    var onStar: (() -> Void)?
    private let icon = NSImageView()
    private lazy var star = HoverButton(symbol: "star", size: 11, label: "Bookmark This Page (⌘D)", target: self, action: #selector(starClicked))
    private var url: URL?
    private var bookmarked = false

    init() {
        super.init(frame: .zero)
        fill = Theme.fieldFill
        border = Theme.hairline
        radius = 8

        icon.contentTintColor = .tertiaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.monoFont(12.5)
        field.placeholderString = "Search or enter URL"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        for v in [icon, field, star] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        star.isHidden = field.isEditing || !(url.map(HistoryStore.isRecordable) ?? false)
        guard !field.isEditing else { return }
        field.stringValue = Theme.displayString(for: url)
        field.toolTip = url?.absoluteString
        let secure = url?.scheme == "https"
        icon.image = Theme.symbol(url == nil ? "magnifyingglass" : (secure ? "lock.fill" : "globe"), size: 11, weight: .semibold)
    }

    private func setFocused(_ focused: Bool) {
        fill = focused ? Theme.fieldFocusedFill : Theme.fieldFill
        border = focused ? Theme.accent : Theme.hairline
        if focused {
            field.stringValue = url?.absoluteString ?? ""
            icon.image = Theme.symbol("magnifyingglass", size: 11, weight: .semibold)
        }
        star.isHidden = focused || !(url.map(HistoryStore.isRecordable) ?? false)
    }

    @objc private func starClicked() { onStar?() }

    // Clicking anywhere on the pill focuses the field.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

final class AddressField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            DispatchQueue.main.async { self.currentEditor()?.selectAll(nil) }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

