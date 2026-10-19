import Accelerate
import AVFoundation

/// Effects for the selection (or the whole take when nothing is selected),
/// the same set as the macOS app.
enum Effect: Equatable {
    case silence
    case fadeIn
    case fadeOut
    /// Peak normalize to -0.1 dBFS.
    case normalize
    case amplify(dB: Float)
    case reverse
    case invert

    var name: String {
        switch self {
        case .silence: "Silence"
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .normalize: "Normalize"
        case .amplify: "Amplify"
        case .reverse: "Reverse"
        case .invert: "Invert"
        }
    }
}

/// An edit to a take's audio. Every edit writes a new file (the old one
/// stays behind for undo), streaming a chunk at a time.
enum EditOp {
    case delete(Range<Int64>)
    case trim(Range<Int64>)
    /// Puts the audio at `clip` (`frames` long, already in the take's
    /// format) in place of `range`; an empty range inserts.
    case paste(clip: URL, frames: Int64, at: Range<Int64>)
    case effect(Effect, Range<Int64>)

    var name: String {
        switch self {
        case .delete: "Delete"
        case .trim: "Trim"
        case .paste: "Paste"
        case .effect(let e, _): e.name
        }
    }

    /// Where markers end up after the edit; markers in removed audio go.
    func moved(_ markers: [Marker]) -> [Marker] {
        func replace(_ r: Range<Int64>, with frames: Int64) -> [Marker] {
            markers.compactMap { m in
                if m.frame < r.lowerBound || (r.isEmpty && m.frame == r.lowerBound) { return m }
                if m.frame < r.upperBound { return nil }
                var m = m
                m.frame += frames - Int64(r.count)
                return m
            }
        }
        switch self {
        case .delete(let r):
            return replace(r, with: 0)
        case .trim(let r):
            return markers.filter { r.contains($0.frame) }.map { var m = $0; m.frame -= r.lowerBound; return m }
        case .paste(_, let frames, let r):
            return replace(r, with: frames)
        case .effect(.reverse, let r):
            return markers.map { m in
                guard r.contains(m.frame) else { return m }
                var m = m
                m.frame = r.lowerBound + r.upperBound - 1 - m.frame
                return m
            }
        case .effect:
            return markers
        }
    }
}

enum Edits {
    /// Renders `op` applied to the audio at `source` into a new file at `dest`.
    static func render(_ op: EditOp, from source: URL, to dest: URL) throws -> Peaks {
        let input = try AudioIO.reader(source)
        let format = input.processingFormat
        let output = try AudioIO.writer(dest, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        var sink = Sink(file: output)
        let total = input.length

        switch op {
        case .delete(let r):
            try copy(input, 0 ..< r.lowerBound, to: &sink)
            try copy(input, r.upperBound ..< total, to: &sink)
        case .trim(let r):
            try copy(input, r, to: &sink)
        case .paste(let clip, _, let r):
            try copy(input, 0 ..< r.lowerBound, to: &sink)
            let clipFile = try AudioIO.reader(clip)
            try copy(clipFile, 0 ..< clipFile.length, to: &sink)
            try copy(input, r.upperBound ..< total, to: &sink)
        case .effect(.reverse, let r):
            try copy(input, 0 ..< r.lowerBound, to: &sink)
            try reversed(input, r, to: &sink)
            try copy(input, r.upperBound ..< total, to: &sink)
        case .effect(let effect, let r):
            let g = try gain(for: effect, over: r, in: input)
            try copy(input, 0 ..< total, to: &sink) { buffer, at in
                apply(g, to: buffer, at: at, over: r)
            }
        }
        return sink.finish()
    }

    /// Gain at frame `f` of the range (as a fraction of the way through it).
    private enum Gain {
        case constant(Float)
        case ramp(from: Float, to: Float)
    }

    private static func gain(for effect: Effect, over r: Range<Int64>, in input: AVAudioFile) throws -> Gain {
        switch effect {
        case .silence: return .constant(0)
        case .fadeIn: return .ramp(from: 0, to: 1)
        case .fadeOut: return .ramp(from: 1, to: 0)
        case .normalize:
            let peak = try self.peak(of: input, in: r)
            return .constant(peak > 1e-9 ? pow(10, -0.1 / 20) / peak : 1)
        case .amplify(let dB): return .constant(pow(10, dB / 20))
        case .invert: return .constant(-1)
        case .reverse: return .constant(1)
        }
    }

    private static func apply(_ gain: Gain, to buffer: AVAudioPCMBuffer, at: Int64, over r: Range<Int64>) {
        let lo = max(r.lowerBound, at), hi = min(r.upperBound, at + Int64(buffer.frameLength))
        guard lo < hi, let data = buffer.floatChannelData else { return }
        let offset = Int(lo - at), n = vDSP_Length(hi - lo)
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = data[c] + offset
            switch gain {
            case .constant(var k):
                vDSP_vsmul(samples, 1, &k, samples, 1, n)
            case .ramp(let from, let to):
                // Linear, like the macOS app: 0 at the first frame, 1 at the last.
                let span = Float(max(r.count, 2) - 1)
                var start = from + (to - from) * Float(lo - r.lowerBound) / span
                var step = (to - from) / span
                var ramp = [Float](repeating: 0, count: Int(n))
                vDSP_vramp(&start, &step, &ramp, 1, n)
                vDSP_vmul(samples, 1, ramp, 1, samples, 1, n)
            }
        }
    }

    private static func peak(of file: AVAudioFile, in r: Range<Int64>) throws -> Float {
        var peak: Float = 0
        try AudioIO.forEachChunk(of: file, in: r) { buffer, _ in
            peak = max(peak, AudioIO.peaks(of: buffer).max() ?? 0)
        }
        return peak
    }

    private static func copy(
        _ input: AVAudioFile, _ range: Range<Int64>, to sink: inout Sink,
        process: ((AVAudioPCMBuffer, Int64) -> Void)? = nil
    ) throws {
        try AudioIO.forEachChunk(of: input, in: range) { buffer, at in
            process?(buffer, at)
            try sink.write(buffer)
        }
    }

    /// Writes `r` backwards, reading it a chunk at a time from the end.
    private static func reversed(_ input: AVAudioFile, _ r: Range<Int64>, to sink: inout Sink) throws {
        let buffer = try AudioIO.buffer(input.processingFormat)
        var end = r.upperBound
        while end > r.lowerBound {
            let start = max(r.lowerBound, end - Int64(AudioIO.chunk))
            input.framePosition = start
            try input.read(into: buffer, frameCount: AVAudioFrameCount(end - start))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<Int(buffer.format.channelCount) {
                vDSP_vrvrs(data[c], 1, vDSP_Length(buffer.frameLength))
            }
            try sink.write(buffer)
            end = start
        }
    }
}

/// The new file and its peaks, built as it's written.
private struct Sink {
    let file: AVAudioFile
    var builder = PeakBuilder()

    init(file: AVAudioFile) {
        self.file = file
    }

    mutating func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
        builder.append(buffer)
    }

    mutating func finish() -> Peaks {
        builder.finish()
    }
}
