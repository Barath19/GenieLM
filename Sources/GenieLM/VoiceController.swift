import AVFoundation
import Speech

/// On-device speech-to-text via the Speech framework. Streams partial
/// transcripts and delivers a final string when the user stops or pauses.
/// State is only touched on the main thread (recognizer callbacks hop via
/// DispatchQueue.main), so the class is safe to mark @unchecked Sendable.
final class VoiceController: NSObject, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var listening = false
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    /// Request Speech + Microphone permission, then call `done(granted)` on main.
    func requestAuth(_ done: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { DispatchQueue.main.async { done(false) }; return }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(mic) }
            }
        }
    }

    func start() {
        guard !listening, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { return }
        listening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            // Extract Sendable values off-main, then hop to main.
            let text = result?.bestTranscription.formattedString ?? ""
            let done = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                guard let self, self.listening else { return }
                if !text.isEmpty { self.onPartial?(text) }
                if done { self.finish(text) }
            }
        }
    }

    func stop() {
        guard listening else { return }
        request?.endAudio()          // lets the recognizer emit a final result
    }

    private func finish(_ text: String) {
        guard listening else { return }
        listening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task = nil; request = nil
        onFinal?(text)
    }
}
