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
You are a desktop assistant looking at a screenshot of the user's screen. \
Answer their questions about what is on screen, concisely. Only mention \
buttons, links, or actions that are actually visible; do not invent UI that \
may not exist.
"""

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = ShakeDetector()
    private let overlay = OverlayController()
    private let ghost = GhostCursor()
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
        detector.start()
    }

    /// Shake toggles the chat: open if closed, close if already open.
    private func toggleSession() {
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
    private func startNewSession() {
        guard !busy else { return }
        busy = true
        sessionActive = true
        history = []
        transcript = ""
        pendingImageB64 = nil
        overlay.clearInput()
        overlay.present(hint: "Capturing...")
        overlay.setInputEnabled(false)
        RetroSound.open()

        Task { @MainActor in
            defer { busy = false }
            do {
                let png = try await ScreenCapture.capture(globalRect: nil)
                guard sessionActive else { return }   // closed mid-capture
                pendingImageB64 = png.base64EncodedString()
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
        // Easter-egg command: spawn/dismiss the ghost cursor.
        if question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tic tac toe" {
            ghost.toggle()
            overlay.clearInput()
            overlay.setStatus(ghost.visible ? "GHOST ON" : "GHOST OFF")
            RetroSound.submit()
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

        Task { @MainActor in
            defer { busy = false }
            do {
                let answer = try await ollama.chat(messages: history)
                guard sessionActive else { return }   // closed mid-request
                history.append(OllamaClient.ChatMessage(role: "assistant", content: answer, images: nil))
                transcript += "\n\n\(answer)"
                overlay.render(transcript: transcript)
                overlay.setStatus("SHAKESIGHT")
                RetroSound.answer()
            } catch {
                guard sessionActive else { return }
                transcript += "\n\nERR: \(error.localizedDescription)"
                overlay.render(transcript: transcript)
                overlay.setStatus("ERROR")
                RetroSound.error()
            }
            overlay.setInputEnabled(true)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar agent, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
