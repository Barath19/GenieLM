import AppKit

/// Calls Pioneer (OpenAI-compatible) to ground an instruction against a text
/// list of screen elements. Key/model come from the environment.
struct PioneerClient {
    var base = URL(string: ProcessInfo.processInfo.environment["PIONEER_API_URL"] ?? "https://api.pioneer.ai")!
    var model = ProcessInfo.processInfo.environment["PIONEER_MODEL"] ?? "claude-haiku-4-5"
    var apiKey: String? { ProcessInfo.processInfo.environment["PIONEER_API_KEY"] }

    struct Choice { let action: String; let id: Int?; let text: String?; let done: Bool; let reason: String? }

    enum ClientError: Error, LocalizedError {
        case noKey, bad(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "No PIONEER_API_KEY in environment (relaunch with it set)."
            case .bad(let c, let b): return "Pioneer \(c): \(b)"
            }
        }
    }

    /// Single-shot grounding: one instruction → one element.
    func ground(elements: String, instruction: String) async throws -> Choice {
        let system = """
        You are a UI grounding model. Given a numbered list of on-screen elements \
        (label + pixel center) and an instruction, pick the single best element. \
        Reply with ONLY JSON: {"action":"click"|"type","id":<int>,"text":<string if typing>}. \
        If nothing matches, reply {"action":"none"}.
        """
        return try await decide(system: system, user: "Elements:\n\(elements)\n\nInstruction: \(instruction)")
    }

    /// Agentic step: given a goal + current elements + history, pick the NEXT action.
    func nextStep(goal: String, elements: String, history: [String]) async throws -> Choice {
        let system = """
        You are a screen-automation agent working toward a GOAL. You see the current \
        on-screen elements (label + pixel center) and the actions already taken. \
        Decide the SINGLE next action. Reply with ONLY JSON: \
        {"action":"click"|"type"|"done","id":<int>,"text":<string if typing>,"done":<bool>,"reason":<short>}. \
        Set "done":true when the goal is already accomplished. Prefer the fewest steps.
        """
        let hist = history.isEmpty ? "(none yet)" : history.enumerated().map { "\($0+1). \($1)" }.joined(separator: "\n")
        let user = "GOAL: \(goal)\n\nActions so far:\n\(hist)\n\nCurrent elements:\n\(elements)"
        return try await decide(system: system, user: user)
    }

    private func decide(system: String, user: String) async throws -> Choice {
        guard let apiKey else { throw ClientError.noKey }
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": 200,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.bad(0, "no response") }
        guard http.statusCode == 200 else { throw ClientError.bad(http.statusCode, String(data: data, encoding: .utf8) ?? "") }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        print("[agent] raw: \(content.replacingOccurrences(of: "\n", with: " "))")

        guard let s = content.firstIndex(of: "{"), let e = content.lastIndex(of: "}") else {
            return Choice(action: "none", id: nil, text: nil, done: false, reason: nil)
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(content[s...e].utf8))) as? [String: Any]
        return Choice(action: json?["action"] as? String ?? "none",
                      id: (json?["id"] as? NSNumber)?.intValue,
                      text: json?["text"] as? String,
                      done: (json?["done"] as? NSNumber)?.boolValue ?? (json?["action"] as? String == "done"),
                      reason: json?["reason"] as? String)
    }
}

/// Performs real mouse/keyboard actions on screen (needs Accessibility perms).
@MainActor
enum ScreenAction {
    /// Click at a CoreGraphics global point (top-left origin) — what a11y returns.
    static func click(atCG p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Type unicode text at the current focus via synthesized key events.
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var chars = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
    }

    /// CG top-left global → AppKit bottom-left global (for the genie cursor).
    static func cgToAppKit(_ p: CGPoint) -> NSPoint {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens[0]
        return NSPoint(x: p.x, y: primary.frame.height - p.y)
    }
}
