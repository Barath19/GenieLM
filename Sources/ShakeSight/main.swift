import AppKit
import CoreText

/// Register the bundled pixel font so SwiftUI's Font.custom can find it.
func registerBundledFonts() {
    if let url = Bundle.main.url(forResource: "PressStart2P-Regular", withExtension: "ttf", subdirectory: "Fonts")
        ?? Bundle.main.url(forResource: "PressStart2P-Regular", withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

let systemPrompt = """
You are a helpful desktop assistant. A screenshot of the user's screen is \
attached only as optional context. Respond directly and conversationally to \
what the user actually says. Do NOT describe the screen unless the user asks \
about it. If they just greet you or chat, reply normally. Be concise, and \
never invent UI that isn't visible.
"""

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = ShakeDetector()
    private let overlay = OverlayController()
    private let ghost = GhostCursor()
    private let snipper = CmdDragSnipper()
    private lazy var game = DrawGameController(ghost: ghost)
    private let ollama = OllamaClient()
    private var statusItem: NSStatusItem?
    private var busy = false
    private var sessionActive = false

    // Conversation state for the current screenshot.
    private var pendingImageB64: String?
    private var history: [OllamaClient.ChatMessage] = []
    private var transcript = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        setupStatusItem()
        detector.onShake = { [weak self] in self?.toggleSession() }
        overlay.onSubmit = { [weak self] question in self?.ask(question) }
        overlay.onClose = { [weak self] in self?.closeSession() }
        snipper.onSnip = { [weak self] rect in self?.startNewSession(region: rect) }
        detector.start()
        snipper.start()
    }

    /// Shake toggles the chat (or closes the game if it's running).
    private func toggleSession() {
        if game.isActive { game.close(); RetroSound.close(); return }
        if sessionActive { closeSession() } else { startNewSession() }
    }

    private func closeSession() {
        sessionActive = false   // invalidates any in-flight completion
        busy = false
        ghost.hide()            // dismiss the ghost cursor with the chat
        RetroSound.close()
        overlay.hide()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "👁"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open chat now", action: #selector(openMenu), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Snip: hold ⌘ + drag", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle ghost cursor", action: #selector(toggleGhost), keyEquivalent: "g"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShakeSight", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openMenu() { startNewSession() }
    @objc private func toggleGhost() { ghost.toggle(); RetroSound.submit() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Shake (or menu): capture the screen silently and open the chat at the
    /// pointer. No model call yet — we wait for the user's question.
    private func startNewSession(region: CGRect? = nil) {
        guard !busy else { return }
        busy = true
        sessionActive = true
        history = []
        transcript = ""
        pendingImageB64 = nil
        overlay.clearInput()
        overlay.present(hint: region == nil ? "Capturing..." : "Reading snip...")
        overlay.setInputEnabled(false)
        RetroSound.open()

        Task { @MainActor in
            defer { busy = false }
            do {
                let png = try await ScreenCapture.capture(globalRect: region)
                guard sessionActive else { return }   // closed mid-capture
                let img = NSImage(data: png)
                print("[snip] region=\(String(describing: region)) png=\(png.count)B image=\(img != nil) size=\(img?.size ?? .zero)")
                pendingImageB64 = png.base64EncodedString()
                overlay.setImage(region == nil ? nil : img)   // only show the snip, not full screen
                overlay.setStatus("SHAKESIGHT")
                overlay.setInputEnabled(true)   // just the pill until they ask
            } catch {
                guard sessionActive else { return }
                overlay.render(transcript: "ERR: \(error.localizedDescription)")
                overlay.setStatus("ERROR")
                RetroSound.error()
            }
        }
    }

    /// A question. The first one carries the screenshot; later ones reuse context.
    private func ask(_ question: String) {
        // Easter-egg command: play tic-tac-toe against the ghost.
        if question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tic tac toe" {
            overlay.clearInput()
            sessionActive = false
            busy = false
            overlay.hide()
            game.start()
            RetroSound.open()
            return
        }

        guard !busy else { return }
        busy = true
        overlay.clearInput()
        overlay.setInputEnabled(false)

        // The first question clears the "Screen captured" hint.
        if history.isEmpty { transcript = "" }
        transcript += transcript.isEmpty ? "> \(question)" : "\n\n> \(question)"
        overlay.render(transcript: transcript)
        overlay.setStatus("THINKING...")
        RetroSound.submit()

        // Build the next user turn, attaching the image on the first turn only.
        if history.isEmpty {
            history.append(OllamaClient.ChatMessage(role: "system", content: systemPrompt, images: nil))
            history.append(OllamaClient.ChatMessage(role: "user", content: question, images: pendingImageB64.map { [$0] }))
        } else {
            history.append(OllamaClient.ChatMessage(role: "user", content: question, images: nil))
        }

        print("[chat] asking: \(question) (history=\(history.count))")
        Task { @MainActor in
            defer { busy = false }
            do {
                let answer = try await ollama.chat(messages: history)
                guard sessionActive else { return }   // closed mid-request
                print("[chat] answer: \(answer.prefix(120))")
                history.append(OllamaClient.ChatMessage(role: "assistant", content: answer, images: nil))
                transcript += "\n\n\(answer)"
                overlay.render(transcript: transcript)
                overlay.setStatus("SHAKESIGHT")
                RetroSound.answer()
            } catch {
                guard sessionActive else { return }
                print("[chat] error: \(error.localizedDescription)")
                transcript += "\n\nERR: \(error.localizedDescription)"
                overlay.render(transcript: transcript)
                overlay.setStatus("ERROR")
                RetroSound.error()
            }
            overlay.setInputEnabled(true)
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered logs when stdout is a file

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar agent, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
