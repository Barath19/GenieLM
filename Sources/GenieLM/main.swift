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
    private let genie = GenieCursor()
    private let snipper = CmdDragSnipper()
    private lazy var game = DrawGameController(genie: genie)
    private let ollama = OllamaClient()
    private let pioneer = PioneerClient()
    private let voice = VoiceController()
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
        overlay.onMic = { [weak self] in self?.toggleVoice() }
        snipper.onSnip = { [weak self] rect in self?.startNewSession(region: rect) }
        detector.start()
        snipper.start()
    }

    /// Tap the mic in the chat: transcribe speech, then route it like a typed
    /// message (question → Gemma, command → grounder).
    private func toggleVoice() {
        if voice.listening { voice.stop(); return }
        voice.requestAuth { [weak self] ok in
            MainActor.assumeIsolated {          // delivered on the main queue
                guard let self else { return }
                guard ok else {
                    self.overlay.render(transcript: "Grant Microphone + Speech Recognition\n(System Settings → Privacy), then relaunch.")
                    return
                }
                self.overlay.clearInput()
                self.overlay.setListening(true)
                self.voice.onPartial = { [weak self] t in
                    MainActor.assumeIsolated { self?.overlay.setInputText(t) }
                }
                self.voice.onFinal = { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.overlay.setListening(false)
                        let q = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.overlay.clearInput()
                        if !q.isEmpty { self.ask(q) }
                    }
                }
                self.voice.start()
            }
        }
    }

    /// Shake toggles the chat (or closes the game if it's running).
    private func toggleSession() {
        if game.isActive { game.close(); RetroSound.close(); return }
        if sessionActive { closeSession() } else { startNewSession() }
    }

    private func closeSession() {
        sessionActive = false   // invalidates any in-flight completion
        busy = false
        genie.hide()            // dismiss the genie cursor with the chat
        RetroSound.close()
        overlay.hide()
    }

    /// "do <instruction>": dump the frontmost app, ask Pioneer which element to
    /// act on, then the genie glides there and clicks it.
    private func performAction(_ instruction: String) {
        guard !busy else { return }
        overlay.clearInput()
        guard AccessibilityDumper.isTrusted else {
            overlay.render(transcript: "Grant Accessibility permission\n(System Settings → Privacy → Accessibility), then relaunch.")
            AccessibilityDumper.requestPermission()
            return
        }
        busy = true
        sessionActive = true
        transcript = "> do \(instruction)"
        overlay.render(transcript: transcript)
        overlay.setStatus("LOOKING...")
        overlay.setInputEnabled(false)
        RetroSound.submit()

        let (app, els) = AccessibilityDumper.dumpFrontmost()
        let listText = AccessibilityDumper.serialize(els)

        Task { @MainActor in
            defer { busy = false }
            do {
                let choice = try await pioneer.ground(elements: listText, instruction: instruction)
                guard sessionActive else { return }
                guard choice.action != "none", let id = choice.id, id >= 0, id < els.count else {
                    transcript += "\n\nNo matching element in \(app)."
                    overlay.render(transcript: transcript); overlay.setStatus("GENIELM")
                    overlay.setInputEnabled(true); RetroSound.error(); return
                }
                let el = els[id]
                transcript += "\n\n→ \(choice.action) [\(id)] \"\(el.label)\""
                overlay.render(transcript: transcript); overlay.setStatus("GENIELM")
                let cg = el.center
                genie.glide(to: ScreenAction.cgToAppKit(cg)) {
                    ScreenAction.click(atCG: cg)
                    RetroSound.answer()
                }
                overlay.setInputEnabled(true)
            } catch {
                guard sessionActive else { return }
                transcript += "\n\nERR: \(error.localizedDescription)"
                overlay.render(transcript: transcript); overlay.setStatus("ERROR")
                overlay.setInputEnabled(true); RetroSound.error()
            }
        }
    }

    /// "auto <goal>": agentic loop — observe (a11y) → decide (Pioneer) → act
    /// (genie click/type) → re-observe, until done or a step cap. Abort by
    /// shaking / Esc (clears sessionActive).
    private func automate(_ goal: String) {
        guard !busy else { return }
        overlay.clearInput()
        guard AccessibilityDumper.isTrusted else {
            overlay.render(transcript: "Grant Accessibility permission\n(System Settings → Privacy → Accessibility), then relaunch.")
            AccessibilityDumper.requestPermission()
            return
        }
        busy = true
        sessionActive = true
        transcript = "> auto \(goal)"
        overlay.render(transcript: transcript)
        overlay.setInputEnabled(false)
        RetroSound.submit()

        Task { @MainActor in
            defer { busy = false; overlay.setInputEnabled(true) }
            var history: [String] = []
            let maxSteps = 8
            for step in 1...maxSteps {
                guard sessionActive else { return }   // aborted
                overlay.setStatus("STEP \(step)...")
                let (app, els) = AccessibilityDumper.dumpFrontmost()
                let listText = AccessibilityDumper.serialize(els)

                let choice: PioneerClient.Choice
                do { choice = try await pioneer.nextStep(goal: goal, elements: listText, history: history) }
                catch {
                    transcript += "\n\nERR: \(error.localizedDescription)"
                    overlay.render(transcript: transcript); overlay.setStatus("ERROR"); RetroSound.error(); return
                }
                guard sessionActive else { return }

                if choice.done {
                    transcript += "\n\nDONE: \(choice.reason ?? "goal reached")"
                    overlay.render(transcript: transcript); overlay.setStatus("GENIELM"); RetroSound.answer(); return
                }
                guard let id = choice.id, id >= 0, id < els.count else {
                    transcript += "\n\nSTUCK: \(choice.reason ?? "no matching element in \(app)")"
                    overlay.render(transcript: transcript); overlay.setStatus("GENIELM"); RetroSound.error(); return
                }

                let el = els[id]
                let line = "\(step). \(choice.action) [\(id)] \"\(el.label)\"" + (choice.text.map { " = \"\($0)\"" } ?? "")
                transcript += "\n\n\(line)"
                overlay.render(transcript: transcript)
                history.append(line)

                let cg = el.center
                let act = choice.action, text = choice.text
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    genie.glide(to: ScreenAction.cgToAppKit(cg)) {
                        ScreenAction.click(atCG: cg)
                        if act == "type", let t = text { ScreenAction.type(t) }
                        RetroSound.submit()
                        cont.resume()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)   // let the UI settle
            }
            transcript += "\n\n(step limit reached)"
            overlay.render(transcript: transcript); overlay.setStatus("GENIELM")
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "👁"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open chat now", action: #selector(openMenu), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Snip: hold ⌘ + drag", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle genie cursor", action: #selector(toggleGenie), keyEquivalent: "g"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GenieLM", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openMenu() { startNewSession() }
    @objc private func toggleGenie() { genie.toggle(); RetroSound.submit() }
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
                overlay.setStatus("GENIELM")
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
        // Agentic loop: "auto <goal>" → observe→decide→act→repeat until done.
        let qt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if qt.lowercased().hasPrefix("auto ") {
            automate(String(qt.dropFirst(5)))
            return
        }

        // Single action: "do <instruction>" → ground via Pioneer → genie clicks it.
        if qt.lowercased().hasPrefix("do ") {
            performAction(String(qt.dropFirst(3)))
            return
        }

        // Dev command: dump the frontmost app's accessibility tree to a file.
        if question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dump" {
            overlay.clearInput()
            guard AccessibilityDumper.isTrusted else {
                overlay.render(transcript: "Grant Accessibility permission\n(System Settings → Privacy → Accessibility), then relaunch.")
                AccessibilityDumper.requestPermission()
                return
            }
            let (app, els) = AccessibilityDumper.dumpFrontmost()
            let text = AccessibilityDumper.serialize(els)
            try? text.write(toFile: "/tmp/a11y.txt", atomically: true, encoding: .utf8)
            print("[a11y] app=\(app) elements=\(els.count) -> /tmp/a11y.txt")
            print("[a11y]\n\(text)")
            overlay.render(transcript: "Dumped \(els.count) elements from \(app)\n→ /tmp/a11y.txt")
            return
        }

        // Easter-egg command: play tic-tac-toe against the genie.
        if question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tic tac toe" {
            overlay.clearInput()
            sessionActive = false
            busy = false
            overlay.hide()
            game.start()
            RetroSound.open()
            return
        }

        // Default: auto-intent routing (no keyword needed).
        route(qt)
    }

    /// Auto-intent: decide whether a plain message is a QUESTION (answer about
    /// the screen) or an ACTION (click/type an element), and route accordingly.
    private func route(_ q: String) {
        guard !busy else { return }
        let lc = q.lowercased()
        let questionish = lc.contains("?")
            || ["what", "why", "how", "who", "when", "where", "which", "explain",
                "summar", "tell me", "describe", "is ", "are ", "can ", "could ",
                "should ", "does ", "what's", "whats"].contains { lc.hasPrefix($0) }
        // Questions (or no Accessibility access) → vision chat; never act.
        if questionish || !AccessibilityDumper.isTrusted {
            chatAboutScreen(q)
            return
        }

        busy = true
        sessionActive = true
        overlay.clearInput()
        transcript = "> \(q)"
        overlay.render(transcript: transcript)
        overlay.setStatus("READING SCREEN...")
        overlay.setInputEnabled(false)

        let (_, els) = AccessibilityDumper.dumpFrontmost()
        let list = AccessibilityDumper.serialize(els)
        Task { @MainActor in
            do {
                let choice = try await pioneer.ground(elements: list, instruction: q)
                guard sessionActive else { busy = false; return }
                if choice.action != "none", let id = choice.id, id >= 0, id < els.count {
                    let el = els[id]
                    transcript += "\n\n→ \(choice.action) [\(id)] \"\(el.label)\""
                    overlay.render(transcript: transcript); overlay.setStatus("GENIELM")
                    let cg = el.center, act = choice.action, text = choice.text
                    genie.glide(to: ScreenAction.cgToAppKit(cg)) {
                        ScreenAction.click(atCG: cg)
                        if act == "type", let t = text { ScreenAction.type(t) }
                        RetroSound.answer()
                    }
                    overlay.setInputEnabled(true)
                    busy = false
                } else {
                    busy = false
                    chatAboutScreen(q)   // no UI match → answer as a question
                }
            } catch {
                busy = false
                chatAboutScreen(q)       // grounding failed → fall back to chat
            }
        }
    }

    /// Answer a question about the captured screenshot (local Gemma vision).
    private func chatAboutScreen(_ question: String) {
        guard !busy else { return }
        busy = true
        overlay.clearInput()
        overlay.setInputEnabled(false)

        if history.isEmpty { transcript = "" }
        transcript += transcript.isEmpty ? "> \(question)" : "\n\n> \(question)"
        overlay.render(transcript: transcript)
        overlay.setStatus("THINKING...")
        RetroSound.submit()

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
                guard sessionActive else { return }
                print("[chat] answer: \(answer.prefix(120))")
                history.append(OllamaClient.ChatMessage(role: "assistant", content: answer, images: nil))
                transcript += "\n\n\(answer)"
                overlay.render(transcript: transcript)
                overlay.setStatus("GENIELM")
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
