import AVFoundation

/// Synthesizes 8-bit square-wave blips in memory (no bundled audio files) and
/// plays them. Tiny chiptune cues for open / submit / answer / close / error.
@MainActor
enum RetroSound {
    private static let sampleRate = 44100.0
    private static var players: [AVAudioPlayer] = []

    static func open()   { play([(660, 0.05), (880, 0.07)]) }            // rising boop-beep
    static func submit() { play([(988, 0.045)]) }                        // quick high blip
    static func answer() { play([(784, 0.05), (1047, 0.08)]) }           // pleasant up
    static func close()  { play([(523, 0.05), (392, 0.06)]) }            // descending
    static func error()  { play([(196, 0.14)], volume: 0.22) }           // low buzz

    static func play(_ notes: [(freq: Double, dur: Double)], volume: Double = 0.16) {
        let data = wav(notes: notes, volume: volume)
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.play()
        players.append(player)
        if players.count > 8 { players.removeFirst(players.count - 8) }  // bound retained players
    }

    // MARK: - Synthesis

    private static func wav(notes: [(freq: Double, dur: Double)], volume: Double) -> Data {
        var samples: [Int16] = []
        let amp = volume * Double(Int16.max)
        for note in notes {
            let n = Int(note.dur * sampleRate)
            let attack = Int(0.005 * sampleRate)
            let release = Int(0.012 * sampleRate)
            for i in 0..<n {
                let phase = (Double(i) * note.freq / sampleRate).truncatingRemainder(dividingBy: 1.0)
                var s = phase < 0.5 ? amp : -amp
                if i < attack { s *= Double(i) / Double(attack) }              // de-click attack
                if i > n - release { s *= Double(n - i) / Double(release) }     // de-click release
                samples.append(Int16(max(-32767, min(32767, s))))
            }
        }
        return pcmToWAV(samples)
    }

    private static func pcmToWAV(_ samples: [Int16]) -> Data {
        let sr = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sr * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataSize = UInt32(samples.count * 2)

        var d = Data()
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels); u32(sr); u32(byteRate); u16(blockAlign); u16(bits)
        ascii("data"); u32(dataSize)
        for s in samples { var x = s.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        return d
    }
}
