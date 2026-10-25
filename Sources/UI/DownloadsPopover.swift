import AppKit
import UniformTypeIdentifiers

/// The downloads button's popover: this session's downloads, newest first, with progress while they
/// run. Click a finished one to open it; the buttons cancel, retry or show it in Finder.
@MainActor
final class DownloadsController: NSViewController {
    weak var browser: BrowserWindowController?
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private var rows: [UUID: DownloadRow] = [:]
    private let empty = NSTextField(labelWithString: "No downloads yet")

    private static let width: CGFloat = 340
    private static let maxListHeight: CGFloat = 330

    override func loadView() {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        list.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)

        let title = NSTextField(labelWithAttributedString: Theme.sectionTitle("Downloads"))
        let folder = NSButton(title: "Show in Finder", target: self, action: #selector(showFolder))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearFinished))
        for b in [folder, clear] { b.bezelStyle = .accessoryBarAction; b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        let header = NSStackView(views: [title, NSView(), clear, folder])
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [header, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            scrollHeight,
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Rows are kept per download and updated in place, so progress ticks don't rebuild the list.
    func reload() {
        let items = DownloadManager.shared.items
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for (i, item) in items.enumerated() {
            let row = rows[item.id] ?? {
                let r = DownloadRow(item: item)
                r.onCancel = { DownloadManager.shared.cancel(item) }
                r.onRetry = { [weak self] in DownloadManager.shared.retry(item, using: self?.browser?.activeTab?.webView) }
                r.onReveal = { DownloadManager.shared.reveal(item) }
                r.onOpen = { DownloadManager.shared.open(item) }
                rows[item.id] = r
                return r
            }()
            if list.arrangedSubviews.firstIndex(of: row) != i {
                row.removeFromSuperview()
                list.insertArrangedSubview(row, at: min(i, list.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
            }
            row.update()
        }
        empty.isHidden = !items.isEmpty
        list.layoutSubtreeIfNeeded()
        scrollHeight.constant = items.isEmpty ? 60 : min(list.fittingSize.height, Self.maxListHeight)
    }

    var rowCount: Int { rows.count }

    @objc private func showFolder() { DownloadManager.shared.revealFolder() }
    @objc private func clearFinished() { DownloadManager.shared.clearFinished() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One download: its file icon, name, a status line or progress bar, and an action button.
private final class DownloadRow: NSView {
    let item: DownloadManager.Item
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onReveal: (() -> Void)?
    var onOpen: (() -> Void)?

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private lazy var action = HoverButton(symbol: "xmark.circle.fill", size: 13, label: "Cancel", target: self, action: #selector(actionClicked))
    private lazy var reveal = HoverButton(symbol: "magnifyingglass", size: 12, label: "Show in Finder", target: self, action: #selector(revealClicked))
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: DownloadManager.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = Theme.monoFont(10.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1

        let text = NSStackView(views: [name, bar, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let buttons = NSStackView(views: [reveal, action])
        buttons.spacing = 0
        for v in [icon, text, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -4),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        name.stringValue = item.filename
        toolTip = item.source?.absoluteString
        if let path = item.destination?.path, item.state == .finished, FileManager.default.fileExists(atPath: path) {
            icon.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let ext = (item.filename as NSString).pathExtension
            icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        status.stringValue = DownloadManager.status(of: item)
        let running = item.state == .running
        bar.isHidden = !running
        if let f = item.fraction { bar.isIndeterminate = false; bar.doubleValue = f } else if running {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        if case .failed = item.state { status.textColor = .systemRed } else { status.textColor = .secondaryLabelColor }
        reveal.isHidden = item.state != .finished
        switch item.state {
        case .running:
            action.isHidden = false
            action.image = Theme.symbol("xmark.circle.fill", size: 13)
            action.toolTip = "Cancel"
        case .failed, .cancelled:
            action.isHidden = item.source == nil
            action.image = Theme.symbol("arrow.clockwise", size: 12)
            action.toolTip = "Try Again"
        case .finished:
            action.isHidden = true
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.backgroundColor = hovering ? Theme.hoverFill.cgColor : .clear
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 1, item.state == .finished { onOpen?() }
    }

    @objc private func actionClicked() { item.state == .running ? onCancel?() : onRetry?() }
    @objc private func revealClicked() { onReveal?() }
}
