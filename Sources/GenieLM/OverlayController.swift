import AppKit
import SwiftUI

/// A non-activating panel that can still accept keyboard focus. Esc dismisses it.
final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Observable state shared with the SwiftUI bubble.
@MainActor
final class BubbleModel: ObservableObject {
    @Published var title = "👁 GenieLM"
    @Published var transcript = ""
    @Published var inputText = ""
    @Published var inputEnabled = false
    @Published var shown = false
    @Published var focusTick = 0   // bump to (re)request keyboard focus
    @Published var image: NSImage?   // captured snip shown atop the chat

    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    func submit() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSubmit?(t)
    }
}

/// 8-bit / CRT-terminal palette + font.
enum Retro {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let neon = Color(red: 0.23, green: 1.0, blue: 0.34)
    static let dim = Color(red: 0.23, green: 1.0, blue: 0.34).opacity(0.45)
    /// Bundled arcade pixel font; falls back to monospaced if unregistered.
    static func font(_ size: CGFloat) -> Font {
        .custom("Press Start 2P", size: size)
    }
}

/// A slim chat-input box attached to the cursor, 8-bit themed. The answer panel
/// only appears below once there's a reply. Bounce via SwiftUI's `.bouncy` spring.
struct ChatBubbleView: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The captured snip, shown on top.
            if let img = model.image {
                // Fit within 340x220 while preserving aspect, so the frame hugs
                // the image (no transparent bars showing the desktop through).
                let aspect = img.size.width / max(img.size.height, 1)
                let w = min(340, 220 * aspect)
                let h = w / aspect
                Image(nsImage: img)
                    .resizable()
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.45), radius: 5)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            // The input box — the entire UI when there's no answer yet.
            HStack(spacing: 6) {
                Text(">").foregroundColor(Retro.neon)
                TextField("", text: $model.inputText,
                          prompt: Text(model.inputEnabled ? "ASK ABOUT YOUR SCREEN" : model.title.uppercased())
                            .foregroundColor(Retro.dim))
                    .textFieldStyle(.plain)
                    .foregroundColor(Retro.neon)
                    .focused($focused)
                    .disabled(!model.inputEnabled)
                    .onSubmit { model.submit() }
            }
            .font(Retro.font(9))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Retro.bg)
            .overlay(Rectangle().strokeBorder(Retro.neon, lineWidth: 2))
            .shadow(color: Retro.neon.opacity(0.18), radius: 0, x: 2, y: 2)

            // Answer panel — appears only after a reply, expands downward.
            if !model.transcript.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.transcript)
                            .font(Retro.font(8))
                            .foregroundColor(Retro.neon)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: model.transcript) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .padding(10)
                .background(Retro.bg)
                .overlay(Rectangle().strokeBorder(Retro.neon, lineWidth: 2))
                .shadow(color: Retro.neon.opacity(0.18), radius: 0, x: 2, y: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(model.shown ? 1 : 0.6, anchor: .top)
        .opacity(model.shown ? 1 : 0)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.35), value: model.shown)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.2), value: model.transcript.isEmpty)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.2), value: model.image != nil)
        .onChange(of: model.inputEnabled) { _, enabled in focused = enabled }
        .onChange(of: model.focusTick) { _, _ in if model.inputEnabled { focused = true } }
        .onExitCommand { model.onClose?() }
    }
}

/// Bridges the AppKit panel (window placement, cursor-follow) to the SwiftUI bubble.
@MainActor
final class OverlayController: NSObject {
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let model = BubbleModel()
    private var panel: KeyablePanel?

    // Cursor-follow state.
    private var following = false
    private var moveMonitors: [Any] = []

    /// Show the bubble glued to the pointer and follow the cursor. No model call.
    func present(hint: String) {
        ensurePanel()
        model.title = hint          // shown as the pill placeholder while disabled
        model.transcript = ""       // no answer card until there's a reply
        model.image = nil
        model.shown = false
        panel?.makeKeyAndOrderFront(nil)
        startFollowing()
        forceRender()
        // Flip on next runloop so the spring animates from the collapsed state.
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    func setStatus(_ status: String) { model.title = status; forceRender() }
    func render(transcript: String) { model.transcript = transcript; forceRender() }
    func setImage(_ image: NSImage?) {
        model.image = image
        forceRender()
    }
    func clearInput() { model.inputText = "" }

    /// Resize the window to fit the SwiftUI content and re-anchor to the cursor.
    /// The app is a background agent, so we flush layout immediately rather than
    /// waiting for the next event.
    private func forceRender() {
        guard let panel, let host = panel.contentView else { return }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        if fit.width > 1, fit.height > 1 {
            let new = NSSize(width: ceil(fit.width), height: ceil(fit.height))
            if panel.frame.size != new {
                var f = panel.frame; f.size = new
                panel.setFrame(f, display: true)
            }
        }
        glueToPointer()
        panel.displayIfNeeded()
    }

    func setInputEnabled(_ enabled: Bool) {
        model.inputEnabled = enabled
        if enabled {
            panel?.makeKeyAndOrderFront(nil)
            model.focusTick += 1
        }
        forceRender()
    }

    func hide() {
        stopFollowing()
        model.shown = false
        let p = panel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)   // let the out-spring play
            p?.orderOut(nil)
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() {
        if panel != nil { return }

        model.onSubmit = { [weak self] text in self?.onSubmit?(text) }
        model.onClose = { [weak self] in self?.onClose?() }

        let size = NSSize(width: 356, height: 72)   // initial; resized to fit content
        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false         // SwiftUI draws shadows on the pill/card
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.onEscape = { [weak self] in self?.onClose?() }

        let host = NSHostingView(rootView: ChatBubbleView(model: model))
        host.sizingOptions = [.intrinsicContentSize]   // size to SwiftUI content, not the window
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host

        self.panel = p
    }

    // MARK: - Cursor follow (always attached to the pointer)

    private func startFollowing() {
        guard !following else { glueToPointer(); return }
        following = true
        let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.glueToPointer() }
        })
        if let g { moveMonitors.append(g) }
        let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.glueToPointer() }
            return event
        })
        if let l { moveMonitors.append(l) }
        glueToPointer()
    }

    private func stopFollowing() {
        following = false
        moveMonitors.forEach { NSEvent.removeMonitor($0) }
        moveMonitors.removeAll()
    }

    /// Glue the bubble just below-right of the cursor tip, clamped on screen.
    private func glueToPointer() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        var origin = NSPoint(x: mouse.x + 6, y: mouse.y - frame.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vis = screen.visibleFrame
            origin.x = min(max(origin.x, vis.minX), vis.maxX - frame.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - frame.height)
        }
        panel.setFrameOrigin(origin)
    }
}
