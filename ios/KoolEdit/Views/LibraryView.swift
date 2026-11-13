import SwiftUI
import UniformTypeIdentifiers

/// Where the navigation stack goes: a take into the editor, a take's
/// folder into the play mode, or a hand-picked list into the play mode.
enum Route: Hashable {
    case take(UUID)
    case playlist(UUID)
    case selection([UUID])
}

/// Every take, newest first, with a big Record button.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var path: [Route] = []
    @State private var recording = false
    @State private var recorded: UUID?
    @State private var importing = false
    @State private var importingFolder = false
    @State private var renaming: Take?
    @State private var newName = ""
    @State private var deleting: Take?
    @State private var deduping = false
    @State private var deletingAll = false
    /// Building a playlist by hand: rows pick instead of opening.
    @State private var picking = false
    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if library.importing > 0 {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Importing…").font(Theme.font(13))
                    }
                    .listRowBackground(Theme.face)
                }
                ForEach(library.takes) { take in
                    if picking {
                        Button {
                            if !picked.insert(take.id).inserted { picked.remove(take.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: picked.contains(take.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(picked.contains(take.id) ? Theme.navy : Theme.shadow)
                                TakeRow(take: take)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white)
                    } else {
                        NavigationLink(value: Route.take(take.id)) { TakeRow(take: take) }
                            .listRowBackground(Color.white)
                            .swipeActions {
                                Button(role: .destructive) { deleting = take } label: { Label("Delete", systemImage: "trash") }
                                Button { playFolder(take) } label: { Label("Play", systemImage: "play.circle") }.tint(.green)
                                Button { rename(take) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                            }
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") { rename(take) }
                                Button("Play Folder…", systemImage: "play.circle") { playFolder(take) }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = take }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.face)
            .overlay {
                if library.takes.isEmpty && library.importing == 0 {
                    ContentUnavailableView {
                        Label("No Takes Yet", systemImage: "waveform")
                    } description: {
                        Text("Record yourself jamming, or import audio from Files.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordBar { recording = true }
            }
            .navigationTitle("Kool Edit")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .take(let id):
                    EditorScreen(takeID: id, onAdvance: advance)
                case .playlist(let id):
                    PlaylistScreen(source: .group(id), onOpenInEditor: { takeID in path.append(.take(takeID)) })
                case .selection(let ids):
                    PlaylistScreen(source: .picks(ids), autoplay: true, onOpenInEditor: { takeID in path.append(.take(takeID)) })
                }
            }
            .toolbar {
                // One line with the title: the playlist buttons float right,
                // beside Import; picking swaps them for Play and Cancel.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if picking {
                        Button("Cancel") {
                            picking = false
                            picked = []
                        }
                        Button {
                            startPickedPlaylist()
                        } label: {
                            Label(picked.isEmpty ? "Play" : "Play (\(picked.count))", systemImage: "play.fill")
                        }
                        .disabled(picked.isEmpty)
                    } else {
                        Button {
                            picking = true
                        } label: {
                            Label("Start Playlist", systemImage: "list.bullet")
                        }
                    }
                    Menu {
                        Button("Import Files…", systemImage: "square.and.arrow.down") { importing = true }
                        Button("Import Folder…", systemImage: "folder") { importingFolder = true }
                        Section {
                            Button("Delete Duplicates…", systemImage: "doc.on.doc", role: .destructive) { deduping = true }
                                .disabled(library.duplicates.isEmpty)
                            Button("Delete All Takes…", systemImage: "trash", role: .destructive) { deletingAll = true }
                                .disabled(library.takes.isEmpty)
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.importFolder(url) }
            }
            .fullScreenCover(isPresented: $recording, onDismiss: openRecorded) {
                RecorderView { take in recorded = take.id }
            }
            .alert("Rename Take", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let renaming { library.rename(renaming.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Take", role: .destructive) { if let deleting { library.delete(deleting.id) } }
            } message: {
                Text("The recording and its markers are deleted from this device.")
            }
            .confirmationDialog(
                "Delete \(library.duplicates.count) Duplicate\(library.duplicates.count == 1 ? "" : "s")?",
                isPresented: $deduping,
                titleVisibility: .visible
            ) {
                Button("Delete Duplicates", role: .destructive) {
                    library.deleteDuplicates()
                }
            } message: {
                Text("Takes with the same name, length and format are the same file imported twice; the originals are kept.")
            }
            .confirmationDialog(
                "Delete All Takes?", isPresented: $deletingAll, titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) { library.deleteAll() }
            } message: {
                Text("Every recording, import and edit is deleted from this device. This can't be undone.")
            }
            .alert("Kool Edit", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.error ?? "")
            }
        }
    }

    private func rename(_ take: Take) {
        newName = take.name
        renaming = take
    }

    /// Straight into the editor with a fresh recording.
    private func openRecorded() {
        guard let id = recorded else { return }
        recorded = nil
        path = [.take(id)]
    }

    /// Into the play mode for `take`'s folder (or just `take` on its own).
    private func playFolder(_ take: Take) {
        path.append(.playlist(take.id))
    }

    /// The picked takes become the playlist, in the list's order, and it
    /// starts playing straight away.
    private func startPickedPlaylist() {
        guard !picked.isEmpty else { return }
        let ids = library.takes.filter { picked.contains($0.id) }.map(\.id)
        picking = false
        picked = []
        path.append(.selection(ids))
    }

    /// The take before this one finished: mark this one to start playing the
    /// moment it opens, and swap the top of the stack over to it (so a
    /// playlist pushed underneath stays where it is).
    private func advance(to id: UUID) {
        library.requestChainPlay(id)
        if path.isEmpty {
            path = [.take(id)]
        } else {
            path[path.count - 1] = .take(id)
        }
    }
}

private struct TakeRow: View {
    let take: Take

    var body: some View {
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
                    Text(take.info.created.formatted(date: .abbreviated, time: .shortened))
                    if !take.info.markers.isEmpty {
                        Label("\(take.info.markers.count)", systemImage: "flag.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(Theme.font(11))
                .foregroundStyle(Theme.shadow)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The take list's thumbnail waveform.
struct MiniWave: View {
    let overview: [UInt8]

    var body: some View {
        Canvas { ctx, size in
            guard !overview.isEmpty else { return }
            let mid = size.height / 2
            let step = size.width / CGFloat(overview.count)
            var path = Path()
            for (i, v) in overview.enumerated() {
                let h = max(CGFloat(v) / 255 * (mid - 2), 0.5)
                let x = (CGFloat(i) + 0.5) * step
                path.move(to: CGPoint(x: x, y: mid - h))
                path.addLine(to: CGPoint(x: x, y: mid + h))
            }
            ctx.stroke(path, with: .color(Color(uiColor: Theme.wave)), lineWidth: max(step * 0.8, 1))
        }
    }
}

private struct RecordBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(Theme.record).frame(width: 20, height: 20)
                Text("Record").font(Theme.font(17, bold: true))
            }
            .frame(height: 54)
        }
        .buttonStyle(ClassicButtonStyle())
        .frame(height: 54)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.face)
        .accessibilityLabel("Record a new take")
    }
}
