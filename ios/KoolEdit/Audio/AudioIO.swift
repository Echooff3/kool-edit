import Accelerate
import AVFoundation

enum AudioError: LocalizedError {
    case noInput
    case empty
    case cannotAllocate
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noInput: "There's no audio input to record from."
        case .empty: "There's no audio in it."
        case .cannotAllocate: "Couldn't set aside memory for the audio."
        case .unsupported(let why): why
        }
    }
}

/// Reading and writing takes' audio. Takes are 24-bit PCM CAF files, worked
/// on as 32-bit float a chunk at a time, so an hour-long jam never has to fit
/// in memory.
enum AudioIO {
    static let chunk: AVAudioFrameCount = 32_768

    static func pcmSettings(sampleRate: Double, channels: Int, bits: Int = 24, float: Bool = false) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: float,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func reader(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// A new take file (24-bit CAF), written from 32-bit float buffers.
    static func writer(_ url: URL, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url, settings: pcmSettings(sampleRate: sampleRate, channels: channels),
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    static func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = chunk) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw AudioError.cannotAllocate }
        return buffer
    }

    /// Calls `body` with each chunk of `range` and the frame the chunk starts at.
    static func forEachChunk(of file: AVAudioFile, in range: Range<Int64>, _ body: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        guard !range.isEmpty else { return }
        let buffer = try buffer(file.processingFormat)
        file.framePosition = range.lowerBound
        var at = range.lowerBound
        while at < range.upperBound {
            let want = AVAudioFrameCount(min(Int64(chunk), range.upperBound - at))
            try file.read(into: buffer, frameCount: want)
            if buffer.frameLength == 0 { break }
            try body(buffer, at)
            at += Int64(buffer.frameLength)
        }
    }

    /// Copies `src` into `dst`, which may have a different channel count:
    /// stereo mixes down to mono, mono repeats into stereo, and channels past
    /// the second are dropped.
    static func copy(_ src: AVAudioPCMBuffer, into dst: AVAudioPCMBuffer) {
        let n = Int(min(src.frameLength, dst.frameCapacity))
        dst.frameLength = AVAudioFrameCount(n)
        guard n > 0, let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        let sc = Int(src.format.channelCount), dc = Int(dst.format.channelCount)
        if dc == 1 && sc > 1 {
            memcpy(d[0], s[0], n * MemoryLayout<Float>.size)
            for c in 1..<sc { vDSP_vadd(d[0], 1, s[c], 1, d[0], 1, vDSP_Length(n)) }
            var k = 1 / Float(sc)
            vDSP_vsmul(d[0], 1, &k, d[0], 1, vDSP_Length(n))
        } else {
            for c in 0..<dc { memcpy(d[c], s[min(c, sc - 1)], n * MemoryLayout<Float>.size) }
        }
    }

    /// The loudest sample of each channel.
    static func peaks(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<Int(buffer.format.channelCount)).map { c in
            var v: Float = 0
            vDSP_maxmgv(data[c], 1, &v, vDSP_Length(buffer.frameLength))
            return v
        }
    }

    /// Converts any audio file iOS can read into a take (24-bit CAF, at most
    /// two channels) and returns its peaks.
    static func convert(_ source: URL, to dest: URL) throws -> Peaks {
        let input = try reader(source)
        let format = input.processingFormat
        guard format.channelCount > 0, format.sampleRate > 0, input.length > 0 else { throw AudioError.empty }
        let output = try writer(dest, sampleRate: format.sampleRate, channels: min(Int(format.channelCount), 2))
        let out = try buffer(output.processingFormat)
        var builder = PeakBuilder()
        try forEachChunk(of: input, in: 0..<input.length) { buffer, _ in
            copy(buffer, into: out)
            try output.write(from: out)
            builder.append(out)
        }
        guard builder.frames > 0 else { throw AudioError.empty }
        return builder.finish()
    }

    /// Writes `source` again at another sample rate and channel count (for
    /// pasting between takes), returning the frames written.
    @discardableResult
    static func conform(_ source: URL, to dest: URL, sampleRate: Double, channels: Int) throws -> Int64 {
        let input = try reader(source)
        let output = try writer(dest, sampleRate: sampleRate, channels: channels)
        let inBuffer = try buffer(input.processingFormat)
        // Counted as written: an open file's length lags behind its writes.
        var written: Int64 = 0
        if input.processingFormat.sampleRate == sampleRate {
            let out = try buffer(output.processingFormat)
            try forEachChunk(of: input, in: 0..<input.length) { buffer, _ in
                copy(buffer, into: out)
                try output.write(from: out)
                written += Int64(out.frameLength)
            }
            return written
        }
        // Match the channels first, then the rate.
        guard let mid = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: input.processingFormat.sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false),
            let converter = AVAudioConverter(from: mid, to: output.processingFormat)
        else { throw AudioError.unsupported("Can't convert between these sample rates.") }
        let midBuffer = try buffer(mid)
        let ratio = sampleRate / input.processingFormat.sampleRate
        let out = try buffer(output.processingFormat, frames: AVAudioFrameCount(Double(chunk) * max(ratio, 1)) + 1024)
        var finished = false
        while true {
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if finished || input.framePosition >= input.length {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer, frameCount: chunk)
                } catch {
                    finished = true
                }
                if finished || inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                copy(inBuffer, into: midBuffer)
                inputStatus.pointee = .haveData
                return midBuffer
            }
            if status == .error { throw error ?? AudioError.unsupported("Sample rate conversion failed.") }
            if out.frameLength > 0 {
                try output.write(from: out)
                written += Int64(out.frameLength)
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return written
    }
}
