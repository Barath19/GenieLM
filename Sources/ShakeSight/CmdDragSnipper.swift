import AppKit

/// Hold ⌘ and drag a rectangle anywhere to snip that region. Uses passive
/// global/local mouse monitors and a click-through overlay that draws the
/// selection box; on release it reports the rect in global AppKit coords.
@MainActor
final class CmdDragSnipper {
    var onSnip: ((CGRect) -> Void)?

    private var monitors: [Any] = []
    private var overlay: NSWindow?
    private var view: SnipView?
    private var dragging = false
    private var startPoint: NSPoint = .zero

    func start() {
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }; return e
        }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .leftMouseDown || e.type == .leftMouseUp {
            print("[snip] \(e.type == .leftMouseDown ? "down" : "up") cmd=\(e.modifierFlags.contains(.command)) dragging=\(dragging)")
        }
        switch e.type {
        case .leftMouseDown:
            guard e.modifierFlags.contains(.command) else { return }
            dragging = true
            startPoint = NSEvent.mouseLocation
            showOverlay(near: startPoint)
            updateRect(to: startPoint)
        case .leftMouseDragged:
            guard dragging else { return }
            updateRect(to: NSEvent.mouseLocation)
        case .leftMouseUp:
            guard dragging else { return }
            dragging = false
            let rect = globalRect(end: NSEvent.mouseLocation)
            hideOverlay()
            print("[snip] mouseUp rect=\(rect)")
            if rect.width >= 8, rect.height >= 8 { onSnip?(rect) }
            else { print("[snip] too small, ignored") }
        default:
            break
        }
    }

    private func globalRect(end: NSPoint) -> CGRect {
        CGRect(x: min(startPoint.x, end.x), y: min(startPoint.y, end.y),
               width: abs(end.x - startPoint.x), height: abs(end.y - startPoint.y))
    }

    private func showOverlay(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        if overlay == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.ignoresMouseEvents = true        // never steal the drag from the app underneath
            w.hasShadow = false
            let v = SnipView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            overlay = w; view = v
        }
        overlay?.setFrame(screen.frame, display: false)
        view?.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlay?.orderFrontRegardless()
    }

    private func updateRect(to end: NSPoint) {
        guard let overlay, let view else { return }
        let g = globalRect(end: end)
        // Global → overlay-window coords.
        let origin = overlay.frame.origin
        view.selection = NSRect(x: g.minX - origin.x, y: g.minY - origin.y, width: g.width, height: g.height)
        view.needsDisplay = true
    }

    private func hideOverlay() {
        view?.selection = nil
        overlay?.orderOut(nil)
    }
}

/// Click-through visual: dims the screen and outlines the live selection.
final class SnipView: NSView {
    var selection: NSRect?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        guard let sel = selection, sel.width > 0, sel.height > 0 else { return }
        NSColor.clear.setFill()
        sel.fill(using: .copy)   // reveal the real screen inside the box
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 1.5
        NSColor(srgbRed: 0.23, green: 1.0, blue: 0.34, alpha: 1.0).setStroke()
        border.stroke()
    }
}
