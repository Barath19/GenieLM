import Foundation

/// Client for the app-managed local llama.cpp `llama-server` (OpenAI-compatible).
/// The server is launched by `LocalEngine`. Vision works via the gemma mmproj.
struct LlamaClient {
    var base = URL(string: ProcessInfo.processInfo.environment["LLAMA_URL"] ?? "http://127.0.0.1:8080")!
    var model = "local"   // llama-server serves one model; ignored

    struct ChatMessage {
        let role: String
        let content: String
        var images: [String]?   // base64 PNG (no prefix)
    }

    enum ClientError: Error, LocalizedError {
        case serverUnreachable, badStatus(Int, String)
        var errorDescription: String? {
            switch self {
            case .serverUnreachable: return "Local model not ready yet."
            case .badStatus(let c, let b): return "llama-server \(c): \(b)"
            }
        }
    }

    func chat(messages: [ChatMessage]) async throws -> String {
        let oa: [[String: Any]] = messages.map { m in
            if let imgs = m.images, !imgs.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for b in imgs { parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b)"]]) }
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
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw ClientError.serverUnreachable }
        guard let http = response as? HTTPURLResponse else { throw ClientError.serverUnreachable }
        guard http.statusCode == 200 else { throw ClientError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
