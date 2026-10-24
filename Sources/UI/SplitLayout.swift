import AppKit

/// How the panes of a split are arranged.
enum SplitLayout: String, CaseIterable {
    /// Side by side.
    case columns
    /// Stacked top to bottom.
    case rows
    /// Three tabs: one on the left, two stacked on the right. Four tabs: a 2×2 grid.
    case grid

    var title: String {
        switch self {
        case .columns: "Side by Side"
        case .rows: "Stacked"
        case .grid: "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .columns: "rectangle.split.2x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        }
    }

    /// A grid needs at least three tabs.
    func fits(_ count: Int) -> Bool { self != .grid || count >= 3 }
}

/// Two to four tabs shown together. It's on screen whenever the active tab is one of them;
/// picking another tab shows that tab alone and keeps the group for later.
struct SplitGroup {
    static let maxTabs = 4

    /// In reading order: left to right, then top to bottom.
    var tabs: [Tab]
    var layout: SplitLayout
    /// Where the dividers sit, from 0 to 1. Columns and rows: one per gap, increasing.
    /// Grid: the column divider, then the row divider.
    var dividers: [CGFloat]

    init(tabs: [Tab], layout: SplitLayout, dividers: [CGFloat]? = nil) {
        let layout = layout.fits(tabs.count) ? layout : .columns
        self.tabs = tabs
        self.layout = layout
        self.dividers = dividers.flatMap { $0.count == Self.dividerCount(tabs.count, layout) ? $0 : nil }
            ?? Self.evenDividers(tabs.count, layout)
    }

    static func dividerCount(_ count: Int, _ layout: SplitLayout) -> Int { layout == .grid ? 2 : count - 1 }

    static func evenDividers(_ count: Int, _ layout: SplitLayout) -> [CGFloat] {
        layout == .grid ? [0.5, 0.5] : (1..<max(count, 2)).map { CGFloat($0) / CGFloat(count) }
    }

    func contains(_ tab: Tab) -> Bool { tabs.contains { $0 === tab } }

    /// Changes the tabs, and the layout when given or when the old one no longer fits. Dividers go back to even.
    mutating func setTabs(_ tabs: [Tab], layout: SplitLayout? = nil) {
        self = SplitGroup(tabs: tabs, layout: layout ?? self.layout)
    }
}

/// A gap between panes that can be dragged.
struct SplitHandle {
    var rect: NSRect
    /// Which entry of `SplitGroup.dividers` it moves.
    var divider: Int
    var vertical: Bool
}

/// Pane geometry, shared by the content panes and the drop target. Flipped thinking: index 0 is at
/// the top or left; the returned rects are in AppKit's bottom-left coordinates.
enum SplitGeometry {
    static func frames(count: Int, layout: SplitLayout, dividers: [CGFloat], in b: NSRect, gap: CGFloat) -> [NSRect] {
        guard count > 1 else { return [b] }
        switch layout {
        case .columns:
            return spans(count, dividers, length: b.width, gap: gap).map { NSRect(x: b.minX + $0.start, y: b.minY, width: $0.length, height: b.height) }
        case .rows:
            return spans(count, dividers, length: b.height, gap: gap).map { NSRect(x: b.minX, y: b.maxY - $0.start - $0.length, width: b.width, height: $0.length) }
        case .grid:
            let x = dividers.first ?? 0.5, y = dividers.count > 1 ? dividers[1] : 0.5
            let leftW = ((b.width - gap) * x).rounded(), rightW = b.width - leftW - gap
            let topH = ((b.height - gap) * y).rounded(), bottomH = b.height - topH - gap
            let left = b.minX, right = b.minX + leftW + gap
            let top = b.maxY - topH, bottom = b.minY
            if count == 3 {
                return [NSRect(x: left, y: b.minY, width: leftW, height: b.height),
                        NSRect(x: right, y: top, width: rightW, height: topH),
                        NSRect(x: right, y: bottom, width: rightW, height: bottomH)]
            }
            return [NSRect(x: left, y: top, width: leftW, height: topH), NSRect(x: right, y: top, width: rightW, height: topH),
                    NSRect(x: left, y: bottom, width: leftW, height: bottomH), NSRect(x: right, y: bottom, width: rightW, height: bottomH)]
        }
    }

    /// The draggable gaps, a few points wider than the gap itself.
    static func handles(count: Int, layout: SplitLayout, frames f: [NSRect], in b: NSRect, gap: CGFloat) -> [SplitHandle] {
        guard count > 1, f.count == count else { return [] }
        let pad: CGFloat = 3
        switch layout {
        case .columns:
            return (0..<count - 1).map { SplitHandle(rect: NSRect(x: f[$0].maxX - pad, y: b.minY, width: gap + 2 * pad, height: b.height), divider: $0, vertical: true) }
        case .rows:
            return (0..<count - 1).map { SplitHandle(rect: NSRect(x: b.minX, y: f[$0].minY - gap - pad, width: b.width, height: gap + 2 * pad), divider: $0, vertical: false) }
        case .grid:
            let column = SplitHandle(rect: NSRect(x: f[0].maxX - pad, y: b.minY, width: gap + 2 * pad, height: b.height), divider: 0, vertical: true)
            let rowY = f[1].minY - gap - pad
            let rowX = count == 3 ? f[1].minX : b.minX
            let row = SplitHandle(rect: NSRect(x: rowX, y: rowY, width: b.maxX - rowX, height: gap + 2 * pad), divider: 1, vertical: false)
            return [column, row]
        }
    }

    /// The divider value for a pointer at `point` dragging `handle`, kept clear of its neighbors.
    static func divider(for handle: SplitHandle, at point: NSPoint, count: Int, layout: SplitLayout,
                        dividers: [CGFloat], in b: NSRect, gap: CGFloat) -> CGFloat {
        let minPane: CGFloat = 0.12
        let along = handle.vertical ? point.x - b.minX : b.maxY - point.y
        let length = handle.vertical ? b.width : b.height
        let gaps = layout == .grid ? 1 : CGFloat(count - 1)
        let index = layout == .grid ? 0 : CGFloat(handle.divider)
        let value = (along - (index + 0.5) * gap) / max(1, length - gaps * gap)
        let low = layout != .grid && handle.divider > 0 ? dividers[handle.divider - 1] + minPane : minPane
        let high = layout != .grid && handle.divider < dividers.count - 1 ? dividers[handle.divider + 1] - minPane : 1 - minPane
        return min(high, max(low, value))
    }

    private static func spans(_ count: Int, _ dividers: [CGFloat], length: CGFloat, gap: CGFloat) -> [(start: CGFloat, length: CGFloat)] {
        let available = length - gap * CGFloat(count - 1)
        let cuts = [0] + dividers.prefix(count - 1).map { ($0 * available).rounded() } + [available]
        return (0..<count).map { i in (cuts[i] + CGFloat(i) * gap, cuts[i + 1] - cuts[i]) }
    }
}
