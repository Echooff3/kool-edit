import SwiftUI

/// Opens a take from the library.
struct EditorScreen: View {
    @Environment(Library.self) private var library
    let takeID: UUID
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model)
            } else if library.take(takeID) == nil {
                ContentUnavailableView("This take is gone", systemImage: "waveform.slash")
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil, let take = library.take(takeID) else { return }
            let editor = EditorModel(take: take, library: library)
            model = editor
            await editor.open()
        }
    }
}

/// The editor, laid out like Cool Edit: a toolbar, the overview, the
/// waveform and time ruler, then the transport, zoom, LCD, the
/// Selection/View fields and the level meter.
struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var showMarkers = false
    @State private var sharing: ShareRequest?
    @State private var amplifying = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var field: EditorModel.Field?
    @State private var fieldText = ""

    private var compact: Bool { verticalSize == .compact }

    var body: some View {
        VStack(spacing: 6) {
            ToolRow(model: model, amplifying: $amplifying)
            OverviewStrip(model: model)
                .frame(height: compact ? 26 : 34)
            WaveformView(model: model)
                .bevel(raised: false)
            if compact {
                HStack(spacing: 8) {
                    TransportGroup(model: model, compact: true)
                    ZoomGroup(model: model, compact: true)
                    MarkGroup(model: model, showMarkers: $showMarkers, compact: true)
                }
                .frame(height: 50)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    TransportGroup(model: model, compact: false)
                    ZoomGroup(model: model, compact: false)
                    MarkGroup(model: model, showMarkers: $showMarkers, compact: false)
                }
                .frame(height: 96)
                HStack(alignment: .top, spacing: 6) {
                    LCDPanel(model: model)
                    SelectionTable(model: model) { edit($0) }
                }
                LevelMeter(meter: model.player.meter) { model.player.resetClips() }
                    .frame(height: 30)
                    .bevel(raised: false)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .background(Theme.face)
        .navigationTitle(model.take.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            Button("Rename…", systemImage: "pencil") {
                newName = model.take.name
                renaming = true
            }
            Button("Share Whole Take…", systemImage: "square.and.arrow.up") { sharing = ShareRequest(whole: true) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Save Selection as New Take", systemImage: "plus.square.on.square") {
                    Task { await model.saveSelectionAsTake() }
                }
                .disabled(model.selection == nil)
                Button(model.selection == nil ? "Share Take" : "Share Selection", systemImage: "square.and.arrow.up") {
                    sharing = ShareRequest(whole: model.selection == nil)
                }
            }
        }
        .overlay {
            if let busy = model.busy { BusyOverlay(text: busy) }
        }
        .sheet(isPresented: $showMarkers) { MarkersSheet(model: model) }
        .sheet(item: $sharing) { request in ExportSheet(model: model, whole: request.whole) }
        .sheet(isPresented: $amplifying) {
            AmplifySheet { dB in Task { await model.apply(.amplify(dB: dB)) } }
        }
        .alert("Rename Take", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.rename(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(fieldTitle, isPresented: Binding(get: { field != nil }, set: { if !$0 { field = nil } })) {
            TextField("m:ss.ddd", text: $fieldText)
                .keyboardType(.numbersAndPunctuation)
            Button("Set") { if let field { model.setSelection(field, to: fieldText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type a time like 1:23.456")
        }
        .alert("Kool Edit", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .onDisappear { model.close() }
    }

    private var fieldTitle: String {
        switch field {
        case .begin: "Selection Begin"
        case .end: "Selection End"
        case .length: "Selection Length"
        case nil: ""
        }
    }

    private func edit(_ f: EditorModel.Field) {
        let s = model.selection ?? model.cursor ..< model.cursor
        let frame: Int64 = switch f {
        case .begin: s.lowerBound
        case .end: s.upperBound
        case .length: Int64(s.count)
        }
        fieldText = TimeFormat.clock(model.seconds(frame))
        field = f
    }
}

struct ShareRequest: Identifiable {
    let whole: Bool
    var id: Bool { whole }
}

/// Cool Edit's icon toolbar: undo/redo, the clipboard, and menus for
/// selecting and effects.
private struct ToolRow: View {
    let model: EditorModel
    @Binding var amplifying: Bool

    var body: some View {
        let selected = model.selection != nil
        HStack(spacing: 2) {
            tool("arrow.uturn.backward", model.undoName.map { "Undo \($0)" } ?? "Undo", enabled: model.canUndo) { await model.undo() }
            tool("arrow.uturn.forward", model.redoName.map { "Redo \($0)" } ?? "Redo", enabled: model.canRedo) { await model.redo() }
            separator
            tool("scissors", "Cut", enabled: selected) { await model.cut() }
            tool("doc.on.doc", "Copy", enabled: selected) { await model.copy() }
            tool("doc.on.clipboard", "Paste", enabled: model.hasClipboard) { await model.paste() }
            tool("delete.left", "Delete", enabled: selected) { await model.delete() }
            tool("crop", "Trim to Selection", enabled: selected) { await model.trim() }
            separator
            Menu {
                Button("Select All") { model.selectAll() }
                Button("Select Visible") { model.selectVisible() }
                Button("Select Between Markers") { model.selectAround(model.playheadOrCursor) }
                    .disabled(model.markers.isEmpty)
                Button("Deselect") { model.select(nil) }
                    .disabled(!selected)
            } label: {
                Image(systemName: "selection.pin.in.out")
                    .frame(width: 36, height: 30)
            }
            .accessibilityLabel("Select")
            Menu {
                Section(selected ? "On the Selection" : "On the Whole Take") {
                    effect(.fadeIn, "arrow.up.right")
                    effect(.fadeOut, "arrow.down.right")
                    effect(.normalize, "arrow.up.and.down")
                    Button("Amplify…", systemImage: "speaker.wave.3") { amplifying = true }
                    effect(.silence, "speaker.slash")
                    effect(.reverse, "arrow.left.arrow.right")
                    effect(.invert, "arrow.up.arrow.down")
                }
            } label: {
                Image(systemName: "wand.and.stars")
                    .frame(width: 36, height: 30)
            }
            .accessibilityLabel("Effects")
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text)
        .frame(height: 32)
    }

    private var separator: some View {
        HStack(spacing: 1) {
            Rectangle().fill(Theme.shadow).frame(width: 1)
            Rectangle().fill(Color.white).frame(width: 1)
        }
        .frame(height: 22)
        .padding(.horizontal, 3)
    }

    private func tool(_ icon: String, _ label: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 36, height: 30)
        }
        .disabled(!enabled || model.busy != nil)
        .foregroundStyle(enabled ? Theme.text : Theme.disabled)
        .accessibilityLabel(label)
    }

    private func effect(_ e: Effect, _ icon: String) -> some View {
        Button(e.name, systemImage: icon) { Task { await model.apply(e) } }
    }
}

/// Stop, Play, Pause, Loop / Start, Back, Forward, End.
private struct TransportGroup: View {
    let model: EditorModel
    let compact: Bool

    var body: some View {
        let player = model.player
        let buttons = [
            button("stop.fill", "Stop", color: Color(hex: 0x0A246A)) { model.stop() },
            button("play.fill", "Play", color: Color(hex: 0x008000), latched: player.isPlaying && !player.isLooping) {
                if player.isPlaying { model.stop() } else { model.play() }
            },
            button("pause.fill", "Pause", color: Color(hex: 0x0A246A), latched: model.isPaused) { model.togglePause() },
            button("repeat", "Loop", color: Color(hex: 0x008000), latched: model.loop) { model.toggleLoop() },
            button("backward.end.fill", "Go to Start", color: Color(hex: 0x0A246A)) { model.toStart() },
            button("backward.fill", "Back 5 Seconds", color: Color(hex: 0x0A246A)) { model.skip(-5) },
            button("forward.fill", "Forward 5 Seconds", color: Color(hex: 0x0A246A)) { model.skip(5) },
            button("forward.end.fill", "Go to End", color: Color(hex: 0x0A246A)) { model.toEnd() },
        ]
        ClassicGroup(title: "Transport") {
            if compact {
                HStack(spacing: 2) { ForEach(0..<8, id: \.self) { buttons[$0] } }
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { ForEach(0..<4, id: \.self) { buttons[$0] } }
                    GridRow { ForEach(4..<8, id: \.self) { buttons[$0] } }
                }
            }
        }
    }

    private func button(_ icon: String, _ label: String, color: Color, latched: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
        }
        .buttonStyle(ClassicButtonStyle(latched: latched))
        .accessibilityLabel(label)
    }
}

private struct ZoomGroup: View {
    let model: EditorModel
    let compact: Bool

    var body: some View {
        let buttons = [
            button("plus.magnifyingglass", "Zoom In") { model.zoomIn() },
            button("minus.magnifyingglass", "Zoom Out") { model.zoomOut() },
            button("arrow.left.and.right.square", "Zoom to Selection", enabled: model.selection != nil) { model.zoomToSelection() },
            button("arrow.up.left.and.arrow.down.right.square", "Zoom Out Full") { model.zoomFull() },
        ]
        ClassicGroup(title: "Zoom") {
            if compact {
                HStack(spacing: 2) { ForEach(0..<4, id: \.self) { buttons[$0] } }
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { buttons[0]; buttons[1] }
                    GridRow { buttons[2]; buttons[3] }
                }
            }
        }
        .frame(maxWidth: compact ? 170 : 92)
    }

    private func button(_ icon: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15))
        }
        .buttonStyle(ClassicButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Dropping markers on the moments worth keeping, and the list of them.
private struct MarkGroup: View {
    let model: EditorModel
    @Binding var showMarkers: Bool
    let compact: Bool

    var body: some View {
        ClassicGroup(title: "Marks") {
            let layout = compact ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
            layout {
                Button { model.addMarker() } label: {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(uiColor: Theme.marker))
                }
                .buttonStyle(ClassicButtonStyle())
                .accessibilityLabel("Add Marker")
                Button { showMarkers = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet").font(.system(size: 13))
                        Text("\(model.markers.count)").font(Theme.font(11))
                    }
                }
                .buttonStyle(ClassicButtonStyle())
                .accessibilityLabel("Markers, \(model.markers.count)")
            }
        }
        .frame(maxWidth: compact ? 100 : 62)
    }
}

/// The green LCD: the playhead (or cursor) time, what the transport is
/// doing, and the sample rate.
private struct LCDPanel: View {
    let model: EditorModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.player.isPlaying)) { _ in
            let player = model.player
            let state = player.isPlaying ? "PLAY" : model.isPaused ? "PAUSE" : "STOP"
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(state).foregroundStyle(Theme.lcdOn)
                    Text("LOOP").foregroundStyle(model.loop ? Theme.lcdOn : Theme.lcdOff)
                    Spacer(minLength: 4)
                    Text("\(Int(model.sampleRate)) Hz").foregroundStyle(Theme.lcdOn)
                }
                .font(Theme.font(9))
                SevenSegment(text: TimeFormat.clock(model.seconds(model.playheadOrCursor)), height: 30)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 150)
            .background(Color.black)
            .bevel(raised: false)
        }
        .fixedSize()
    }
}

/// Begin/End/Length of the selection and the view, like Cool Edit's
/// "Selection / View" box. Tap a selection time to type one.
private struct SelectionTable: View {
    let model: EditorModel
    let onEdit: (EditorModel.Field) -> Void

    var body: some View {
        let s = model.selection ?? model.cursor ..< model.cursor
        let v = model.visibleFrames
        ClassicGroup(title: "Selection / View") {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    header("Begin")
                    header("End")
                    header("Length")
                }
                GridRow {
                    rowLabel("Sel")
                    cell(s.lowerBound) { onEdit(.begin) }
                    cell(s.upperBound) { onEdit(.end) }
                    cell(Int64(s.count)) { onEdit(.length) }
                }
                GridRow {
                    rowLabel("View")
                    cell(Int64(v.lowerBound), action: nil)
                    cell(Int64(v.upperBound), action: nil)
                    cell(Int64(v.upperBound - v.lowerBound), action: nil)
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.font(10)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(Theme.font(10)).fixedSize()
    }

    private func cell(_ frame: Int64, action: (() -> Void)?) -> some View {
        Text(TimeFormat.clock(model.seconds(frame)))
            .font(Theme.mono(11))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(Theme.text)
            .sunkenField()
            .onTapGesture { action?() }
            .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

/// A classic "please wait" box while an edit or export runs.
struct BusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 0) {
                TitleBar(title: "Kool Edit")
                HStack(spacing: 10) {
                    ProgressView()
                    Text(text).font(Theme.font(13)).foregroundStyle(Theme.text)
                }
                .padding(16)
            }
            .frame(width: 240)
            .background(Theme.face)
            .bevel()
            .shadow(color: .black.opacity(0.35), radius: 0, x: 3, y: 3)
        }
    }
}
