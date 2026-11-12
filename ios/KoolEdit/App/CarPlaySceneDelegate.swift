import CarPlay
import Observation

/// The car's screen: the takes as a list — tap one to play it and whatever
/// came in from its folder, one into the next — and the system's Now Playing
/// screen with the scrubber and the steering-wheel buttons. Only attaches
/// when the app carries the CarPlay audio entitlement; until then the car
/// still gets Now Playing controls through the audio session (and Bluetooth
/// / USB audio always works).
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    /// The playlist the car is playing (nil when nothing has been picked).
    private var playlist: PlaylistModel?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didAttach interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        interfaceController.delegate = self
        self.interfaceController = interfaceController
        showLibrary()
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDetach interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        playlist?.stop()
        playlist = nil
        self.interfaceController = nil
    }

    private func showLibrary() {
        guard let interfaceController else { return }
        let list = CPListTemplate(title: "Kool Edit", sections: [takesSection()])
        // The car's own Now Playing screen, with the scrubber and the
        // steering-wheel buttons, pushed onto the stack when a take plays.
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
        interfaceController.setRootTemplate(list, animated: false)
    }

    private func takesSection() -> CPListSection {
        let takes = Library.shared.takes
        guard !takes.isEmpty else {
            let empty = CPListItem(text: "No takes yet — record or import on the phone", detailText: nil)
            empty.isEnabled = false
            return CPListSection(items: [empty])
        }
        let items = takes.map { take in
            let item = CPListItem(
                text: take.name,
                detailText: "\(TimeFormat.clock(take.duration, decimals: 0)) • \(take.formatSummary)"
            )
            item.playbackProgress = 0
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    self?.play(take)
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }

    /// Plays `take`'s folder (or the take alone) on the car's own playlist.
    private func play(_ take: Take) {
        let model = PlaylistModel(takes: Library.shared.groupOf(take))
        playlist?.stop()
        playlist = model
        model.claimNowPlaying()
        model.play(take)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true)
    }
}

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didSelect template: CPTemplate,
        animated: Bool
    ) {}
}