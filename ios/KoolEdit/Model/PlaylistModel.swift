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
    /// Where playing has got to (an index into `takes`), or nil when stopped.
    private(set) var current: Int?
    let player = Player()

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

    /// The next picked take after `index`, wrapping when `loop`; nil to stop.
    func next(after index: Int) -> Int? {
        if let following = pickedIndices.first(where: { $0 > index }) { return following }
        return loop ? pickedIndices.first : nil
    }

    /// The picked take before `index`, wrapping when `loop`; nil at the top.
    func previous(before index: Int) -> Int? {
        if let preceding = pickedIndices.last(where: { $0 < index }) { return preceding }
        return loop ? pickedIndices.last : nil
    }

    /// Plays from where playing left off, or the first picked take.
    func play() {
        if let current {
            playCurrent(current)
        } else if let first = pickedIndices.first {
            playCurrent(first)
        }
    }

    /// Plays `take` (wherever it is in the list, picked or not).
    func play(_ take: Take) {
        if let i = takes.firstIndex(where: { $0.id == take.id }) { playCurrent(i) }
    }

    func playCurrent(_ index: Int) {
        let take = takes[index]
        current = index
        do {
            try player.load(take.audioURL)
            player.play(0..<take.info.frames, from: 0, loop: false)
        } catch {
            stop()
        }
    }

    func stop() {
        player.stop()
        current = nil
    }

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
}