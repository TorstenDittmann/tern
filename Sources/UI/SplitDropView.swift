import AppKit

extension NSPasteboard.PasteboardType {
    /// A tab dragged out of the sidebar, by id.
    static let tabID = NSPasteboard.PasteboardType("dev.tern.tab-id")
}

/// Covers the panes while a tab is dragged from the sidebar. Hovering highlights the left or right
/// half; dropping opens the dragged tab on that side of a split.
final class SplitDropView: NSView {
    /// Called with the dragged tab's id and the side; returns whether the split happened.
    var onDrop: ((UUID, _ right: Bool) -> Bool)?

    private let highlight = FilledView()
    private let label = NSTextField(labelWithString: "")
    private(set) var side: Bool? { didSet { if side != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.tabID])
        highlight.radius = Theme.cardRadius
        highlight.fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
        highlight.border = NSColor.controlAccentColor.withAlphaComponent(0.7)
        highlight.isHidden = true
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .controlAccentColor
        label.alignment = .center
        addSubview(highlight)
        highlight.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks never stop here; it's only ever a drop target.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func layout() {
        super.layout()
        guard let side else { highlight.isHidden = true; return }
        let half = (bounds.width - Theme.gutter) / 2
        highlight.frame = NSRect(x: side ? bounds.width - half : 0, y: 0, width: half, height: bounds.height)
        label.stringValue = side ? "Open on the Right" : "Open on the Left"
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (half - label.frame.width) / 2, y: (bounds.height - label.frame.height) / 2)
        highlight.isHidden = false
    }

    func reset() { side = nil }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .tabID) != nil else { side = nil; return [] }
        side = convert(sender.draggingLocation, from: nil).x > bounds.midX
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { side = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { side = nil }
        guard let side, let s = sender.draggingPasteboard.string(forType: .tabID), let id = UUID(uuidString: s) else { return false }
        return onDrop?(id, side) ?? false
    }
}
