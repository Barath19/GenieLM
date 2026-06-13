import AppKit
import SwiftUI

/// Game state + unbeatable minimax AI. You are X, the ghost is O.
@MainActor
final class TicTacToeModel: ObservableObject {
    enum Mark: Character { case x = "X", o = "O" }

    @Published var board: [Mark?] = Array(repeating: nil, count: 9)
    @Published var status = "YOUR TURN"
    @Published var finished = false
    /// Cell frames in SwiftUI global space, used to aim the ghost.
    @Published var cellFrames: [Int: CGRect] = [:]

    var current: Mark = .x

    func reset() {
        board = Array(repeating: nil, count: 9)
        current = .x
        finished = false
        status = "YOUR TURN"
    }

    func canPlay(_ i: Int) -> Bool { !finished && board[i] == nil }
    func place(_ i: Int, _ m: Mark) { board[i] = m }
    func isFull() -> Bool { !board.contains(where: { $0 == nil }) }

    private static let lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]

    func winner() -> Mark? {
        for l in Self.lines {
            if let m = board[l[0]], board[l[1]] == m, board[l[2]] == m { return m }
        }
        return nil
    }

    /// Best move for `me` via minimax.
    func bestMove(for me: Mark) -> Int {
        var bestScore = Int.min, move = -1
        for i in 0..<9 where board[i] == nil {
            board[i] = me
            let s = minimax(depth: 1, maximizing: false, me: me)
            board[i] = nil
            if s > bestScore { bestScore = s; move = i }
        }
        return move
    }

    private func minimax(depth: Int, maximizing: Bool, me: Mark) -> Int {
        if let w = winner() { return w == me ? 10 - depth : depth - 10 }
        if isFull() { return 0 }
        let opp: Mark = me == .x ? .o : .x
        if maximizing {
            var best = Int.min
            for i in 0..<9 where board[i] == nil {
                board[i] = me; best = max(best, minimax(depth: depth + 1, maximizing: false, me: me)); board[i] = nil
            }
            return best
        } else {
            var best = Int.max
            for i in 0..<9 where board[i] == nil {
                board[i] = opp; best = min(best, minimax(depth: depth + 1, maximizing: true, me: me)); board[i] = nil
            }
            return best
        }
    }
}

/// 8-bit tic-tac-toe board.
struct TicTacToeView: View {
    @ObservedObject var model: TicTacToeModel
    var onTap: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("TIC TAC TOE").font(Retro.font(11)).foregroundColor(Retro.neon)
            Text(model.status).font(Retro.font(7)).foregroundColor(Retro.dim)

            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { c in cell(r * 3 + c) }
                    }
                }
            }
            Text("ESC TO QUIT").font(Retro.font(6)).foregroundColor(Retro.dim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Retro.bg)
        .overlay(Rectangle().strokeBorder(Retro.neon, lineWidth: 2))
        .onExitCommand { onClose() }
    }

    private func cell(_ i: Int) -> some View {
        Button { onTap(i) } label: {
            Text(model.board[i].map { String($0.rawValue) } ?? " ")
                .font(Retro.font(20))
                .foregroundColor(Retro.neon)
                .frame(width: 60, height: 60)
                .background(Retro.bg)
                .overlay(Rectangle().strokeBorder(Retro.neon.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { model.cellFrames[i] = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, f in model.cellFrames[i] = f }
        })
    }
}

/// Hosts the board in a centered panel and drives the ghost to each AI move.
@MainActor
final class TicTacToeController: NSObject {
    private(set) var isActive = false
    var onClose: (() -> Void)?

    let model = TicTacToeModel()
    private let ghost: GhostCursor
    private let ollama = OllamaClient()
    private var panel: KeyablePanel?
    private var animating = false

    init(ghost: GhostCursor) { self.ghost = ghost }

    func start() {
        model.reset()
        ensurePanel()
        centerPanel()
        isActive = true
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        ghost.park()   // ghost waits near the cursor until it's O's turn
    }

    func close() {
        guard isActive else { return }
        isActive = false
        ghost.hide()
        panel?.orderOut(nil)
        onClose?()
    }

    private func tap(_ i: Int) {
        if model.finished { model.reset(); return }       // tap to play again
        guard !animating, model.current == .x, model.canPlay(i) else { return }

        model.place(i, .x)
        RetroSound.submit()
        if endIfOver() { return }

        // Ghost's turn — Gemma looks at the board and decides.
        model.current = .o
        model.status = "GHOST LOOKING"
        animating = true
        Task { @MainActor in
            let ai = await ghostMove()
            let commit: () -> Void = { [weak self] in
                guard let self else { return }
                self.model.place(ai, .o)
                RetroSound.answer()
                self.animating = false
                if self.endIfOver() { return }
                self.model.current = .x
                self.model.status = "YOUR TURN"
            }
            if let pt = self.cellScreenCenter(ai) {
                self.ghost.glide(to: pt, completion: commit)
            } else {
                commit()
            }
        }
    }

    /// Vision move via Gemma; minimax fallback if it returns nothing legal.
    private func ghostMove() async -> Int {
        if let idx = await visionMove() { return idx }
        return model.bestMove(for: .o)
    }

    /// Screenshot the board, ask Gemma for the best empty cell (0–8).
    private func visionMove() async -> Int? {
        guard let panel else { return nil }
        ghost.hide()   // keep the ghost out of the screenshot
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the latest X render
        guard let png = try? await ScreenCapture.capture(globalRect: panel.frame) else { return nil }

        let prompt = """
        This is a tic-tac-toe board. The 9 cells are numbered 0-8: \
        top row 0 1 2, middle row 3 4 5, bottom row 6 7 8. \
        You play as O against X. Reply with ONLY the single digit (0-8) of the \
        best empty cell for O. No words, just the number.
        """
        let msg = OllamaClient.ChatMessage(role: "user", content: prompt, images: [png.base64EncodedString()])
        guard let reply = try? await ollama.chat(messages: [msg]) else { return nil }

        for ch in reply {
            if let d = ch.wholeNumberValue, (0...8).contains(d), model.board[d] == nil { return d }
        }
        return nil
    }

    private func endIfOver() -> Bool {
        if let w = model.winner() {
            model.finished = true
            model.status = w == .x ? "YOU WIN! TAP TO REPLAY" : "GHOST WINS. TAP TO REPLAY"
            w == .x ? RetroSound.answer() : RetroSound.error()
            return true
        }
        if model.isFull() {
            model.finished = true
            model.status = "DRAW. TAP TO REPLAY"
            RetroSound.close()
            return true
        }
        return false
    }

    /// SwiftUI-global cell center → screen coordinates for the ghost.
    private func cellScreenCenter(_ i: Int) -> NSPoint? {
        guard let panel, let cv = panel.contentView, let f = model.cellFrames[i] else { return nil }
        let center = CGPoint(x: f.midX, y: f.midY)            // top-left origin
        let winPoint = NSPoint(x: center.x, y: cv.bounds.height - center.y)
        return panel.convertPoint(toScreen: winPoint)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let size = NSSize(width: 240, height: 320)
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.onEscape = { [weak self] in self?.close() }

        let host = NSHostingView(rootView: TicTacToeView(
            model: model,
            onTap: { [weak self] i in self?.tap(i) },
            onClose: { [weak self] in self?.close() }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    private func centerPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = panel.frame, v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2))
    }
}
