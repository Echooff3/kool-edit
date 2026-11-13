import SwiftUI

/// The play mode screen: the folder's takes listed for picking, a transport
/// that plays the picked ones in order (round again with Loop on), and the
/// way into the editor for whatever's playing.
struct PlaylistScreen: View {
    @Environment(Library.self) private var library
    let seedID: UUID
    let onOpenInEditor: (UUID) -> Void
    @State private var model: PlaylistModel?

    var body: some View {
        Group {
            if let model {
                PlaylistView(model: model, onOpenInEditor: onOpenInEditor)
            } else if library.take(seedID) == nil {
                ContentUnavailableView("This take is gone", systemImage: "waveform.slash")
            } else {
                ProgressView()
            }
        }
        .background(Theme.face)
        .task {
            guard model == nil, let seed = library.take(seedID) else { return }
            model = PlaylistModel(takes: library.groupOf(seed))
        }
        .onDisappear { model?.stop() }
    }
}

/// The list of takes to pick from, and the transport under it.
private struct PlaylistView: View {
    @Bindable var model: PlaylistModel
    let onOpenInEditor: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(model.takes.enumerated()), id: \.element.id) { pair in
                    row(pair.offset, pair.element)
                        .listRowBackground(Color.white)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            transport
        }
        .background(Theme.face)
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Open in Editor", systemImage: "square.and.pencil") { openCurrent() }
                    .disabled(model.current == nil)
            }
        }
    }

    /// One take in the list: the wave, the name, and whether it's picked.
    private func row(_ index: Int, _ take: Take) -> some View {
        HStack(spacing: 12) {
            MiniWave(overview: take.info.overview)
                .frame(width: 72, height: 40)
                .background(Color.black)
                .bevel(raised: false)
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(take.name)
                    .frame(height: 18)
                HStack(spacing: 10) {
                    Text(TimeFormat.clock(take.duration, decimals: 0)).font(Theme.mono(13))
                    if index == model.current {
                        Label(model.player.isPlaying ? "Playing" : "Paused", systemImage: "speaker.wave.2.fill")
                            .foregroundStyle(Color(hex: 0x008000))
                    }
                }
                .font(Theme.font(11))
                .foregroundStyle(Theme.shadow)
            }
            Spacer()
            Button {
                if !model.picked.insert(take.id).inserted { model.picked.remove(take.id) }
            } label: {
                Image(systemName: model.picked.contains(take.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(model.picked.contains(take.id) ? Theme.navy : Theme.shadow)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(take.name + (model.picked.contains(take.id) ? ", picked" : ", not picked"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.play(take) }
        .contextMenu {
            Button("Play From Here", systemImage: "play.fill") { model.play(take) }
            Button("Open in Editor", systemImage: "square.and.pencil") { onOpenInEditor(take.id) }
        }
    }

    /// Stop, Play, Loop (round the list), Previous and Next.
    private var transport: some View {
        VStack(spacing: 0) {
            HStack {}
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .background(Theme.shadow)
            HStack(spacing: 10) {
                transportButton("stop.fill", "Stop", color: Color(hex: 0x0A246A)) { model.stop() }
                transportButton("play.fill", "Play", color: Color(hex: 0x008000), latched: model.player.isPlaying) {
                    if model.player.isPlaying { model.stop() } else { model.play() }
                }
                transportButton("repeat", "Loop Playlist", color: Color(hex: 0x008000), latched: model.loop) {
                    model.loop.toggle()
                }
                transportButton("shuffle", "Random Order", color: Color(hex: 0x008000), latched: model.shuffle) {
                    model.shuffle.toggle()
                }
                transportButton("backward.fill", "Previous Take", color: Color(hex: 0x0A246A)) { model.skip(-1) }
                transportButton("forward.fill", "Next Take", color: Color(hex: 0x0A246A)) { model.skip(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.face)
    }

    private func transportButton(_ icon: String, _ label: String, color: Color, latched: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 40, height: 34)
        }
        .buttonStyle(ClassicButtonStyle(latched: latched))
        .accessibilityLabel(label)
    }

    /// The toolbar's way in: whatever's playing (or was), straight into the editor.
    private func openCurrent() {
        if let take = model.currentTake { onOpenInEditor(take.id) }
    }
}