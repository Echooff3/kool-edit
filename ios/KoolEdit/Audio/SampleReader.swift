import AVFoundation

/// Individual samples (channels averaged) for drawing close up, where the
/// peaks are too coarse. Keeps the last stretch it read, a few screens wide.
final class SampleReader {
    private let file: AVAudioFile
    private var cache: [Float] = []
    private var cached: Range<Int64> = 0..<0
    let frames: Int64

    init(url: URL) throws {
        file = try AudioIO.reader(url)
        frames = file.length
    }

    /// The samples in `range` (clamped to the file) and the frame they start at.
    func samples(_ range: Range<Int64>) -> (start: Int64, values: ArraySlice<Float>) {
        let r = max(0, range.lowerBound) ..< min(frames, max(range.upperBound, 0))
        guard !r.isEmpty else { return (r.lowerBound, []) }
        if !(cached.lowerBound <= r.lowerBound && r.upperBound <= cached.upperBound) {
            let span = Int64(r.count)
            load(max(0, r.lowerBound - span) ..< min(frames, r.upperBound + span))
        }
        let a = Int(r.lowerBound - cached.lowerBound)
        let b = min(cache.count, Int(r.upperBound - cached.lowerBound))
        guard a < b else { return (r.lowerBound, []) }
        return (r.lowerBound, cache[a..<b])
    }

    private func load(_ range: Range<Int64>) {
        cache.removeAll(keepingCapacity: true)
        cache.reserveCapacity(range.count)
        try? AudioIO.forEachChunk(of: file, in: range) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
            let k = 1 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                cache.append(sum * k)
            }
        }
        cached = range.lowerBound ..< range.lowerBound + Int64(cache.count)
    }
}
