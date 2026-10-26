import AppKit

/// Shared timing for the UI's small animations. Everything checks `reduceMotion`: with Reduce Motion on,
/// nothing moves or scales, and changes are instant or a plain fade.
@MainActor
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Hover fills, a pill fading out.
    static let fast: CFTimeInterval = 0.12
    /// Panels opening, a chip moving between rows.
    static let standard: CFTimeInterval = 0.2

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// The spring link peek grows on; `damping` below 30 gives a little overshoot.
    static func spring(_ keyPath: String, stiffness: CGFloat = 300, damping: CGFloat = 30) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        return spring
    }

    /// A scale about the center of a layer whose anchor point is its corner (AppKit's default).
    static func scale(_ s: CGFloat, size: CGSize) -> CATransform3D {
        let t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        return CATransform3DTranslate(CATransform3DScale(t, s, s, 1), -size.width / 2, -size.height / 2, 0)
    }

    /// A quick bounce for something that just turned on: a bookmark star, a check.
    static func pop(_ view: NSView, from scale: CGFloat = 0.55) {
        guard !reduceMotion, let layer = view.layer else { return }
        let pop = spring("transform", stiffness: 420, damping: 13)
        pop.fromValue = NSValue(caTransform3D: Self.scale(scale, size: view.bounds.size))
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(pop, forKey: "pop")
    }

    /// Sets a layer's background, fading from what's on screen now (hover fills). Fades are kept with
    /// Reduce Motion on: nothing moves.
    static func setBackground(_ layer: CALayer?, _ color: CGColor?, duration: CFTimeInterval = fast) {
        guard let layer else { return }
        let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        if current != color {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = current ?? NSColor.clear.cgColor
            fade.toValue = color ?? NSColor.clear.cgColor
            fade.duration = duration
            fade.timingFunction = easeOut
            layer.add(fade, forKey: "fill")
        }
        layer.backgroundColor = color
    }

    /// Fades a view in or out, hiding it at the end of a fade out.
    static func fade(_ view: NSView, visible: Bool, duration: CFTimeInterval = fast) {
        if visible, view.isHidden { view.alphaValue = 0; view.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            view.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            MainActor.assumeIsolated { if !visible, view.alphaValue == 0 { view.isHidden = true } }
        })
    }
}

/// A table whose selection is a separate view under the rows, so it can glide from row to row instead of
/// jumping. Rows draw no selection of their own; the owner moves the chip with `moveChip(to:animated:)`.
class GlidingTableView: NSTableView {
    private let chip: NSView
    /// The row the chip sits on; -1 hides it.
    private(set) var chipRow = -1

    init(chip: NSView) {
        self.chip = chip
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the chip on `row`. A chip already on screen glides there unless `animated` is false or
    /// Reduce Motion is on.
    func moveChip(to row: Int, animated: Bool = true) {
        guard row >= 0, row < numberOfRows else { chipRow = -1; chip.isHidden = true; return }
        if chip.superview !== self {
            chip.wantsLayer = true
            addSubview(chip, positioned: .below, relativeTo: nil)
        }
        let wasShown = !chip.isHidden && chipRow >= 0
        let from = chip.layer?.presentation()?.position ?? chip.layer?.position
        chipRow = row
        chip.isHidden = false
        chip.frame = rect(ofRow: row)
        guard animated, wasShown, !Motion.reduceMotion, let from, let layer = chip.layer, from != layer.position else {
            chip.layer?.removeAnimation(forKey: "glide")
            return
        }
        let glide = Motion.spring("position", stiffness: 520, damping: 42)
        glide.fromValue = NSValue(point: from)
        glide.toValue = NSValue(point: layer.position)
        layer.add(glide, forKey: "glide")
    }

    /// Keeps the chip on its row as the table resizes or rows come and go.
    override func layout() {
        super.layout()
        if chipRow >= 0, chipRow < numberOfRows { chip.frame = rect(ofRow: chipRow) }
    }
}
