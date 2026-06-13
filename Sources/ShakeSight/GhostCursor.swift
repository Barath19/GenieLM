import AppKit

/// A second, click-through "ghost" pointer that eases toward the real cursor,
/// leaving a trailing-lag effect. Drawn as an 8-bit neon arrow.
@MainActor
final class GhostCursor {
    private(set) var visible = false
    private var window: NSWindow?
    private var timer: Timer?
    private var pos: NSPoint = .zero
    private let offset = CGPoint(x: -60, y: 0)   // ghost sits to the left of the real cursor

    func toggle() { visible ? hide() : show() }

    func show() {
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

    func hide() {
        visible = false
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        let target = NSPoint(x: m.x + offset.x, y: m.y + offset.y)
        pos.x += (target.x - pos.x) * 0.16   // easing → trailing ghost
        pos.y += (target.y - pos.y) * 0.16
        place()
    }

    private func place() {
        guard let window else { return }
        // Arrow tip is the window's top-left corner.
        window.setFrameOrigin(NSPoint(x: pos.x, y: pos.y - window.frame.height))
    }

    private func ensureWindow() {
        if window != nil { return }
        let size = NSSize(width: 28, height: 28)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true                 // click-through
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = GhostPointerView(frame: NSRect(origin: .zero, size: size))
        window = w
    }
}

/// Draws a blocky neon arrow pointer (tip at top-left), with a dark outline.
final class GhostPointerView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ rect: NSRect) {
        // Classic pointer outline, tip at (1,1).
        let pts: [NSPoint] = [
            NSPoint(x: 1, y: 1),  NSPoint(x: 1, y: 19), NSPoint(x: 6, y: 14),
            NSPoint(x: 9, y: 22), NSPoint(x: 12, y: 21), NSPoint(x: 9, y: 13),
            NSPoint(x: 15, y: 13)
        ]
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.close()

        NSColor(srgbRed: 0.23, green: 1.0, blue: 0.34, alpha: 0.75).setFill()
        path.fill()
        NSColor(srgbRed: 0.0, green: 0.12, blue: 0.04, alpha: 0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
