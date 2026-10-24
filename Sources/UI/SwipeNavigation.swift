import AppKit
import WebKit

/// Two-finger back/forward without Safari's page slide: the page changes the moment the swipe has
/// travelled `threshold` points, while the fingers are still moving. An arrow at the pane's edge
/// follows the swipe until then.
///
/// A gesture that starts out vertical never navigates, and neither does one over something that can
/// still scroll that way (the page itself, or a carousel under the pointer): that scrolls as usual.
@MainActor
final class SwipeNavigator {
    static let threshold: CGFloat = 56

    private weak var webView: WKWebView?
    private let arrow = SwipeArrow()

    private enum Axis { case undecided, horizontal, vertical }
    private enum Room { case unknown, checking, scrolls, free }
    private var axis = Axis.undecided
    private var travel = NSSize.zero
    /// Finger travel so far; positive is towards "back" (fingers moving right).
    private var fingers: CGFloat = 0
    /// Whether the content under the pointer can still scroll towards each side, asked once per gesture.
    private var room: [Bool: Room] = [:]
    private var point = CGPoint.zero
    private var fired = false
    private var inGesture = false
    private var gesture = 0

    init(webView: WKWebView) { self.webView = webView }

    /// Turns off WebKit's sliding swipe, and the sideways rubber band at the page's edges, which would
    /// otherwise stretch the page while it changes.
    static func configure(_ webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = false
        let setter = NSSelectorFromString("_setRubberBandingEnabled:")
        guard webView.responds(to: setter), let imp = webView.method(for: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let top: UInt = 1 << 1, bottom: UInt = 1 << 3 // _WKRectEdge
        unsafeBitCast(imp, to: Setter.self)(webView, setter, top | bottom)
    }

    /// The system setting "Swipe between pages" (scroll left or right with two fingers).
    static var isEnabled: Bool { NSEvent.isSwipeTrackingFromScrollEventsEnabled }

    /// Every scroll event the web view gets, before WebKit sees it.
    func scrollWheel(_ event: NSEvent) {
        guard Self.isEnabled, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty, let webView else { return }
        if event.phase.contains(.began) {
            reset()
            inGesture = true
            gesture += 1
            let p = webView.convert(event.locationInWindow, from: nil)
            point = CGPoint(x: p.x, y: webView.isFlipped ? p.y : webView.bounds.height - p.y)
        }
        guard inGesture else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            inGesture = false
            if !fired { arrow.hide(animated: true) }
            return
        }
        travel.width += abs(event.scrollingDeltaX)
        travel.height += abs(event.scrollingDeltaY)
        if axis == .undecided, travel.width + travel.height > 6 {
            axis = travel.width > travel.height * 1.5 ? .horizontal : .vertical
        }
        // Fingers moving right mean "back", whichever way content scrolls.
        fingers += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        update()
    }

    private func update() {
        guard axis == .horizontal, !fired, let webView, fingers != 0 else { return }
        let back = fingers > 0
        guard back ? webView.canGoBack : webView.canGoForward else { return arrow.hide(animated: false) }
        switch room[back] ?? .unknown {
        case .unknown: check(back: back)
        case .checking, .scrolls: arrow.hide(animated: false)
        case .free:
            let progress = min(abs(fingers) / Self.threshold, 1)
            arrow.show(back: back, progress: progress, in: webView)
            if progress >= 1 {
                fired = true
                if back { webView.goBack() } else { webView.goForward() }
                arrow.commit()
            }
        }
    }

    /// Asks the page whether anything under the pointer, or the page itself, can still scroll that way.
    private func check(back: Bool) {
        guard let webView else { return }
        room[back] = .checking
        let gesture = self.gesture
        webView.callAsyncJavaScript(Self.canScroll, arguments: ["x": point.x, "y": point.y, "back": back],
                                    in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.gesture == gesture else { return }
                // A page that won't answer (still loading, or no script) doesn't block the swipe.
                let scrolls = (try? result.get()) as? Bool ?? false
                self.room[back] = scrolls ? .scrolls : .free
                self.update()
            }
        }
    }

    private static let canScroll = """
    const html = document.documentElement, body = document.body;
    const can = (e) => {
      const max = e.scrollWidth - e.clientWidth;
      if (max < 1) return false;
      const style = getComputedStyle(e);
      if (e === document.scrollingElement) {
        if ([html, body].some(n => n && /hidden|clip/.test(getComputedStyle(n).overflowX))) return false;
      } else if (!/auto|scroll|overlay/.test(style.overflowX)) return false;
      const fromLeft = style.direction === 'rtl' ? max + e.scrollLeft : e.scrollLeft;
      return back ? fromLeft > 0.5 : fromLeft < max - 0.5;
    };
    for (let e = document.elementFromPoint(x, y); e; e = e.parentElement) if (can(e)) return true;
    return document.scrollingElement ? can(document.scrollingElement) : false;
    """

    private func reset() {
        axis = .undecided
        travel = .zero
        fingers = 0
        room = [:]
        fired = false
        arrow.hide(animated: false)
    }
}

/// A round arrow at the left or right edge of the page that slides in as the swipe progresses.
@MainActor
final class SwipeArrow: NSView {
    private static let size: CGFloat = 40
    private let icon = NSImageView()
    private var back = true

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.borderWidth = 1
        icon.frame = bounds
        icon.imageScaling = .scaleNone
        addSubview(icon)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }

    /// Follows the swipe: hidden off the edge at 0, fully in at 1.
    func show(back: Bool, progress: CGFloat, in webView: NSView) {
        guard let host = webView.superview else { return }
        if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: webView) }
        if back != self.back || icon.image == nil {
            self.back = back
            icon.image = Theme.symbol(back ? "arrow.left" : "arrow.right", size: 15, weight: .semibold)
        }
        let frame = webView.frame
        let inset = -Self.size + (Self.size + 16) * progress
        let x = back ? frame.minX + inset : frame.maxX - Self.size - inset
        layer?.removeAllAnimations()
        self.frame = NSRect(x: x, y: frame.midY - Self.size / 2, width: Self.size, height: Self.size)
        icon.contentTintColor = progress >= 1 ? Theme.accent : .secondaryLabelColor
        alphaValue = min(1, progress * 1.5)
        isHidden = false
    }

    /// The page is changing: a short fade, so the arrow doesn't sit over the new page.
    func commit() {
        icon.contentTintColor = Theme.accent
        hide(animated: true)
    }

    func hide(animated: Bool) {
        guard !isHidden else { return }
        guard animated, !LinkPeek.reduceMotion else { isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.alphaValue == 0 { self?.isHidden = true }
            }
        })
    }
}
