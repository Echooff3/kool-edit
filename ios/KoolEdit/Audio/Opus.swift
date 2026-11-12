import AVFoundation
import Foundation

/// Opus where CoreAudio can't follow: an Opus track inside an M4A (the
/// BandLab/Zoom export shape). Apple's audio stack has no Opus decoder at
/// all, so the packets are pulled out of the MP4 boxes by hand and decoded
/// by the vendored libopus (OpusLib/, from opus 1.5.2). Opus always decodes
/// at 48 kHz.
enum Opus {
    /// True when the file holds an Opus track: an `Opus` sample entry in
    /// the sound track's stsd, or an Ogg `OpusHead`.
    static func isOpusFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        if data.range(of: Data("dOps".utf8)) != nil { return true }
        return data.range(of: Data("OpusHead".utf8)) != nil
    }

    // MARK: The MP4 boxes

    /// The Opus packets of the file's sound track, in play order, and the
    /// track's channel count and encoder pre-skip.
    private struct Track {
        var packets: [(offset: Int, size: Int)]
        var channels: Int
        var preSkip: Int
    }

    /// Walks the atom tree: moov → trak → (hdlr soun) mdia → minf → stbl,
    /// reading stsd (the Opus entry with dOps), stsz (packet sizes) and
    /// stsc + stco/co64 (chunk layout) into a packet list.
    private static func readTrack(_ data: Data) throws -> Track {
        var track: Track?
        walkBoxes(data, 0, data.count) { body, type in
            guard type == "moov" else { return false }
            walkBoxes(data, body.lowerBound, body.upperBound) { tBody, tType in
                guard tType == "trak", track == nil else { return false }
                if let found = readTrak(data, tBody) { track = found }
                return true
            }
            return true
        }
        guard let track, !track.packets.isEmpty else {
            throw AudioError.unsupported("No Opus track in this file.")
        }
        return track
    }

    /// One trak: only the ones whose handler is `soun` (hdlr lives inside
    /// mdia), and only Opus ones.
    private static func readTrak(_ data: Data, _ trak: Range<Int>) -> Track? {
        var isSound = false
        var stbl: Range<Int>?
        walkBoxes(data, trak.lowerBound, trak.upperBound) { body, type in
            switch type {
            case "mdia":
                // hdlr and minf both live in here.
                walkBoxes(data, body.lowerBound, body.upperBound) { mBody, mType in
                    switch mType {
                    case "hdlr":
                        // The handler type is the first field after
                        // version/flags and the reserved word.
                        isSound = String(bytes: data[mBody.lowerBound + 8 ..< mBody.lowerBound + 12], encoding: .ascii) == "soun"
                    case "minf":
                        walkBoxes(data, mBody.lowerBound, mBody.upperBound) { sBody, sType in
                            guard sType == "stbl" else { return false }
                            stbl = sBody
                            return true
                        }
                    default: break
                    }
                    return false
                }
            default: break
            }
            return false
        }
        guard isSound, let stbl else { return nil }

        var channels = 2
        var preSkip = 0
        var sizes: [Int] = []
        var chunkEntries: [(firstChunk: Int, samples: Int)] = []
        var chunkOffsets: [Int] = []

        walkBoxes(data, stbl.lowerBound, stbl.upperBound) { body, type in
            switch type {
            case "stsd":
                // stsd: version/flags (4), entry count (4), then entries.
                // An Opus entry's type is "Opus"; the dOps box rides inside
                // it after AudioSampleEntry's fixed fields, carrying the
                // channels and the encoder's pre-skip.
                let entry = body.lowerBound + 8
                let esize = Int(u32(data, entry))
                guard entry + 16 <= body.upperBound,
                      String(bytes: data[entry + 4 ..< entry + 8], encoding: .ascii) == "Opus",
                      esize >= 8, entry + esize <= data.count else { return false }
                if let dOps = data.firstRange(of: Data("dOps".utf8), in: entry + 8 ..< entry + esize - 3) {
                    // dOps body: version(1) channels(1) preSkip(2) rate(4)…
                    // The spec says little-endian, but the encoders that
                    // actually make these files (ffmpeg's muxer, and the
                    // BandLab/Zoom exports through it) write big-endian —
                    // the rate field proves which. Take the reading that
                    // lands inside one Opus frame (≤ 5760); pre-skip is
                    // encoder warm-up, never a third of a second.
                    let at = dOps.lowerBound + 4
                    if data[at] == 0 { channels = max(1, Int(data[at + 1])) }
                    let be = Int(data[at + 2]) << 8 | Int(data[at + 3])
                    let le = Int(data[at + 3]) << 8 | Int(data[at + 2])
                    preSkip = be <= 5_760 ? be : le
                }
            case "stsz":
                // version/flags(4), sample_size(4), sample_count(4); a zero
                // sample_size means per-sample sizes follow.
                let sampleSize = u32(data, body.lowerBound + 4)
                let count = Int(u32(data, body.lowerBound + 8))
                if sampleSize > 0 {
                    sizes = Array(repeating: Int(sampleSize), count: count)
                } else {
                    sizes = (0..<count).map { Int(u32(data, body.lowerBound + 12 + $0 * 4)) }
                }
            case "stsc":
                let count = Int(u32(data, body.lowerBound + 4))
                chunkEntries = (0..<count).map {
                    let at = body.lowerBound + 8 + $0 * 12
                    return (Int(u32(data, at)), Int(u32(data, at + 4)))
                }
            case "stco":
                let count = Int(u32(data, body.lowerBound + 4))
                chunkOffsets = (0..<count).map { Int(u32(data, body.lowerBound + 8 + $0 * 4)) }
            case "co64":
                let count = Int(u32(data, body.lowerBound + 4))
                chunkOffsets = (0..<count).map { Int(u64(data, body.lowerBound + 8 + $0 * 8)) }
            default: break
            }
            return false
        }

        guard !sizes.isEmpty, !chunkOffsets.isEmpty, !chunkEntries.isEmpty, channels > 0 else { return nil }
        // Chunks hold consecutive packets; stsc says how many in each.
        var packets: [(offset: Int, size: Int)] = []
        var nextPacket = 0
        for (i, chunkStart) in chunkOffsets.enumerated() {
            let samplesThisChunk = chunkSamples(chunk: i + 1, entries: chunkEntries)
            var at = chunkStart
            for _ in 0..<samplesThisChunk where nextPacket < sizes.count {
                packets.append((at, sizes[nextPacket]))
                at += sizes[nextPacket]
                nextPacket += 1
            }
        }
        return Track(packets: packets, channels: channels, preSkip: preSkip)
    }

    /// stsc lookup: the entry whose firstChunk is the last one ≤ `chunk`.
    private static func chunkSamples(chunk: Int, entries: [(firstChunk: Int, samples: Int)]) -> Int {
        var samples = 1
        for e in entries where e.firstChunk <= chunk {
            samples = e.samples
        }
        return samples
    }

    // MARK: Box plumbing

    /// Iterates the boxes in `range`; `body` is the box's contents. Returning
    /// true stops the walk.
    private static func walkBoxes(_ data: Data, _ from: Int, _ to: Int, _ visit: (Range<Int>, String) -> Bool) {
        var at = from
        while at + 8 <= to {
            let size = Int(u32(data, at))
            let type = String(bytes: data[at + 4 ..< at + 8], encoding: .ascii) ?? ""
            var body = at + 8 ..< to
            if size == 1 {
                guard at + 16 <= to else { return }
                let big = Int(u64(data, at + 8))
                guard big > 0, at + big <= to else { return }
                body = at + 16 ..< at + big
                at += big
            } else if size == 0 {
                body = at + 8 ..< to
                at = to
            } else if size >= 8, at + size <= to {
                body = at + 8 ..< at + size
                at += size
            } else {
                return
            }
            if visit(body, type) { return }
        }
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16) | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
    }

    private static func u64(_ data: Data, _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(data[at + i]) }
        return v
    }

    // MARK: Decoding

    /// Decodes the Opus track into a 24-bit CAF take and returns its peaks,
    /// exactly what `AudioIO.convert` does for the formats CoreAudio reads.
    static func convert(_ source: URL, to dest: URL) throws -> Peaks {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let track = try readTrack(data)
        let channels = min(track.channels, 2)

        var error: Int32 = 0
        guard let decoder = opus_decoder_create(48_000, Int32(channels), &error), error == 0 else {
            throw AudioError.unsupported("Couldn't start the Opus decoder.")
        }
        defer { opus_decoder_destroy(decoder) }

        let output = try AudioIO.writer(dest, sampleRate: 48_000, channels: channels)
        let out = try AudioIO.buffer(output.processingFormat)
        var builder = PeakBuilder()
        var decoded = false
        var trimmed = track.preSkip
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: 5_760 * channels)
        defer { pcm.deallocate() }

        for packet in track.packets {
            guard packet.size > 0, packet.offset + packet.size <= data.count else { continue }
            let produced = data[packet.offset ..< packet.offset + packet.size].withUnsafeBytes { raw in
                opus_decode(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(packet.size), pcm, 5_760, 0)
            }
            guard produced > 0 else { continue }
            decoded = true
            guard let planes = out.floatChannelData else { continue }
            let producedFrames = Int(produced)
            out.frameLength = AVAudioFrameCount(producedFrames)
            for c in 0..<channels {
                for i in 0..<producedFrames {
                    planes[c][i] = Float(pcm[i * channels + c]) / 32768
                }
            }
            // The encoder's warm-up samples come off the front, once.
            if trimmed > 0 {
                let drop = min(trimmed, Int(out.frameLength))
                let kept = Int(out.frameLength) - drop
                if kept > 0 {
                    memmove(planes[0], planes[0] + drop, kept * MemoryLayout<Float>.size)
                    if channels > 1 { memmove(planes[1], planes[1] + drop, kept * MemoryLayout<Float>.size) }
                }
                out.frameLength = AVAudioFrameCount(kept)
                trimmed -= drop
            }
            if out.frameLength == 0 { continue }
            try output.write(from: out)
            builder.append(out)
        }

        guard decoded, builder.frames > 0 else { throw AudioError.empty }
        return builder.finish()
    }
}