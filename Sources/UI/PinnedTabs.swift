import AppKit

/// Pinned tabs as a row of favicon tiles above the tab list. Wraps onto more rows when there are
/// more pins than fit across; collapses to nothing when there are none.
@MainActor
final class PinnedTabsView: NSView {
    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    /// The context menu for a tile (the same one the tab list uses).
    var menuForTab: ((Tab) -> NSMenu?)?

    private var tiles: [PinnedTile] = []
    var tileCount: Int { tiles.count }
    private static let tileHeight: CGFloat = 34
    private static let minTileWidth: CGFloat = 40
    private static let gap: CGFloat = 6

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The tiles can sit in the titlebar strip: keep the window server from dragging the window from them
    /// (see TabTableView).
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { visibleRect }

    func show(_ tabs: [Tab], active: Tab?) {
        if tiles.count != tabs.count || zip(tiles, tabs).contains(where: { $0.tab !== $1 }) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = tabs.map { tab in
                let tile = PinnedTile(tab: tab)
                tile.onClick = { [weak self] in self?.onSelect?(tab) }
                tile.onMiddleClick = { [weak self] in self?.onClose?(tab) }
                tile.onMenu = { [weak self] in self?.menuForTab?(tab) }
                addSubview(tile)
                return tile
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        for tile in tiles {
            tile.isActive = tile.tab === active
            tile.refresh()
        }
    }

    func refresh(_ tab: Tab) {
        tiles.first { $0.tab === tab }?.refresh()
    }

    /// Up to four tiles across, fewer when the sidebar is too narrow for them.
    private var perRow: Int {
        max(1, min(4, Int((bounds.width + Self.gap) / (Self.minTileWidth + Self.gap))))
    }

    private var rowCount: Int { (tiles.count + perRow - 1) / perRow }

    override var intrinsicContentSize: NSSize {
        let rows = CGFloat(rowCount)
        return NSSize(width: NSView.noIntrinsicMetric, height: rows == 0 ? 0 : rows * Self.tileHeight + (rows - 1) * Self.gap)
    }

    private var laidOutRows = 0

    override func layout() {
        super.layout()
        let perRow = perRow
        let width = (bounds.width - CGFloat(perRow - 1) * Self.gap) / CGFloat(perRow)
        for (i, tile) in tiles.enumerated() {
            let row = i / perRow, column = i % perRow
            tile.frame = NSRect(x: CGFloat(column) * (width + Self.gap), y: CGFloat(row) * (Self.tileHeight + Self.gap),
                                width: width, height: Self.tileHeight).integral
        }
        // A width change can move tiles onto another row; the height follows.
        if rowCount != laidOutRows {
            laidOutRows = rowCount
            invalidateIntrinsicContentSize()
        }
    }
}

/// One pinned tab: its favicon on a raised tile. The active one gets the accent ring.
final class PinnedTile: NSView {
    let tab: Tab
    var onClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }

    private let icon = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        icon.image = tab.favicon ?? Monogram.image(for: tab.currentURL, title: tab.displayTitle)
        icon.alphaValue = tab.isSuspended && !isActive ? 0.5 : 1
        toolTip = tab.displayTitle
        setAccessibilityLabel(tab.displayTitle)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() } else { super.otherMouseUp(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        Motion.setBackground(layer, (isActive ? Theme.selectedFill : hovering ? Theme.fieldFocusedFill : Theme.surface).cgColor)
        layer?.borderWidth = 1
        layer?.borderColor = (isActive ? Theme.accent : Theme.hairline).cgColor
    }
}
