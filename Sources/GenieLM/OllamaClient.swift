import Foundation

/// Minimal client for a local Ollama server running a vision model (gemma3:4b).
/// Streams nothing fancy: one request, one response.
struct OllamaClient {
    var host = URL(string: "http://127.0.0.1:11434")!
    var model = "gemma3:4b"

    /// One chat turn. `images` are base64 PNGs (no data: prefix) and are only
    /// attached to the first user turn; later turns reference them via context.
    struct ChatMessage: Codable {
        let role: String          // "user" | "assistant" | "system"
        let content: String
        var images: [String]?     // omitted from JSON when nil
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    struct ChatResponse: Decodable {
        let message: ChatMessage
    }

    enum ClientError: Error, LocalizedError {
        case serverUnreachable
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable:
                return "Can't reach Ollama at 127.0.0.1:11434. Is `ollama serve` running?"
            case .badStatus(let code, let body):
                return "Ollama returned \(code): \(body)"
            }
        }
    }

    /// Sends the full conversation (screenshot pinned to the first turn) and
    /// returns the assistant's reply. Stateless: caller owns the history.
    func chat(messages: [ChatMessage]) async throws -> String {
        let req = ChatRequest(model: model, messages: messages, stream: false)

        var urlReq = URLRequest(url: host.appendingPathComponent("api/chat"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONEncoder().encode(req)
        urlReq.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlReq)
        } catch {
            throw ClientError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.serverUnreachable
        }
        guard http.statusCode == 200 else {
            throw ClientError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
