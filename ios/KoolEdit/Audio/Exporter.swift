import Accelerate
import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case m4a
    case wav16
    case wav24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4a: "M4A (AAC)"
        case .wav16: "WAV, 16-bit"
        case .wav24: "WAV, 24-bit"
        }
    }

    var detail: String {
        switch self {
        case .m4a: "Small, plays anywhere. Best for texts and email."
        case .wav16: "Lossless, CD quality."
        case .wav24: "Lossless, studio quality."
        }
    }

    var fileExtension: String { self == .m4a ? "m4a" : "wav" }

    /// Roughly how many bytes a second of audio takes.
    func bytesPerSecond(sampleRate: Double, channels: Int) -> Double {
        switch self {
        case .m4a: Double(bitRate(channels: channels)) / 8
        case .wav16: sampleRate * 2 * Double(channels)
        case .wav24: sampleRate * 3 * Double(channels)
        }
    }

    func bitRate(channels: Int) -> Int { channels > 1 ? 256_000 : 128_000 }
}

enum Exporter {
    /// Short fades on the ends of a shared clip so it doesn't start or stop
    /// with a click: 5 ms.
    static let edgeFade = 0.005

    /// Writes `range` of the audio at `source` to a new file called `name`,
    /// in a temporary folder of its own (so the name survives sharing).
    static func export(
        _ source: URL, range: Range<Int64>, format: ExportFormat, name: String, smoothEdges: Bool
    ) throws -> URL {
        let input = try AudioIO.reader(source)
        let rate = input.processingFormat.sampleRate
        let channels = Int(input.processingFormat.channelCount)
        let settings: [String: Any]
        switch format {
        case .m4a:
            guard rate <= 48_000 else {
                throw AudioError.unsupported("M4A goes up to 48 kHz and this take is \(Int(rate)) Hz. Share it as WAV instead.")
            }
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: format.bitRate(channels: channels),
            ]
        case .wav16:
            settings = AudioIO.pcmSettings(sampleRate: rate, channels: channels, bits: 16)
        case .wav24:
            settings = AudioIO.pcmSettings(sampleRate: rate, channels: channels, bits: 24)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(name)).appendingPathExtension(format.fileExtension)
        // Scoped so the file is closed (and complete) before it's shared.
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let fade = smoothEdges ? min(Int64(rate * edgeFade), Int64(range.count) / 2) : 0
            try AudioIO.forEachChunk(of: input, in: range) { buffer, at in
                if fade > 0 {
                    ramp(buffer, at: at, over: range.lowerBound ..< range.lowerBound + fade, rising: true)
                    ramp(buffer, at: at, over: range.upperBound - fade ..< range.upperBound, rising: false)
                }
                try output.write(from: buffer)
            }
        }
        return url
    }

    /// Removes the temporary files from earlier exports.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Share"))
    }

    /// `name` with the characters file systems and share targets dislike
    /// swapped out.
    static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Kool Edit" : String(trimmed.prefix(120))
    }

    private static func ramp(_ buffer: AVAudioPCMBuffer, at: Int64, over r: Range<Int64>, rising: Bool) {
        let lo = max(r.lowerBound, at), hi = min(r.upperBound, at + Int64(buffer.frameLength))
        guard lo < hi, let data = buffer.floatChannelData else { return }
        let span = Float(max(r.count, 1))
        let offset = Int(lo - at), n = Int(hi - lo)
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<n {
                let u = Float(lo - r.lowerBound + Int64(i)) / span
                data[c][offset + i] *= rising ? u : 1 - u
            }
        }
    }
}
