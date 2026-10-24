import AppKit

extension NSPasteboard.PasteboardType {
    /// A tab dragged out of the sidebar, by id.
    static let tabID = NSPasteboard.PasteboardType("dev.tern.tab-id")
}

/// Covers the panes while a tab is dragged from the sidebar. Over a single page, the half nearest the
/// pointer lights up: dropping there splits left, right, up or down. In a split, a pane lights up and the
/// drop replaces it; near the page's outer edge (with room for another pane), the drop adds a pane there.
final class SplitDropView: NSView {
    /// Called with the dragged tab's id and the target; returns whether the split changed.
    var onDrop: ((UUID, BrowserWindowController.PaneDrop) -> Bool)?
    /// The visible panes' frames, in this view's coordinates.
    var paneFrames: (() -> [NSRect])?
    var canAddPane = true

    private let highlight = FilledView()
    private let label = NSTextField(labelWithString: "")
    private(set) var target: BrowserWindowController.PaneDrop? { didSet { if target != oldValue { needsLayout = true } } }

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
        guard let target else { highlight.isHidden = true; return }
        let (rect, text) = Self.preview(for: target, frames: paneFrames?() ?? [bounds], in: bounds)
        highlight.frame = rect
        label.stringValue = text
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (rect.width - label.frame.width) / 2, y: (rect.height - label.frame.height) / 2)
        highlight.isHidden = false
    }

    func reset() { target = nil }

    /// What a drop at `point` would do.
    static func target(at point: NSPoint, frames: [NSRect], in b: NSRect, canAddPane: Bool) -> BrowserWindowController.PaneDrop? {
        guard b.contains(point) else { return nil }
        // Distance to each outer edge, as a share of the page.
        let edges: [(NSRectEdge, CGFloat)] = [
            (.minX, (point.x - b.minX) / b.width), (.maxX, (b.maxX - point.x) / b.width),
            (.maxY, (b.maxY - point.y) / b.height), (.minY, (point.y - b.minY) / b.height),
        ]
        let nearest = edges.min { $0.1 < $1.1 }!
        if frames.count < 2 { return .edge(nearest.0) }
        if canAddPane, nearest.1 < 0.12 { return .edge(nearest.0) }
        return frames.firstIndex { $0.insetBy(dx: -Theme.gutter / 2, dy: -Theme.gutter / 2).contains(point) }.map { .pane($0) }
    }

    static func preview(for target: BrowserWindowController.PaneDrop, frames: [NSRect], in b: NSRect) -> (NSRect, String) {
        switch target {
        case .pane(let i):
            return (frames.indices.contains(i) ? frames[i] : b, "Replace This Pane")
        case .edge(let edge):
            // A single page splits in half; a split gets a strip for the new pane.
            let share: CGFloat = frames.count < 2 ? 0.5 : 0.3
            let w = ((b.width - Theme.gutter) * share).rounded(), h = ((b.height - Theme.gutter) * share).rounded()
            switch edge {
            case .minX: return (NSRect(x: b.minX, y: b.minY, width: w, height: b.height), "Open on the Left")
            case .maxX: return (NSRect(x: b.maxX - w, y: b.minY, width: w, height: b.height), "Open on the Right")
            case .maxY: return (NSRect(x: b.minX, y: b.maxY - h, width: b.width, height: h), "Open Above")
            default: return (NSRect(x: b.minX, y: b.minY, width: b.width, height: h), "Open Below")
            }
        }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .tabID) != nil else { target = nil; return [] }
        target = Self.target(at: convert(sender.draggingLocation, from: nil), frames: paneFrames?() ?? [], in: bounds, canAddPane: canAddPane)
        return target == nil ? [] : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { target = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { target = nil }
        guard let target, let s = sender.draggingPasteboard.string(forType: .tabID), let id = UUID(uuidString: s) else { return false }
        return onDrop?(id, target) ?? false
    }
}
