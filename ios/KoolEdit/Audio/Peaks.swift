import AVFoundation

/// The waveform at a glance: the lowest and highest sample (of any channel)
/// in every `base` frames, plus coarser levels each `factor` times wider, so
/// a view at any zoom draws from a handful of buckets per pixel. Saved beside
/// the audio so takes open instantly.
struct Peaks {
    static let base = 64
    static let factor = 16

    /// Frames of audio summarized.
    let frames: Int64
    /// `levels[k]` holds (min, max) pairs for buckets of `bucketFrames(k)` frames.
    let levels: [[Float]]

    init(frames: Int64, base level0: [Float]) {
        self.frames = frames
        var levels = [level0]
        while let last = levels.last, last.count > 2 {
            let n = last.count / 2
            var next = [Float]()
            next.reserveCapacity((n / Peaks.factor + 1) * 2)
            var i = 0
            while i < n {
                let end = min(i + Peaks.factor, n)
                var lo = last[2 * i], hi = last[2 * i + 1]
                for j in i + 1 ..< end {
                    lo = min(lo, last[2 * j])
                    hi = max(hi, last[2 * j + 1])
                }
                next.append(lo)
                next.append(hi)
                i = end
            }
            levels.append(next)
        }
        self.levels = levels
    }

    static func bucketFrames(_ level: Int) -> Double {
        Double(base) * pow(Double(factor), Double(level))
    }

    /// The lowest and highest sample in frames `from..<to`, read from the
    /// coarsest level whose buckets still fit in `framesPerPixel`.
    func minMax(from: Double, to: Double, framesPerPixel: Double) -> (lo: Float, hi: Float)? {
        var level = 0
        while level + 1 < levels.count, Peaks.bucketFrames(level + 1) <= framesPerPixel { level += 1 }
        let size = Peaks.bucketFrames(level)
        let data = levels[level]
        let count = data.count / 2
        let a = max(0, Int(from / size))
        let b = min(count, max(a + 1, Int((to / size).rounded(.up))))
        guard a < b else { return nil }
        var lo = data[2 * a], hi = data[2 * a + 1]
        var i = a + 1
        while i < b {
            lo = min(lo, data[2 * i])
            hi = max(hi, data[2 * i + 1])
            i += 1
        }
        return (lo, hi)
    }

    /// A tiny waveform for the take list: the loudest point of each column,
    /// scaled up so quiet takes still show their shape.
    func overview(columns: Int) -> [UInt8] {
        guard frames > 0, columns > 0 else { return [] }
        let per = Double(frames) / Double(columns)
        let peaks: [Float] = (0..<columns).map { i in
            guard let m = minMax(from: Double(i) * per, to: Double(i + 1) * per, framesPerPixel: per) else { return 0 }
            return max(abs(m.lo), abs(m.hi))
        }
        let loudest = peaks.max() ?? 0
        let gain = loudest > 0 ? min(1 / loudest, 8) : 1
        return peaks.map { UInt8(min(255, ($0 * gain * 255).rounded())) }
    }

    // MARK: Saving

    private static let magic = Array("KEPK".utf8)

    func write(to url: URL) throws {
        var data = Data(Peaks.magic)
        let level0 = levels[0]
        withUnsafeBytes(of: UInt32(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frames.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(level0.count).littleEndian) { data.append(contentsOf: $0) }
        level0.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    /// The peaks saved for audio of `frames` frames, or nil if they're
    /// missing or belong to another version of the audio.
    static func read(from url: URL, frames: Int64) -> Peaks? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 24,
              Array(data.prefix(4)) == magic
        else { return nil }
        let version: UInt32 = data.integer(at: 4)
        let saved: Int64 = data.integer(at: 8)
        let count: Int64 = data.integer(at: 16)
        guard version == 1, saved == frames, count >= 0, data.count == 24 + Int(count) * 4 else { return nil }
        var level0 = [Float](repeating: 0, count: Int(count))
        level0.withUnsafeMutableBytes { _ = data.copyBytes(to: $0, from: 24 ..< data.count) }
        return Peaks(frames: frames, base: level0)
    }

    /// Reads a whole file to work out its peaks.
    static func scan(_ url: URL) throws -> Peaks {
        let file = try AudioIO.reader(url)
        var builder = PeakBuilder()
        try AudioIO.forEachChunk(of: file, in: 0..<file.length) { buffer, _ in builder.append(buffer) }
        return builder.finish()
    }
}

/// Builds `Peaks` from audio as it's written.
struct PeakBuilder {
    private(set) var frames: Int64 = 0
    private var data: [Float] = []
    private var lo = Float.greatestFiniteMagnitude
    private var hi = -Float.greatestFiniteMagnitude
    private var filled = 0

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var i = 0
        while i < n {
            let take = min(Peaks.base - filled, n - i)
            for c in 0..<count {
                let samples = channels[c]
                for j in i ..< i + take {
                    let v = samples[j]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            filled += take
            i += take
            if filled == Peaks.base { flush() }
        }
        frames += Int64(n)
    }

    private mutating func flush() {
        data.append(lo)
        data.append(hi)
        lo = .greatestFiniteMagnitude
        hi = -.greatestFiniteMagnitude
        filled = 0
    }

    mutating func finish() -> Peaks {
        if filled > 0 { flush() }
        return Peaks(frames: frames, base: data)
    }
}

extension Data {
    fileprivate func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { _ = self.copyBytes(to: $0, from: offset ..< offset + MemoryLayout<T>.size) }
        return T(littleEndian: value)
    }
}
