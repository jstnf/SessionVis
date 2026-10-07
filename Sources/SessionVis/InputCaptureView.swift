import SwiftUI
import AppKit

/// Transparent NSView that forwards trackpad scroll, pinch, hover and clicks. Coordinates are top-left origin.
struct InputCaptureView: NSViewRepresentable {
    var onScroll: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onMove: (CGPoint?) -> Void
    var onClick: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) { apply(to: nsView) }

    private func apply(to v: CaptureNSView) {
        v.onScroll = onScroll; v.onMagnify = onMagnify; v.onMove = onMove; v.onClick = onClick
    }
}

final class CaptureNSView: NSView {
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onMove: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint, Int) -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func scrollWheel(with e: NSEvent) {
        let m: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        onScroll?(CGSize(width: e.scrollingDeltaX * m, height: e.scrollingDeltaY * m))
    }
    override func magnify(with e: NSEvent) { onMagnify?(1 + e.magnification, point(e)) }
    override func mouseMoved(with e: NSEvent) { onMove?(point(e)) }
    override func mouseExited(with e: NSEvent) { onMove?(nil) }
    override func mouseDown(with e: NSEvent) { onClick?(point(e), e.clickCount) }
}
