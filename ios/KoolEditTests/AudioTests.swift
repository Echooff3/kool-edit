import AVFoundation
import Foundation
import Testing
@testable import KoolEdit

/// A take-format file holding `samples` in every channel.
private func audioFile(_ samples: [Float], rate: Double = 48_000, channels: Int = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
    let file = try AudioIO.writer(url, sampleRate: rate, channels: channels)
    let buffer = try AudioIO.buffer(file.processingFormat, frames: AVAudioFrameCount(samples.count))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for c in 0..<channels {
        for (i, v) in samples.enumerated() { buffer.floatChannelData![c][i] = v }
    }
    try file.write(from: buffer)
    return url
}

/// The first channel of a file.
private func samples(_ url: URL) throws -> [Float] {
    let file = try AudioIO.reader(url)
    var out: [Float] = []
    try AudioIO.forEachChunk(of: file, in: 0..<file.length) { buffer, _ in
        out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return out
}

private func scratch(_ ext: String = "caf") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
}

/// A ramp from 0 up to just under 1, so every sample says where it came from.
private func ramp(_ n: Int) -> [Float] {
    (0..<n).map { Float($0) / Float(n) }
}

/// 24-bit files round to steps of 2^-23.
private let lsb: Float = 2e-7

struct PeaksTests {
    @Test func everyBucketHoldsItsLowestAndHighestSample() throws {
        let n = Peaks.base * 40 + 17
        let values = (0..<n).map { Float(($0 * 7919) % 1000) / 500 - 1 }
        let url = try audioFile(values)
        let peaks = try Peaks.scan(url)
        #expect(peaks.frames == Int64(n))
        for (from, to) in [(0, n), (3, Peaks.base * 4 + 5), (Peaks.base, Peaks.base * 3), (n - 10, n)] {
            let slice = values[from..<to]
            // A whole number of buckets either side, so compare with the buckets' extremes.
            let a = from / Peaks.base * Peaks.base, b = min(n, (to + Peaks.base - 1) / Peaks.base * Peaks.base)
            let wide = values[a..<b]
            let m = try #require(peaks.minMax(from: Double(from), to: Double(to), framesPerPixel: 1))
            #expect(abs(m.lo - wide.min()!) < lsb && abs(m.hi - wide.max()!) < lsb)
            #expect(m.lo <= slice.min()! + lsb && m.hi >= slice.max()! - lsb)
        }
    }

    @Test func coarseLevelsAgreeWithTheFineOnes() throws {
        let n = Peaks.base * Peaks.factor * Peaks.factor * 3
        let values = (0..<n).map { sin(Float($0) * 0.001) * Float($0 % 977) / 977 }
        let peaks = try Peaks.scan(try audioFile(values))
        #expect(peaks.levels.count >= 3)
        let fine = try #require(peaks.minMax(from: 0, to: Double(n), framesPerPixel: 1))
        let coarse = try #require(peaks.minMax(from: 0, to: Double(n), framesPerPixel: Double(n)))
        #expect(fine.lo == coarse.lo && fine.hi == coarse.hi)
    }

    @Test func peaksRoundTripThroughDisk() throws {
        let peaks = try Peaks.scan(try audioFile(ramp(10_000)))
        let url = scratch("peaks")
        try peaks.write(to: url)
        let back = try #require(Peaks.read(from: url, frames: 10_000))
        #expect(back.levels == peaks.levels)
        // Peaks for another length of audio are stale.
        #expect(Peaks.read(from: url, frames: 9_999) == nil)
    }

    @Test func overviewIsScaledToTheLoudestColumn() throws {
        let quiet = (0..<48_000).map { i in Float(i % 2 == 0 ? 0.2 : -0.2) * Float(i) / 48_000 }
        let overview = try Peaks.scan(try audioFile(quiet)).overview(columns: 10)
        #expect(overview.count == 10)
        #expect(overview.last! >= 250)
        #expect(overview.first! < overview.last!)
    }
}

struct EditTests {
    @Test func trimKeepsOnlyTheSelection() throws {
        let source = try audioFile(ramp(48_000))
        let out = scratch()
        let peaks = try Edits.render(.trim(1_000..<5_000), from: source, to: out)
        let result = try samples(out)
        #expect(peaks.frames == 4_000 && result.count == 4_000)
        #expect(abs(result[0] - 1_000 / 48_000) < lsb)
        #expect(abs(result[3_999] - 4_999 / 48_000) < lsb)
    }

    @Test func deleteClosesTheGap() throws {
        let source = try audioFile(ramp(48_000))
        let out = scratch()
        _ = try Edits.render(.delete(10_000..<20_000), from: source, to: out)
        let result = try samples(out)
        #expect(result.count == 38_000)
        #expect(abs(result[9_999] - 9_999 / 48_000) < lsb)
        #expect(abs(result[10_000] - 20_000 / 48_000) < lsb)
    }

    @Test func pasteInsertsOrReplaces() throws {
        let source = try audioFile(ramp(1_000))
        let clip = try audioFile([Float](repeating: -0.5, count: 100))
        let inserted = scratch()
        _ = try Edits.render(.paste(clip: clip, frames: 100, at: 500..<500), from: source, to: inserted)
        let a = try samples(inserted)
        #expect(a.count == 1_100)
        #expect(a[499] > 0 && a[500] == -0.5 && a[599] == -0.5 && abs(a[600] - 0.5) < lsb)
        let replaced = scratch()
        _ = try Edits.render(.paste(clip: clip, frames: 100, at: 200..<800), from: source, to: replaced)
        let b = try samples(replaced)
        #expect(b.count == 500)
        #expect(b[200] == -0.5 && abs(b[300] - 0.8) < lsb)
    }

    @Test func fadesRampLinearlyAcrossTheSelection() throws {
        let source = try audioFile([Float](repeating: 0.5, count: 2_001))
        let fadedIn = scratch(), fadedOut = scratch()
        _ = try Edits.render(.effect(.fadeIn, 1_000..<2_001), from: source, to: fadedIn)
        _ = try Edits.render(.effect(.fadeOut, 0..<1_001), from: source, to: fadedOut)
        let i = try samples(fadedIn), o = try samples(fadedOut)
        #expect(abs(i[999] - 0.5) < lsb && abs(i[1_000]) < lsb && abs(i[1_500] - 0.25) < 1e-4 && abs(i[2_000] - 0.5) < lsb)
        #expect(abs(o[0] - 0.5) < lsb && abs(o[500] - 0.25) < 1e-4 && abs(o[1_000]) < lsb && abs(o[1_001] - 0.5) < lsb)
    }

    @Test func normalizeBringsThePeakToMinusPointOneDB() throws {
        let source = try audioFile((0..<4_800).map { 0.25 * sin(Float($0) * 0.05) })
        let out = scratch()
        let peaks = try Edits.render(.effect(.normalize, 0..<4_800), from: source, to: out)
        let target = pow(10, Float(-0.1) / 20)
        let loudest = try samples(out).map(abs).max()!
        #expect(abs(loudest - target) < 1e-5)
        #expect(abs(max(abs(peaks.levels.last![0]), peaks.levels.last![1]) - target) < 1e-5)
    }

    @Test func amplifyInvertAndSilence() throws {
        let source = try audioFile([Float](repeating: 0.25, count: 1_000))
        let louder = scratch(), inverted = scratch(), silenced = scratch()
        _ = try Edits.render(.effect(.amplify(dB: 6.0206), 0..<1_000), from: source, to: louder)
        _ = try Edits.render(.effect(.invert, 0..<500), from: source, to: inverted)
        _ = try Edits.render(.effect(.silence, 100..<200), from: source, to: silenced)
        #expect(abs(try samples(louder)[10] - 0.5) < 1e-4)
        let i = try samples(inverted)
        #expect(i[0] == -0.25 && i[499] == -0.25 && i[500] == 0.25)
        let s = try samples(silenced)
        #expect(s[99] == 0.25 && s[100] == 0 && s[199] == 0 && s[200] == 0.25)
    }

    @Test func reverseFlipsJustTheSelection() throws {
        let n = 100_000
        let source = try audioFile(ramp(n))
        let out = scratch()
        _ = try Edits.render(.effect(.reverse, 10_000..<90_000), from: source, to: out)
        let r = try samples(out)
        #expect(r.count == n)
        #expect(abs(r[9_999] - 9_999 / Float(n)) < lsb)
        #expect(abs(r[10_000] - 89_999 / Float(n)) < lsb)
        #expect(abs(r[89_999] - 10_000 / Float(n)) < lsb)
        #expect(abs(r[90_000] - 90_000 / Float(n)) < lsb)
    }

    @Test func markersFollowTheAudio() {
        let marks = [100, 500, 900].map { Marker(frame: Int64($0), name: "\($0)") }
        #expect(EditOp.delete(400..<600).moved(marks).map(\.frame) == [100, 700])
        #expect(EditOp.trim(400..<1_000).moved(marks).map(\.frame) == [100, 500])
        #expect(EditOp.paste(clip: URL(fileURLWithPath: "/"), frames: 50, at: 500..<500).moved(marks).map(\.frame) == [100, 500, 950])
        #expect(EditOp.paste(clip: URL(fileURLWithPath: "/"), frames: 50, at: 450..<550).moved(marks).map(\.frame) == [100, 850])
        #expect(EditOp.effect(.reverse, 0..<1_000).moved(marks).map(\.frame) == [899, 499, 99])
        #expect(EditOp.effect(.fadeIn, 0..<1_000).moved(marks).map(\.frame) == [100, 500, 900])
    }

    @Test func conformChangesChannelsAndRate() throws {
        let stereo = try audioFile([Float](repeating: 0.5, count: 4_410), rate: 44_100, channels: 2)
        let mono = scratch()
        let frames = try AudioIO.conform(stereo, to: mono, sampleRate: 48_000, channels: 1)
        let file = try AudioIO.reader(mono)
        #expect(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 48_000)
        #expect(abs(frames - 4_800) < 64)
        #expect(file.length == frames)
        #expect(abs(try samples(mono)[2_000] - 0.5) < 1e-3)
    }

    @Test func importConvertsToATake() throws {
        // A 16-bit WAV, as another app might hand over.
        let wav = scratch("wav")
        do {
            // Closed (finished) when this scope ends.
            let file = try AVAudioFile(forWriting: wav, settings: AudioIO.pcmSettings(sampleRate: 44_100, channels: 2, bits: 16), commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try AudioIO.buffer(file.processingFormat, frames: 1_000)
            buffer.frameLength = 1_000
            for c in 0..<2 { for i in 0..<1_000 { buffer.floatChannelData![c][i] = 0.25 } }
            try file.write(from: buffer)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let take = try Library.importAudio(wav, into: root)
        #expect(take.info.frames == 1_000 && take.info.channels == 2 && take.info.sampleRate == 44_100)
        #expect(take.info.overview.count == Take.overviewColumns)
        #expect(Peaks.read(from: take.peaksURL, frames: 1_000) != nil)
    }
}

struct ExportTests {
    @Test func wavHoldsExactlyTheSelection() throws {
        let source = try audioFile(ramp(48_000))
        let url = try Exporter.export(source, range: 12_000..<24_000, format: .wav24, name: "Jam: take/1", smoothEdges: false)
        #expect(url.lastPathComponent == "Jam- take-1.wav")
        let out = try samples(url)
        #expect(out.count == 12_000)
        #expect(abs(out[0] - 0.25) < lsb)
    }

    @Test func smoothEdgesFadeTheEnds() throws {
        let source = try audioFile([Float](repeating: 0.5, count: 48_000))
        let url = try Exporter.export(source, range: 0..<48_000, format: .wav24, name: "x", smoothEdges: true)
        let out = try samples(url)
        #expect(abs(out[0]) < 1e-3 && abs(out[47_999]) < 0.01 && abs(out[24_000] - 0.5) < lsb)
    }

    @Test func m4aIsAboutTheRightLength() throws {
        let source = try audioFile((0..<96_000).map { 0.3 * sin(Float($0) * 0.06) })
        let url = try Exporter.export(source, range: 0..<48_000, format: .m4a, name: "clip", smoothEdges: true)
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 48_000) < 2_048)
        #expect(url.pathExtension == "m4a")
    }
}

struct ViewTests {
    @Test func zoomKeepsTheFrameUnderTheFingerStill() {
        var v = Viewport(start: 1_000, scale: 100)
        let before = v.frame(at: 150)
        v.zoom(by: 4, at: 150, width: 400, frames: 1_000_000)
        #expect(abs(v.frame(at: 150) - before) < 1e-6)
        #expect(v.scale == 25)
    }

    @Test func viewStaysInsideTheTake() {
        var v = Viewport(start: -500, scale: 1e9)
        v.clamp(width: 400, frames: 48_000)
        #expect(v.start == 0 && v.scale == 120)
        v = Viewport(start: 47_990, scale: 10)
        v.clamp(width: 400, frames: 48_000)
        #expect(v.start == 44_000)
        v = Viewport(start: 0, scale: 0.0001)
        v.clamp(width: 400, frames: 48_000)
        #expect(v.scale == Viewport.closest)
    }

    @Test func timesFormatAndParseLikeTheMacApp() {
        #expect(TimeFormat.clock(0) == "0:00.000")
        #expect(TimeFormat.clock(83.2567) == "1:23.257")
        #expect(TimeFormat.clock(3725.5, decimals: 1) == "1:02:05.5")
        #expect(TimeFormat.clock(59.9999) == "1:00.000")
        #expect(TimeFormat.clock(12, decimals: 0) == "0:12")
        #expect(TimeFormat.parse("1:23.257") == 83.257)
        #expect(TimeFormat.parse("83.5") == 83.5)
        #expect(TimeFormat.parse("1:02:05.5") == 3725.5)
        #expect(TimeFormat.parse("abc") == nil)
        #expect(TimeFormat.parse("1.5:00") == nil)
        #expect(TimeFormat.stamp(123) == "2m03s")
        #expect(TimeFormat.span(3 * 3600 + 120) == "3h 02m")
    }

    @Test func rulerLabelsStaySpacedOut() {
        let (step, _) = TimeFormat.rulerStep(secondsPerPoint: 0.01, spacing: 76)
        #expect(step == 1)
        #expect(TimeFormat.ruler(65, step: 1) == "1:05")
        #expect(TimeFormat.ruler(0.25, step: 0.05) == "0:00.25")
    }

    @Test func meterHoldsPeaksAndLatchesClips() {
        var m = Meter()
        let t0 = Date()
        m.feed([1.0, 0.1], now: t0)
        #expect(m.clipped == [true, false])
        #expect(abs(m.db[0]) < 0.01 && abs(m.db[1] + 20) < 0.01)
        m.feed([0, 0], now: t0.addingTimeInterval(0.25))
        #expect(abs(m.db[0] + 6) < 0.01)
        #expect(m.hold[0] > -0.01)
        m.resetClips()
        #expect(m.clipped == [false, false])
    }
}
