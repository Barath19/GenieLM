import AppKit
import CoreImage

private let neonColor = NSColor(srgbRed: 0.23, green: 1.0, blue: 0.34, alpha: 1.0)
private let bgColor = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)

/// Load the swappable board image and recolor it: white background → transparent,
/// dark lines → neon. Works for any grid image dropped in as Resources/board.png.
private let boardImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "board", withExtension: "png"),
          let ci = CIImage(contentsOf: url) else { return nil }
    let mask = ci.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha")
    let rep = NSCIImageRep(ciImage: mask)
    let masked = NSImage(size: rep.size); masked.addRepresentation(rep)

    let out = NSImage(size: rep.size)
    out.lockFocus()
    masked.draw(at: .zero, from: NSRect(origin: .zero, size: rep.size), operation: .sourceOver, fraction: 1)
    neonColor.set()
    NSRect(origin: .zero, size: rep.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}()

/// Freehand tic-tac-toe canvas. You ink your X with the mouse and press Space;
/// the ghost (Gemma) reads the drawing and inks an O.
final class DrawCanvasView: NSView {
    var onCommit: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplay: (() -> Void)?

    enum Mode { case draw, waiting, over }
    var mode: Mode = .draw
    private var commitTimer: Timer?
    private let autoCommitDelay = 0.9   // pause after drawing → ghost responds

    private(set) var strokes: [[NSPoint]] = []     // all committed ink (display)
    private var current: [NSPoint] = []            // stroke in progress
    private var turnPoints: [NSPoint] = []         // ink since last commit (to find the X cell)

    var xCells: Set<Int> = []
    var oCells: Set<Int> = []
    var status = "DRAW YOUR X"

    // Animated O.
    private var oAnimCell: Int?
    private var oAnimProgress: CGFloat = 0
    private var oTimer: Timer?
    private var oDone: (() -> Void)?
    private var oOnPoint: ((NSPoint) -> Void)?

    /// Per-O "handwriting": wobble + jitter so each circle looks hand-drawn.
    private struct OStyle { var amp1: Double; var ph1: Double; var amp2: Double; var ph2: Double; var jitter: CGPoint }
    private var oStyle: [Int: OStyle] = [:]

    private func makeOStyle() -> OStyle {
        OStyle(amp1: .random(in: 0.05...0.11), ph1: .random(in: 0..<(2 * .pi)),
               amp2: .random(in: 0.02...0.05), ph2: .random(in: 0..<(2 * .pi)),
               jitter: CGPoint(x: .random(in: -3...3), y: .random(in: -3...3)))
    }

    private let inset: CGFloat = 24
    private let topBar: CGFloat = 44

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // bottom-left origin

    // MARK: Geometry

    func boardRect() -> NSRect {
        let side = min(bounds.width - inset * 2, bounds.height - topBar - inset * 2)
        let x = (bounds.width - side) / 2
        let y = inset
        return NSRect(x: x, y: y, width: side, height: side)
    }

    func cellRect(_ i: Int) -> NSRect {
        let b = boardRect(); let s = b.width / 3
        let r = i / 3, c = i % 3
        return NSRect(x: b.minX + CGFloat(c) * s, y: b.minY + CGFloat(2 - r) * s, width: s, height: s)
    }

    func cellCenter(_ i: Int) -> NSPoint { let r = cellRect(i); return NSPoint(x: r.midX, y: r.midY) }

    func cellAt(_ p: NSPoint) -> Int? {
        for i in 0..<9 where cellRect(i).contains(p) { return i }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill(); bounds.fill()

        let b = boardRect()
        if let img = boardImage {
            img.draw(in: b)
        } else {
            neonColor.setStroke()
            let grid = NSBezierPath(); grid.lineWidth = 2
            for i in 1...2 {
                let x = b.minX + CGFloat(i) * b.width / 3
                grid.move(to: NSPoint(x: x, y: b.minY)); grid.line(to: NSPoint(x: x, y: b.maxY))
                let y = b.minY + CGFloat(i) * b.height / 3
                grid.move(to: NSPoint(x: b.minX, y: y)); grid.line(to: NSPoint(x: b.maxX, y: y))
            }
            grid.stroke()
        }

        // Ink (committed + in progress).
        neonColor.setStroke()
        for s in strokes + [current] where s.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 4; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: s[0]); for pt in s.dropFirst() { path.line(to: pt) }
            path.stroke()
        }

        for c in oCells { drawO(cell: c, end: 1.0) }
        if let a = oAnimCell { drawO(cell: a, end: oAnimProgress) }

        drawStatus()
    }

    private func drawO(cell: Int, end: CGFloat) {
        guard end > 0 else { return }
        let r = cellRect(cell)
        let style = oStyle[cell] ?? OStyle(amp1: 0.06, ph1: 0, amp2: 0.03, ph2: 1, jitter: .zero)
        let cx = Double(r.midX) + Double(style.jitter.x)
        let cy = Double(r.midY) + Double(style.jitter.y)
        let base = Double(r.width) * 0.3
        let start = Double.pi / 2                 // start at the top
        let totalSweep = 2 * Double.pi * 1.08      // slight overshoot, ends don't meet
        let segs = 64
        let n = max(1, Int(Double(segs) * Double(end)))

        let path = NSBezierPath()
        path.lineWidth = 5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        for k in 0...n {
            let t = Double(k) / Double(segs)
            let ang = start - t * totalSweep       // clockwise
            let rad = base * (1 + style.amp1 * sin(ang + style.ph1) + style.amp2 * sin(2 * ang + style.ph2))
            let pt = NSPoint(x: cx + rad * cos(ang), y: cy + rad * sin(ang))
            if k == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        neonColor.setStroke(); path.stroke()
    }

    private func drawStatus() {
        let font = NSFont(name: "Press Start 2P", size: 9) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: neonColor]
        let s = NSAttributedString(string: status, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - topBar / 2 - size.height / 2))
    }

    // MARK: Input

    override func mouseDown(with e: NSEvent) {
        switch mode {
        case .over: onReplay?()
        case .waiting: break
        case .draw:
            commitTimer?.invalidate(); commitTimer = nil
            current = [convert(e.locationInWindow, from: nil)]; needsDisplay = true
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard mode == .draw else { return }
        current.append(convert(e.locationInWindow, from: nil)); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard mode == .draw else { return }
        if current.count > 1 { strokes.append(current); turnPoints.append(contentsOf: current) }
        current = []; needsDisplay = true
        scheduleAutoCommit()
    }

    /// Auto-commit once the player pauses after drawing.
    private func scheduleAutoCommit() {
        commitTimer?.invalidate()
        guard !turnPoints.isEmpty else { return }
        commitTimer = Timer.scheduledTimer(withTimeInterval: autoCommitDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCommit?() }
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onClose?() } else { super.keyDown(with: e) }   // Esc
    }

    // MARK: Game ops

    /// Determine the cell the player just inked into; mark it X. Returns nil if
    /// nothing was drawn or it lands in an occupied cell.
    func commitX() -> Int? {
        guard !turnPoints.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for p in turnPoints { if let c = cellAt(p) { counts[c, default: 0] += 1 } }
        guard let cell = counts.max(by: { $0.value < $1.value })?.key,
              !xCells.contains(cell), !oCells.contains(cell) else { turnPoints = []; return nil }
        xCells.insert(cell); turnPoints = []; needsDisplay = true
        return cell
    }

    /// Pen point on the (wobbly) circle at fraction `end` — the leading edge.
    func penPoint(cell: Int, end: CGFloat) -> NSPoint {
        let r = cellRect(cell)
        let style = oStyle[cell] ?? OStyle(amp1: 0.06, ph1: 0, amp2: 0.03, ph2: 1, jitter: .zero)
        let cx = Double(r.midX) + Double(style.jitter.x)
        let cy = Double(r.midY) + Double(style.jitter.y)
        let base = Double(r.width) * 0.3
        let ang = Double.pi / 2 - Double(end) * 2 * Double.pi * 1.08
        let rad = base * (1 + style.amp1 * sin(ang + style.ph1) + style.amp2 * sin(2 * ang + style.ph2))
        return NSPoint(x: cx + rad * cos(ang), y: cy + rad * sin(ang))
    }

    /// Pick this O's "hand" and return where the stroke begins (view coords).
    func beginO(cell: Int) -> NSPoint {
        oStyle[cell] = makeOStyle()
        oAnimCell = cell; oAnimProgress = 0; needsDisplay = true
        return penPoint(cell: cell, end: 0.0001)
    }

    /// Animate the O; `onPoint` reports the moving pen tip each frame.
    func animateO(cell: Int, onPoint: @escaping (NSPoint) -> Void, completion: @escaping () -> Void) {
        oDone = completion
        oOnPoint = onPoint
        oTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.oAnimProgress += 0.035
                if self.oAnimProgress >= 1 {
                    self.oTimer?.invalidate(); self.oTimer = nil
                    self.oAnimCell = nil
                    self.oCells.insert(cell)
                    self.needsDisplay = true
                    self.oOnPoint = nil
                    let done = self.oDone; self.oDone = nil; done?()
                } else {
                    self.oOnPoint?(self.penPoint(cell: cell, end: self.oAnimProgress))
                    self.needsDisplay = true
                }
            }
        }
    }

    func resetBoard() {
        strokes = []; current = []; turnPoints = []
        xCells = []; oCells = []; oStyle = [:]
        oAnimCell = nil; oTimer?.invalidate(); oTimer = nil
        commitTimer?.invalidate(); commitTimer = nil
        mode = .draw
        status = "DRAW YOUR X"
        needsDisplay = true
    }
}

/// Hosts the drawing canvas and drives the ghost + Gemma for O's moves.
@MainActor
final class DrawGameController: NSObject {
    private(set) var isActive = false
    var onClose: (() -> Void)?

    private let ghost: GhostCursor
    private let ollama = OllamaClient()
    private var panel: KeyablePanel?
    private var canvas: DrawCanvasView?
    private var busy = false

    private static let lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]

    init(ghost: GhostCursor) { self.ghost = ghost }

    func start() {
        ensurePanel()
        canvas?.resetBoard()
        centerPanel()
        isActive = true
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        if let canvas { panel?.makeFirstResponder(canvas) }
        ghost.park()
    }

    func close() {
        guard isActive else { return }
        isActive = false
        ghost.hide()
        panel?.orderOut(nil)
        onClose?()
    }

    private func commit() {
        guard let canvas, !busy, canvas.mode == .draw else { return }

        guard canvas.commitX() != nil else {
            canvas.status = "DRAW YOUR X IN AN EMPTY CELL"; canvas.needsDisplay = true; return
        }
        RetroSound.submit()
        if let w = winner(canvas) { end(canvas, w); return }
        if full(canvas) { end(canvas, nil); return }

        busy = true
        canvas.mode = .waiting
        canvas.status = "GHOST LOOKING..."; canvas.needsDisplay = true
        Task { @MainActor in
            let cell = await ghostMove(canvas)
            let startView = canvas.beginO(cell: cell)
            let startScreen = panel?.convertPoint(toScreen: startView) ?? startView
            ghost.glide(to: startScreen) { [weak self] in
                guard let self, let canvas = self.canvas else { return }
                canvas.animateO(cell: cell, onPoint: { [weak self] viewPoint in
                    guard let self else { return }
                    let sp = self.panel?.convertPoint(toScreen: viewPoint) ?? viewPoint
                    self.ghost.snap(to: sp)   // pointer traces the stroke
                }, completion: {
                    RetroSound.answer()
                    self.busy = false
                    if let w = self.winner(canvas) { self.end(canvas, w); return }
                    if self.full(canvas) { self.end(canvas, nil); return }
                    canvas.mode = .draw
                    canvas.status = "YOUR TURN · DRAW X"; canvas.needsDisplay = true
                })
            }
        }
    }

    // MARK: AI (Gemma vision + fallback)

    private func ghostMove(_ canvas: DrawCanvasView) async -> Int {
        if let idx = await visionMove(canvas) { return idx }
        return (0..<9).first { !canvas.xCells.contains($0) && !canvas.oCells.contains($0) } ?? 0
    }

    private func visionMove(_ canvas: DrawCanvasView) async -> Int? {
        guard let panel else { return nil }
        ghost.hide()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let png = try? await ScreenCapture.capture(globalRect: panel.frame) else { return nil }
        let prompt = """
        This is a hand-drawn tic-tac-toe board with X marks. You play O. \
        Pick the best EMPTY square and reply with its CENTER as two numbers \
        x,y — each a fraction from 0 to 1, where x goes left→right and \
        y goes top→bottom. Reply with ONLY "x,y" (e.g. 0.5,0.5). No other text.
        """
        let msg = OllamaClient.ChatMessage(role: "user", content: prompt, images: [png.base64EncodedString()])
        guard let reply = try? await ollama.chat(messages: [msg]) else {
            print("[ghost] no reply from Gemma"); return nil
        }
        let W = Double(panel.frame.width), H = Double(panel.frame.height)
        print("[ghost] X cells=\(canvas.xCells.sorted()) O cells=\(canvas.oCells.sorted())")
        print("[ghost] gemma raw reply: \(reply.replacingOccurrences(of: "\n", with: " "))")

        let nums = reply.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }

        if nums.count >= 2 {
            var x = nums[0], y = nums[1]
            if x > 1.5 { x /= W }; if y > 1.5 { y /= H }   // tolerate pixel coords
            let col = min(2, max(0, Int(x * 3)))
            let row = min(2, max(0, Int(y * 3)))
            let cell = row * 3 + col
            print("[ghost] coords x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) → cell \(cell)")
            if !canvas.xCells.contains(cell), !canvas.oCells.contains(cell) { return cell }
            print("[ghost] coord cell occupied → fallback")
        } else if let d = nums.first.flatMap({ Int($0) }), (0...8).contains(d),
                  !canvas.xCells.contains(d), !canvas.oCells.contains(d) {
            print("[ghost] single index \(d)")
            return d
        }
        print("[ghost] no legal move parsed → minimax fallback")
        return nil
    }

    // MARK: Win logic (X = player ink cells, O = ghost cells)

    private func winner(_ c: DrawCanvasView) -> Character? {
        for l in Self.lines {
            if l.allSatisfy({ c.xCells.contains($0) }) { return "X" }
            if l.allSatisfy({ c.oCells.contains($0) }) { return "O" }
        }
        return nil
    }
    private func full(_ c: DrawCanvasView) -> Bool { c.xCells.count + c.oCells.count >= 9 }

    private func end(_ c: DrawCanvasView, _ w: Character?) {
        busy = false
        c.mode = .over
        c.status = w == "X" ? "YOU WIN! CLICK TO REPLAY" : w == "O" ? "GHOST WINS · CLICK TO REPLAY" : "DRAW · CLICK TO REPLAY"
        w == "X" ? RetroSound.answer() : RetroSound.error()
        c.needsDisplay = true
    }

    // MARK: Panel

    private func ensurePanel() {
        if panel != nil { return }
        let size = NSSize(width: 360, height: 400)
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.onEscape = { [weak self] in self?.close() }

        let view = DrawCanvasView(frame: NSRect(origin: .zero, size: size))
        view.onCommit = { [weak self] in self?.commit() }
        view.onClose = { [weak self] in self?.close() }
        view.onReplay = { [weak self] in self?.canvas?.resetBoard() }
        p.contentView = view

        // Square border around the whole panel.
        view.wantsLayer = true
        view.layer?.borderColor = neonColor.cgColor
        view.layer?.borderWidth = 2

        panel = p
        canvas = view
    }

    private func centerPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = panel.frame, v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2))
    }
}
