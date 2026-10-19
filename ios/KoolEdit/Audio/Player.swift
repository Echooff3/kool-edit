import AVFoundation
import Observation

/// Plays a take straight from its file: a range, from a point inside it,
/// once or looped. The position is read from the audio clock, so the
/// playhead can be drawn every frame without anything being published.
@Observable @MainActor
final class Player {
    private(set) var isPlaying = false
    private(set) var isLooping = false
    private(set) var meter = Meter()

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var connected: AVAudioFormat?
    @ObservationIgnored private var range: Range<Int64> = 0..<0
    @ObservationIgnored private var from: Int64 = 0
    @ObservationIgnored private var latency: Double = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tapped = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        engine.attach(node)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Headphones in or out: the engine has stopped and needs rewiring.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stop()
                self.connected = nil
                self.removeTap()
            }
        }
    }

    func load(_ url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
    }

    /// Plays `range` starting at `position` (inside it). Looping goes round
    /// the whole range.
    func play(_ range: Range<Int64>, from position: Int64, loop: Bool) {
        guard let file, !range.isEmpty else { return }
        node.stop()
        generation += 1
        self.range = range
        from = min(max(position, range.lowerBound), range.upperBound - 1)
        isLooping = loop
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            latency = session.outputLatency
            if connected != file.processingFormat {
                engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
                connected = file.processingFormat
            }
            installTap()
            if !engine.isRunning { try engine.start() }
        } catch {
            isPlaying = false
            return
        }
        let gen = generation
        schedule(file, from: from, generation: gen)
        if loop { schedule(file, from: range.lowerBound, generation: gen) }
        node.play()
        isPlaying = true
    }

    func stop() {
        generation += 1
        node.stop()
        isPlaying = false
        meter.silence()
    }

    /// Where playback is, in frames into the file (where it started when
    /// stopped).
    var position: Int64 {
        guard isPlaying, let time = node.lastRenderTime, let player = node.playerTime(forNodeTime: time) else { return from }
        let played = max(0, Int64(Double(player.sampleTime) - latency * player.sampleRate))
        let first = range.upperBound - from
        if played < first { return from + played }
        guard isLooping else { return range.upperBound }
        return range.lowerBound + (played - first) % Int64(range.count)
    }

    func resetClips() {
        meter.resetClips()
    }

    private func schedule(_ file: AVAudioFile, from start: Int64, generation gen: Int) {
        let frames = range.upperBound - start
        guard frames > 0 else { return }
        // While looping, the next lap is queued as soon as one is consumed,
        // so there's always one waiting and no gap.
        node.scheduleSegment(
            file, startingFrame: start, frameCount: AVAudioFrameCount(frames), at: nil,
            completionCallbackType: isLooping ? .dataConsumed : .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen, self.isPlaying else { return }
                    if self.isLooping {
                        self.schedule(file, from: self.range.lowerBound, generation: gen)
                    } else {
                        self.from = self.range.upperBound
                        self.stop()
                    }
                }
            }
        }
    }

    private func installTap() {
        guard !tapped else { return }
        tapped = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            let peaks = AudioIO.peaks(of: buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    self.meter.feed(peaks)
                }
            }
        }
    }

    private func removeTap() {
        guard tapped else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        tapped = false
    }
}
