import AppKit

/// A second, click-through "genie" pointer drawn as an 8-bit neon arrow.
/// Two modes: follow the real cursor (trailing-lag), or glide to a fixed point
/// (used as the tic-tac-toe opponent's "hand").
@MainActor
final class GenieCursor {
    private(set) var visible = false
    private var window: NSWindow?
    private var timer: Timer?
    private var pos: NSPoint = .zero
    private let offset = CGPoint(x: -60, y: 0)   // when following: sit left of the real cursor

    private var followMouse = true
    private var glideTarget: NSPoint = .zero
    private var glideDone: (() -> Void)?

    func toggle() { visible ? hide() : show() }

    /// Show following the real cursor (trailing genie).
    func show() {
        followMouse = true
        guard !visible else { return }
        visible = true
        ensureWindow()
        let m = NSEvent.mouseLocation
        pos = NSPoint(x: m.x + offset.x, y: m.y + offset.y)
        place()
        window?.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Show but hold still (used between game moves).
    func park() {
        show()
        followMouse = false
        glideTarget = pos
        glideDone = nil
    }

    /// Glide to a screen point, then call completion.
    func glide(to point: NSPoint, completion: @escaping () -> Void) {
        show()
        followMouse = false
        glideTarget = point
        glideDone = completion
    }

    /// Jump exactly to a point (no easing) — used to trace a drawing stroke.
    func snap(to point: NSPoint) {
        show()
        followMouse = false
        glideDone = nil
        glideTarget = point
        pos = point
        place()
    }

    func hide() {
        visible = false
        followMouse = true
        glideDone = nil
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
    }

    private func tick() {
        let target: NSPoint
        if followMouse {
            let m = NSEvent.mouseLocation
            target = NSPoint(x: m.x + offset.x, y: m.y + offset.y)
        } else {
            target = glideTarget
        }
        pos.x += (target.x - pos.x) * 0.18
        pos.y += (target.y - pos.y) * 0.18
        place()

        if !followMouse {
            let dx = target.x - pos.x, dy = target.y - pos.y
            if dx * dx + dy * dy < 6 {        // arrived
                pos = target; place()
                let done = glideDone; glideDone = nil
                done?()
            }
        }
    }

    private func place() {
        guard let window else { return }
        window.setFrameOrigin(NSPoint(x: pos.x, y: pos.y - window.frame.height))  // tip at top-left
    }

    private func ensureWindow() {
        if window != nil { return }
        let size = NSSize(width: 28, height: 28)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = GeniePointerView(frame: NSRect(origin: .zero, size: size))
        window = w
    }
}

/// Draws a blocky neon arrow pointer (tip at top-left), with a dark outline.
final class GeniePointerView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ rect: NSRect) {
        let pts: [NSPoint] = [
            NSPoint(x: 1, y: 1),  NSPoint(x: 1, y: 19), NSPoint(x: 6, y: 14),
            NSPoint(x: 9, y: 22), NSPoint(x: 12, y: 21), NSPoint(x: 9, y: 13),
            NSPoint(x: 15, y: 13)
        ]
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.close()

        NSColor(srgbRed: 0.23, green: 1.0, blue: 0.34, alpha: 0.8).setFill()
        path.fill()
        NSColor(srgbRed: 0.0, green: 0.12, blue: 0.04, alpha: 0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
