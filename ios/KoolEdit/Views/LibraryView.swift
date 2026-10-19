import SwiftUI
import UniformTypeIdentifiers

/// Every take, newest first, with a big Record button.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var path: [UUID] = []
    @State private var recording = false
    @State private var recorded: UUID?
    @State private var importing = false
    @State private var renaming: Take?
    @State private var newName = ""
    @State private var deleting: Take?

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
                    NavigationLink(value: take.id) { TakeRow(take: take) }
                        .listRowBackground(Color.white)
                        .swipeActions {
                            Button(role: .destructive) { deleting = take } label: { Label("Delete", systemImage: "trash") }
                            Button { rename(take) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                        }
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { rename(take) }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = take }
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
            .navigationDestination(for: UUID.self) { id in EditorScreen(takeID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
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
        path = [id]
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
                Text(take.name)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
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
private struct MiniWave: View {
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
