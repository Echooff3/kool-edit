import AVFoundation
import Observation

/// Records a new take from the current input. The input is metered from
/// the moment the recorder opens, so levels can be set before recording.
/// Recording carries on with the screen locked.
@Observable @MainActor
final class Recorder {
    enum State { case off, ready, recording }

    private(set) var state = State.off
    private(set) var frames: Int64 = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var channels = 1
    private(set) var meter = Meter()
    /// Recent peaks (0...1), newest last, for the scrolling waveform.
    private(set) var recent: [Float] = []
    private(set) var markers: [Marker] = []
    private(set) var inputName = ""
    /// The input's gain (0...1), when the input lets it be set.
    private(set) var inputGain: Float?
    /// Seconds more that fit on the device.
    private(set) var spaceLeft: Double?
    var message: String?

    var elapsed: Double { Double(frames) / sampleRate }

    static let recentCount = 300

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let tap = TapWriter()
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var takeID = UUID()
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var lastUpdate = Date()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(library: Library) {
        self.library = library
    }

    /// Asks for the microphone and starts metering.
    func prepare() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Kool Edit needs the microphone to record. You can allow it in Settings › Privacy & Security › Microphone."
            return
        }
        do {
            try startInput()
            observe()
        } catch {
            message = "Couldn't start the input: \(error.localizedDescription)"
        }
    }

    private func startInput() throws {
        let session = AVAudioSession.sharedInstance()
        // Measurement mode turns off the voice processing (automatic gain and
        // the like) that would squash a guitar.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        inputName = session.currentRoute.inputs.first?.portName ?? "Input"
        inputGain = session.isInputGainSettable ? session.inputGain : nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
        sampleRate = format.sampleRate
        channels = min(Int(format.channelCount), 2)
        input.removeTap(onBus: 0)
        let tap = self.tap
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let peaks = AudioIO.peaks(of: buffer)
            let result = tap.write(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.heard(peaks, result) }
            }
        }
        engine.prepare()
        try engine.start()
        state = .ready
        updateSpaceLeft()
    }

    func setInputGain(_ gain: Float) {
        try? AVAudioSession.sharedInstance().setInputGain(gain)
        inputGain = gain
    }

    func record() {
        guard state == .ready else { return }
        do {
            let (id, folder) = try Library.makeFolder(in: library.root)
            let file = try AudioIO.writer(folder.appendingPathComponent(Take.firstAudioFile), sampleRate: sampleRate, channels: channels)
            tap.begin(file)
            self.folder = folder
            takeID = id
            frames = 0
            markers = []
            meter.resetClips()
            started = Date()
            lastUpdate = started
            state = .recording
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// Flags this moment.
    func mark() {
        guard state == .recording else { return }
        // Frames arrive in blocks; add the time since the last one.
        let now = frames + Int64(min(Date().timeIntervalSince(lastUpdate), 0.2) * sampleRate)
        markers.append(Marker(frame: now, name: "Mark \(markers.count + 1)"))
    }

    /// Stops recording and adds the take to the library.
    @discardableResult
    func stop() -> Take? {
        guard state == .recording, let folder else { return nil }
        let (frames, peaks) = tap.end()
        state = .ready
        self.folder = nil
        updateSpaceLeft()
        guard frames > 0 else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let audio = folder.appendingPathComponent(Take.firstAudioFile)
        try? peaks.write(to: Take.peaksURL(for: audio))
        let info = TakeInfo(
            id: takeID, name: Take.defaultName(started), created: started, audioFile: Take.firstAudioFile,
            frames: frames, sampleRate: sampleRate, channels: channels,
            markers: markers.filter { $0.frame < frames }, overview: peaks.overview(columns: Take.overviewColumns))
        do {
            try Library.write(info, to: folder)
        } catch {
            message = "The recording couldn't be saved: \(error.localizedDescription)"
            return nil
        }
        let take = Take(info: info, folder: folder)
        library.add(take)
        return take
    }

    /// Stops everything (keeping any recording) when the recorder closes.
    func shutDown() {
        stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        state = .off
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resetClips() {
        meter.resetClips()
    }

    private func heard(_ peaks: [Float], _ result: Result<Int64, Error>?) {
        meter.feed(peaks)
        recent.append(peaks.max() ?? 0)
        if recent.count > Recorder.recentCount { recent.removeFirst(recent.count - Recorder.recentCount) }
        switch result {
        case .success(let n):
            frames = n
            lastUpdate = Date()
        case .failure(let error):
            message = "Recording stopped: \(error.localizedDescription). What was recorded is saved."
            stop()
        case nil:
            break
        }
    }

    private func updateSpaceLeft() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let bytes = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return }
        spaceLeft = Double(bytes) / (sampleRate * 3 * Double(channels))
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interrupted(note) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        })
    }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            if state == .recording {
                stop()
                message = "Recording stopped for an interruption (a call or an alarm?). What was recorded is saved."
            }
        case .ended:
            if !engine.isRunning { try? engine.start() }
        @unknown default:
            break
        }
    }

    /// The input changed (an interface plugged in or out). Keep what was
    /// recorded and start listening to the new input.
    private func inputChanged() {
        if state == .recording {
            stop()
            message = "The input changed, so recording stopped. What was recorded is saved."
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try startInput() } catch { message = "Couldn't start the new input: \(error.localizedDescription)" }
    }
}

/// The recording file, written from the input's thread.
private final class TapWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var scratch: AVAudioPCMBuffer?
    private var builder = PeakBuilder()
    private var frames: Int64 = 0

    func begin(_ file: AVAudioFile) {
        lock.withLock {
            self.file = file
            scratch = nil
            builder = PeakBuilder()
            frames = 0
        }
    }

    /// Writes the buffer when recording, returning the frames recorded so
    /// far (or nil when not recording).
    func write(_ buffer: AVAudioPCMBuffer) -> Result<Int64, Error>? {
        lock.withLock {
            guard let file else { return nil }
            do {
                if scratch.map({ $0.frameCapacity < buffer.frameLength }) ?? true {
                    scratch = try AudioIO.buffer(file.processingFormat, frames: max(buffer.frameLength, 4096))
                }
                guard let out = scratch else { return nil }
                AudioIO.copy(buffer, into: out)
                try file.write(from: out)
                builder.append(out)
                frames += Int64(out.frameLength)
                return .success(frames)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Closes the file and hands back what was recorded.
    func end() -> (Int64, Peaks) {
        lock.withLock {
            file = nil
            return (frames, builder.finish())
        }
    }
}
