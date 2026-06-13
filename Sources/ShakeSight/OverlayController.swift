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
    @Published var title = "👁 ShakeSight"
    @Published var transcript = ""
    @Published var inputText = ""
    @Published var inputEnabled = false
    @Published var shown = false
    @Published var focusTick = 0   // bump to (re)request keyboard focus

    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    func submit() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSubmit?(t)
    }
}

/// A slim chat-input pill attached to the cursor. The answer card only appears
/// below the pill once there's a reply; otherwise the rest stays invisible.
/// Bounce is a one-liner via SwiftUI's `.bouncy` spring (interruptible).
struct ChatBubbleView: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The input pill — the entire UI when there's no answer yet.
            TextField(model.inputEnabled ? "Ask about your screen…" : model.title,
                      text: $model.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .focused($focused)
                .disabled(!model.inputEnabled)
                .onSubmit { model.submit() }

            // Answer card — appears only after a reply, expands downward.
            if !model.transcript.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.transcript)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: model.transcript) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 340, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .scaleEffect(model.shown ? 1 : 0.6, anchor: .top)
        .opacity(model.shown ? 1 : 0)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.35), value: model.shown)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.2), value: model.transcript.isEmpty)
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
        model.shown = false
        panel?.makeKeyAndOrderFront(nil)
        startFollowing()
        glueToPointer()
        // Flip on next runloop so the spring animates from the collapsed state.
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    func setStatus(_ status: String) { model.title = status }
    func render(transcript: String) { model.transcript = transcript }
    func clearInput() { model.inputText = "" }

    func setInputEnabled(_ enabled: Bool) {
        model.inputEnabled = enabled
        if enabled {
            panel?.makeKeyAndOrderFront(nil)
            model.focusTick += 1
        }
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

        let size = NSSize(width: 360, height: 360)
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
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
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
