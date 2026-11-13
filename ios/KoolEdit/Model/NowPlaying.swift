import Foundation
import MediaPlayer
import Observation

/// What the car (and Control Center, and headphones) can ask of whatever is
/// playing: play, pause, next, previous, and seek.
struct PlaybackCommands {
    var title: () -> String
    var duration: () -> Double
    var elapsed: () -> Double
    var isPlaying: () -> Bool
    var play: () -> Void
    var pause: () -> Void
    var stop: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var seek: (Double) -> Void
}

/// The one place the system's Now Playing (CarPlay's screen, Control Center,
/// headphone and steering-wheel buttons) meets the app. Whichever player is
/// in front — the editor's or the playlist's — registers its commands; the
/// center publishes the title/times and answers the buttons. Nothing plays
/// through here: it's the remote control and the metadata.
@MainActor
enum NowPlayingCenter {
    /// The player in charge right now (last one to register wins, which is
    /// the one on screen).
    private static weak var active: AnyObject?

    private static var commands: PlaybackCommands?

    /// Installs the system button handlers once per process.
    private static var installed = false

    static func activate(_ owner: AnyObject, _ handlers: PlaybackCommands) {
        active = owner
        commands = handlers
        installIfNeeded()
        refresh()
    }

    /// The owner went away or stopped being the front player.
    static func deactivate(_ owner: AnyObject) {
        guard active === owner else { return }
        active = nil
        commands = nil
        refresh()
    }

    /// True when `owner` is the player the buttons drive right now.
    static func isActive(_ owner: AnyObject) -> Bool {
        active === owner
    }

    /// Re-publishes the now-playing card: called after every state change
    /// (play, pause, stop, next take) so the car screen stays in step.
    static func refresh() {
        guard let handlers = commands else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: handlers.title(),
            MPMediaItemPropertyArtist: "Kool Edit",
            MPMediaItemPropertyAlbumArtist: "Kool Edit",
            MPMediaItemPropertyPlaybackDuration: max(handlers.duration(), 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(handlers.elapsed(), 0),
            MPNowPlayingInfoPropertyPlaybackRate: handlers.isPlaying() ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            run { $0.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            run { $0.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            run { if $0.isPlaying() { $0.pause() } else { $0.play() } }
            return .success
        }
        center.stopCommand.addTarget { _ in
            run { $0.stop() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            run { $0.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            run { $0.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            run { $0.seek(event.positionTime) }
            return .success
        }
    }

    /// Command handlers arrive on a background thread; hop to the main one.
    private static func run(_ body: @escaping (PlaybackCommands) -> Void) {
        Task { @MainActor in
            if let handlers = commands { body(handlers) }
        }
    }
}