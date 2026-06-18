import Foundation

/// Manages the local llama.cpp `llama-server` so the shipped app is
/// self-contained: downloads the GGUF model on first launch, finds the bundled
/// (or dev) `llama-server`, spawns it, and stops it on quit. No Ollama, no
/// manual setup for the user.
@MainActor
final class LocalEngine {
    static let shared = LocalEngine()

    var onStatus: ((String) -> Void)?
    private var process: Process?
    private let port = 8080

    private let modelFile = "gemma-3-4b-it-Q4_K_M.gguf"
    private let mmprojFile = "mmproj-model-f16.gguf"
    private let repoBase = "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/"

    private var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GenieLM/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Bundled helper first (shipped), then dev fallbacks on PATH.
    private func serverBinary() -> String? {
        if let p = Bundle.main.url(forResource: "llama-server", withExtension: nil, subdirectory: "Helpers")?.path,
           FileManager.default.isExecutableFile(atPath: p) { return p }
        for p in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func start() {
        Task { @MainActor in
            if await healthy() { onStatus?("Local model ready"); return }
            let model = supportDir.appendingPathComponent(modelFile)
            let mmproj = supportDir.appendingPathComponent(mmprojFile)
            do {
                if !FileManager.default.fileExists(atPath: model.path) {
                    onStatus?("Downloading model (~2.5GB)…")
                    try await download(URL(string: repoBase + modelFile)!, to: model)
                }
                if !FileManager.default.fileExists(atPath: mmproj.path) {
                    onStatus?("Downloading vision…")
                    try await download(URL(string: repoBase + mmprojFile)!, to: mmproj)
                }
            } catch { onStatus?("Model download failed"); return }

            guard let bin = serverBinary() else { onStatus?("llama-server missing"); return }
            launch(bin: bin, model: model.path, mmproj: mmproj.path)
            for _ in 0..<60 { if await healthy() { onStatus?("Local model ready"); return }; try? await Task.sleep(nanoseconds: 1_000_000_000) }
            onStatus?("Model failed to start")
        }
    }

    func stop() { process?.terminate(); process = nil }

    private func launch(bin: String, model: String, mmproj: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", model, "--mmproj", mmproj, "--port", "\(port)", "-ngl", "99", "--jinja", "-c", "8192"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); process = p } catch { onStatus?("llama-server failed to launch") }
    }

    private func healthy() async -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        r.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func download(_ url: URL, to dest: URL) async throws {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
