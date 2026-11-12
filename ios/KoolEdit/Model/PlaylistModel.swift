import Foundation
import Observation

/// The play mode: a folder's takes queued up for playing in order. Which
/// ones are picked (all, by default), where playing has got to, and the
/// transport. The takes arrive in the folder's own order; `loop` (on by
/// default) wraps the list so the last take plays into the first.
@Observable @MainActor
final class PlaylistModel {
    /// The takes, in the order they'll play.
    let takes: [Take]
    /// The takes picked to play.
    var picked: Set<UUID>
    /// True wraps the list; False stops after the last picked take.
    var loop = true
    /// True plays the picks in a random order (a fresh pick each time a
    /// take ends) instead of the folder's.
    var shuffle = false
    /// Where playing has got to (an index into `takes`), or nil when stopped.
    private(set) var current: Int?
    let player = Player()
    /// Where playback was paused inside the current take, if it was.
    private(set) var pausedAtFrame: Int64?

    var isPaused: Bool { pausedAtFrame != nil && !player.isPlaying }

    init(takes: [Take], picked: Set<UUID>? = nil) {
        self.takes = takes
        self.picked = picked ?? Set(takes.map(\.id))
        // One take after another: the Player hands over when a take plays to
        // its end (each take plays once, the list itself is what loops).
        player.onReachedEnd = { [weak self] in self?.advance() }
    }

    /// The indices of the picked takes, in playing order.
    var pickedIndices: [Int] {
        (0..<takes.count).filter { picked.contains(takes[$0].id) }
    }

    /// What's playing (or about to, when stopped mid-list).
    var currentTake: Take? { current.map { takes[$0] } }

    /// The next picked take after `index`, wrapping when `loop`; a random
    /// other pick when `shuffle`; nil to stop.
    func next(after index: Int) -> Int? {
        let picks = pickedIndices
        guard !picks.isEmpty else { return nil }
        if shuffle, let random = picks.filter({ $0 != index }).randomElement() { return random }
        if let following = picks.first(where: { $0 > index }) { return following }
        return loop ? picks.first : nil
    }

    /// The picked take before `index`, wrapping when `loop`; a random other
    /// pick when `shuffle`; nil at the top.
    func previous(before index: Int) -> Int? {
        let picks = pickedIndices
        guard !picks.isEmpty else { return nil }
        if shuffle, let random = picks.filter({ $0 != index }).randomElement() { return random }
        if let preceding = picks.last(where: { $0 < index }) { return preceding }
        return loop ? picks.last : nil
    }

    /// Plays from where playing left off, or the first picked take.
    func play() {
        if let current {
            playCurrent(current, from: pausedAtFrame ?? 0)
        } else if let first = pickedIndices.first {
            playCurrent(first)
        }
    }

    /// Pauses inside the current take (Play resumes from there).
    func pause() {
        guard player.isPlaying else { return }
        pausedAtFrame = player.position
        player.stop()
        publish()
    }

    /// Plays `take` (wherever it is in the list, picked or not).
    func play(_ take: Take) {
        if let i = takes.firstIndex(where: { $0.id == take.id }) { playCurrent(i) }
    }

    func playCurrent(_ index: Int, from start: Int64 = 0) {
        let take = takes[index]
        current = index
        pausedAtFrame = nil
        do {
            try player.load(take.audioURL)
            player.play(0..<take.info.frames, from: min(max(0, start), max(0, take.info.frames - 1)), loop: false)
        } catch {
            stop()
        }
        publish()
    }

    func stop() {
        player.stop()
        current = nil
        pausedAtFrame = nil
        publish()
    }

    /// Skips to a time in the current take (the car's scrubber).
    func seek(to seconds: Double) {
        guard let current else { return }
        let frame = min(max(0, Int64(seconds * sampleRate)), max(0, takes[current].info.frames - 1))
        if player.isPlaying {
            playCurrent(current, from: frame)
        } else {
            pausedAtFrame = frame
            publish()
        }
    }

    /// The current take's rate, for turning seconds into frames.
    private var sampleRate: Double { current.map { takes[$0].info.sampleRate } ?? 44_100 }

    /// On to the next picked take (the Player calls this at a take's end).
    private func advance() {
        guard let current, let next = next(after: current) else {
            stop()
            return
        }
        playCurrent(next)
    }

    /// Skips a take in the list (picked: the nearest picked one that way).
    func skip(_ direction: Int) {
        let base = current ?? 0
        let target = direction < 0 ? previous(before: base) : next(after: base)
        if let target { playCurrent(target) }
    }

    // MARK: The car and the lock screen

    /// Takes over Now Playing (CarPlay's screen, Control Center, headphone
    /// buttons) while this playlist is the active player.
    func claimNowPlaying() {
        NowPlayingCenter.activate(self, PlaybackCommands(
            title: { [weak self] in self?.currentTake?.name ?? "Playlist" },
            duration: { [weak self] in
                guard let self, let take = self.currentTake else { return 0 }
                return take.duration
            },
            elapsed: { [weak self] in
                guard let self, let take = self.currentTake else { return 0 }
                let frame = self.player.isPlaying ? self.player.position : (self.pausedAtFrame ?? 0)
                return Double(min(max(0, frame), take.info.frames)) / take.info.sampleRate
            },
            isPlaying: { [weak self] in self?.player.isPlaying == true },
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            stop: { [weak self] in self?.stop() },
            next: { [weak self] in self?.skip(1) },
            previous: { [weak self] in self?.skip(-1) },
            seek: { [weak self] in self?.seek(to: $0) }
        ))
    }

    /// Re-publishes the now-playing card after any state change.
    func publish() {
        guard NowPlayingCenter.isActive(self) else { return }
        NowPlayingCenter.refresh()
    }
}