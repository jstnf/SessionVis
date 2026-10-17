import SwiftUI
import AppKit
import SessionVisCore

/// Transparent NSView that forwards trackpad scroll, pinch, hover, clicks and key commands. Coordinates are top-left origin.
struct InputCaptureView: NSViewRepresentable {
    var onScroll: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onMove: (CGPoint?) -> Void
    var onClick: (CGPoint, Int) -> Void
    var onKey: (KeyCommand) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) { apply(to: nsView) }

    private func apply(to v: CaptureNSView) {
        v.onScroll = onScroll; v.onMagnify = onMagnify; v.onMove = onMove; v.onClick = onClick; v.onKey = onKey
    }
}

final class CaptureNSView: NSView {
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onMove: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint, Int) -> Void)?
    var onKey: ((KeyCommand) -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Keys reach this view only while it is first responder; claim that when the window appears and on every click,
    /// so Tab arrives here before the window's key-view loop.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

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
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        onClick?(point(e), e.clickCount)
    }
    override func keyDown(with e: NSEvent) {
        if let command = KeyCommand(event: e) { onKey?(command) } else { super.keyDown(with: e) }
    }
}
