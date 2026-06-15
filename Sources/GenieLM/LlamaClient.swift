import Foundation

/// Minimal client for a local llama.cpp `llama-server` (OpenAI-compatible).
/// Replaces the old Ollama backend. Vision works when the server is started
/// with a multimodal model + mmproj (e.g. gemma-3-4b-it + its mmproj).
///
/// Start it with:
///   llama-server -hf ggml-org/gemma-3-4b-it-GGUF --port 8080 -ngl 99 --jinja
struct LlamaClient {
    var base = URL(string: ProcessInfo.processInfo.environment["LLAMA_URL"] ?? "http://127.0.0.1:8080")!
    /// Kept for API parity; llama-server serves a single model, so it's ignored.
    var model = "local"

    /// One chat turn. `images` are base64 PNGs (no data: prefix), attached to
    /// the first user turn; later turns reference them via context.
    struct ChatMessage {
        let role: String          // "user" | "assistant" | "system"
        let content: String
        var images: [String]?
    }

    enum ClientError: Error, LocalizedError {
        case serverUnreachable
        case badStatus(Int, String)
        var errorDescription: String? {
            switch self {
            case .serverUnreachable:
                return "Can't reach llama-server. Is it running? (llama-server -hf ggml-org/gemma-3-4b-it-GGUF --port 8080)"
            case .badStatus(let code, let body):
                return "llama-server returned \(code): \(body)"
            }
        }
    }

    func chat(messages: [ChatMessage]) async throws -> String {
        // Build OpenAI-format messages. Images become content parts (data URLs).
        let oa: [[String: Any]] = messages.map { m in
            if let imgs = m.images, !imgs.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for b in imgs {
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:image/png;base64,\(b)"]])
                }
                return ["role": m.role, "content": parts]
            }
            return ["role": m.role, "content": m.content]
        }
        let body: [String: Any] = ["model": model, "messages": oa, "stream": false, "temperature": 0]

        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw ClientError.serverUnreachable }

        guard let http = response as? HTTPURLResponse else { throw ClientError.serverUnreachable }
        guard http.statusCode == 200 else {
            throw ClientError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
