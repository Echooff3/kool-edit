import Foundation
import Observation

/// One take open for listening and editing: the view, the cursor and
/// selection, the transport, markers, edits with undo, and exporting.
@Observable @MainActor
final class EditorModel {
    /// A take as it was, for undo and redo, and the edit that came after it.
    private struct Version {
        var info: TakeInfo
        var selection: Range<Int64>?
        var cursor: Int64
        var edit: String
    }

    static let undoDepth = 10

    let library: Library
    let player = Player()
    private(set) var take: Take
    private(set) var peaks: Peaks?
    /// Bumped whenever the audio changes, for anything drawn from `reader`.
    private(set) var version = 0
    @ObservationIgnored private(set) var reader: SampleReader?

    var selection: Range<Int64>?
    var cursor: Int64 = 0
    var viewport = Viewport()
    private(set) var viewWidth: Double = 0
    private(set) var loop = false
    /// Where playback was paused (Play resumes from here).
    private(set) var pausedAt: Int64?
    private(set) var busy: String?
    private(set) var hasClipboard = !Clipboard.isEmpty
    var message: String?

    private var undoStack: [Version] = []
    private var redoStack: [Version] = []

    init(take: Take, library: Library) {
        self.take = take
        self.library = library
    }

    var frames: Int64 { take.info.frames }
    var sampleRate: Double { take.info.sampleRate }
    var markers: [Marker] { take.sortedMarkers }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoName: String? { undoStack.last?.edit }
    var redoName: String? { redoStack.last?.edit }
    /// What effects work on: the selection, or the whole take.
    var effectRange: Range<Int64> { selection ?? 0 ..< frames }
    var isPaused: Bool { pausedAt != nil && !player.isPlaying }
    var visibleFrames: Range<Double> {
        viewport.start ..< min(Double(frames), viewport.end(width: viewWidth))
    }

    func seconds(_ frame: Int64) -> Double {
        Double(frame) / sampleRate
    }

    func frame(_ seconds: Double) -> Int64 {
        min(max(0, Int64((seconds * sampleRate).rounded())), frames)
    }

    // MARK: Opening and closing

    func open() async {
        await loadAudio()
    }

    /// Stops playback and drops the versions kept for undo.
    func close() {
        player.stop()
        Library.removeOldVersions(of: take)
        undoStack = []
        redoStack = []
    }

    private func loadAudio() async {
        let take = self.take
        if let saved = Peaks.read(from: take.peaksURL, frames: take.info.frames) {
            peaks = saved
        } else {
            busy = "Reading the waveform…"
            let result = await Task.detached(priority: .userInitiated) { try Peaks.scan(take.audioURL) }.result
            busy = nil
            switch result {
            case .success(let scanned):
                peaks = scanned
                try? scanned.write(to: take.peaksURL)
            case .failure(let error):
                message = "Couldn't read the audio: \(error.localizedDescription)"
            }
        }
        reader = try? SampleReader(url: take.audioURL)
        do {
            try player.load(take.audioURL)
        } catch {
            message = "Couldn't open the audio for playback: \(error.localizedDescription)"
        }
        version += 1
    }

    // MARK: The view

    func setViewWidth(_ width: Double) {
        guard width != viewWidth, width > 0 else { return }
        let first = viewWidth == 0
        viewWidth = width
        if first { zoomFull() } else { viewport.clamp(width: width, frames: frames) }
    }

    func zoomFull() {
        viewport.show(0 ..< Double(max(frames, 1)), width: viewWidth, frames: frames)
    }

    func zoomIn() { zoom(by: 2) }
    func zoomOut() { zoom(by: 0.5) }

    /// Zooms around the playhead or cursor when it's on screen, else the middle.
    private func zoom(by factor: Double) {
        let x = viewport.x(at: Double(playheadOrCursor))
        let anchor = (0...viewWidth).contains(x) ? x : viewWidth / 2
        viewport.zoom(by: factor, at: anchor, width: viewWidth, frames: frames)
    }

    func zoomToSelection() {
        guard let s = selection else { return }
        let pad = Double(s.count) * 0.05
        viewport.show(Double(s.lowerBound) - pad ..< Double(s.upperBound) + pad, width: viewWidth, frames: frames)
    }

    /// Scrolls so the view is centred on `frame`.
    func center(on frame: Double) {
        viewport.start = frame - viewWidth / 2 * viewport.scale
        viewport.clamp(width: viewWidth, frames: frames)
    }

    func ensureVisible(_ frame: Int64) {
        let x = viewport.x(at: Double(frame))
        if x < 0 || x > viewWidth { center(on: Double(frame)) }
    }

    // MARK: Transport

    var playheadOrCursor: Int64 {
        player.isPlaying ? player.position : pausedAt ?? cursor
    }

    /// Plays the selection, or from the cursor to the end.
    func play() {
        let range = selection ?? 0 ..< frames
        var from = pausedAt ?? (selection?.lowerBound ?? cursor)
        if !range.contains(from) { from = range.lowerBound }
        pausedAt = nil
        player.play(range, from: from, loop: loop)
        ensureVisible(from)
    }

    /// Stops; the cursor stays where playback started, so Play goes again.
    func stop() {
        player.stop()
        pausedAt = nil
    }

    func togglePlay() {
        player.isPlaying ? stop() : play()
    }

    func togglePause() {
        if player.isPlaying {
            pausedAt = player.position
            player.stop()
        } else if pausedAt != nil {
            play()
        }
    }

    func toggleLoop() {
        loop.toggle()
        if player.isPlaying { restart(at: player.position) }
    }

    func toStart() {
        go(to: selection?.lowerBound ?? 0)
    }

    func toEnd() {
        go(to: selection.map { $0.upperBound - 1 } ?? max(0, frames - 1))
    }

    /// Skips by `seconds` (back when negative), carrying on playing if it was.
    func skip(_ seconds: Double) {
        let target = min(max(0, playheadOrCursor + Int64(seconds * sampleRate)), max(0, frames - 1))
        go(to: target)
    }

    private func go(to frame: Int64) {
        if player.isPlaying {
            if let s = selection, !s.contains(frame) { selection = nil }
            cursor = selection?.lowerBound ?? frame
            restart(at: frame)
        } else {
            if pausedAt != nil { pausedAt = frame } else { cursor = frame }
        }
        ensureVisible(frame)
    }

    private func restart(at frame: Int64) {
        player.play(selection ?? 0 ..< frames, from: frame, loop: loop)
    }

    // MARK: Cursor and selection

    /// Puts the cursor at `frame` (seeking if playing) and drops the selection.
    func setCursor(_ frame: Int64) {
        let frame = min(max(0, frame), frames)
        selection = nil
        cursor = frame
        if player.isPlaying {
            restart(at: frame)
        } else if pausedAt != nil {
            pausedAt = nil
        }
    }

    func select(_ range: Range<Int64>?) {
        guard let r = range else {
            selection = nil
            return
        }
        let clamped = max(0, r.lowerBound) ..< min(frames, r.upperBound)
        selection = clamped.isEmpty ? nil : clamped
        cursor = selection?.lowerBound ?? cursor
        pausedAt = nil
    }

    func selectAll() { select(0 ..< frames) }

    func selectVisible() {
        let v = visibleFrames
        select(Int64(v.lowerBound) ..< Int64(v.upperBound))
    }

    /// Selects from the marker at or before `frame` to the next one (or the
    /// ends of the take), the quick way to grab a marked moment.
    func selectAround(_ frame: Int64) {
        let marks = markers.map(\.frame)
        let lower = marks.last { $0 <= frame } ?? 0
        let upper = marks.first { $0 > frame } ?? frames
        select(lower ..< upper)
    }

    // MARK: Markers

    /// Drops a marker at the playhead (or the cursor when stopped).
    func addMarker() {
        let at = playheadOrCursor
        var info = take.info
        let number = (info.markers.compactMap { Int($0.name.split(separator: " ").last ?? "") }.max() ?? 0) + 1
        info.markers.append(Marker(frame: at, name: "Marker \(number)"))
        commit(info)
    }

    func renameMarker(_ id: UUID, to name: String) {
        var info = take.info
        guard let i = info.markers.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        info.markers[i].name = name.isEmpty ? info.markers[i].name : name
        commit(info)
    }

    func deleteMarker(_ id: UUID) {
        var info = take.info
        info.markers.removeAll { $0.id == id }
        commit(info)
    }

    func deleteAllMarkers() {
        var info = take.info
        info.markers = []
        commit(info)
    }

    func jump(to marker: Marker) {
        setCursor(marker.frame)
        ensureVisible(marker.frame)
    }

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var info = take.info
        info.name = name
        commit(info)
    }

    private func commit(_ info: TakeInfo) {
        take.info = info
        library.save(take)
    }

    // MARK: Editing

    @discardableResult
    func copy() async -> Bool {
        guard let s = selection, busy == nil else { return false }
        let source = take.audioURL
        busy = "Copying…"
        let result = await Task.detached(priority: .userInitiated) { try Clipboard.copy(source, range: s) }.result
        busy = nil
        hasClipboard = !Clipboard.isEmpty
        if case .failure(let error) = result {
            message = "Couldn't copy: \(error.localizedDescription)"
            return false
        }
        return true
    }

    func cut() async {
        guard let s = selection, s.count < frames, await copy() else { return }
        await edit(.delete(s), name: "Cut")
    }

    func delete() async {
        guard let s = selection, s.count < frames else { return }
        await edit(.delete(s))
    }

    func trim() async {
        guard let s = selection else { return }
        await edit(.trim(s))
    }

    /// Pastes in place of the selection, or inserts at the cursor.
    func paste() async {
        guard hasClipboard, busy == nil else { return }
        let at = selection ?? cursor ..< cursor
        let scratch = take.folder.appendingPathComponent("clipboard-\(UUID().uuidString.prefix(8)).caf")
        let (rate, channels) = (sampleRate, take.info.channels)
        busy = "Pasting…"
        let result = await Task.detached(priority: .userInitiated) {
            try Clipboard.conformed(sampleRate: rate, channels: channels, scratch: scratch)
        }.result
        busy = nil
        switch result {
        case .success(let (clip, length)):
            await edit(.paste(clip: clip, frames: length, at: at))
            try? FileManager.default.removeItem(at: scratch)
        case .failure(let error):
            message = "Couldn't paste: \(error.localizedDescription)"
        }
    }

    func apply(_ effect: Effect) async {
        await edit(.effect(effect, effectRange))
    }

    private func edit(_ op: EditOp, name: String? = nil) async {
        guard busy == nil else { return }
        let name = name ?? op.name
        stop()
        let before = take
        let file = "audio-\(UUID().uuidString.prefix(8)).caf"
        let dest = before.folder.appendingPathComponent(file)
        busy = name + "…"
        let result = await Task.detached(priority: .userInitiated) { try Edits.render(op, from: before.audioURL, to: dest) }.result
        busy = nil
        switch result {
        case .failure(let error):
            message = "\(name) didn't work: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dest)
        case .success(let peaks):
            try? peaks.write(to: Take.peaksURL(for: dest))
            undoStack.append(Version(info: before.info, selection: selection, cursor: cursor, edit: name))
            let dropped = redoStack + (undoStack.count > EditorModel.undoDepth ? [undoStack.removeFirst()] : [])
            redoStack = []
            discard(dropped)

            var info = before.info
            info.audioFile = file
            info.frames = peaks.frames
            info.markers = op.moved(info.markers)
            info.overview = peaks.overview(columns: Take.overviewColumns)
            let (newSelection, newCursor): (Range<Int64>?, Int64) = switch op {
            case .delete(let r): (nil, r.lowerBound)
            case .trim: (nil, 0)
            case .paste(_, let frames, let r): (r.lowerBound ..< r.lowerBound + frames, r.lowerBound)
            case .effect: (selection, cursor)
            }
            await show(info, peaks: peaks, selection: newSelection, cursor: newCursor)
            if case .trim = op { zoomFull() }
        }
    }

    func undo() async {
        guard let previous = undoStack.popLast() else { return }
        stop()
        redoStack.append(Version(info: take.info, selection: selection, cursor: cursor, edit: previous.edit))
        await show(previous.info, peaks: nil, selection: previous.selection, cursor: previous.cursor)
    }

    func redo() async {
        guard let next = redoStack.popLast() else { return }
        stop()
        undoStack.append(Version(info: take.info, selection: selection, cursor: cursor, edit: next.edit))
        await show(next.info, peaks: nil, selection: next.selection, cursor: next.cursor)
    }

    /// Switches to another version of the take's audio.
    private func show(_ info: TakeInfo, peaks: Peaks?, selection: Range<Int64>?, cursor: Int64) async {
        take.info = info
        library.save(take)
        self.selection = selection.map { min($0.lowerBound, frames) ..< min($0.upperBound, frames) }.flatMap { $0.isEmpty ? nil : $0 }
        self.cursor = min(cursor, frames)
        pausedAt = nil
        if let peaks {
            self.peaks = peaks
            reader = try? SampleReader(url: take.audioURL)
            try? player.load(take.audioURL)
            version += 1
        } else {
            await loadAudio()
        }
        viewport.clamp(width: viewWidth, frames: frames)
    }

    /// Deletes the audio of versions that can't come back.
    private func discard(_ versions: [Version]) {
        let inUse = Set((undoStack + redoStack).map(\.info.audioFile) + [take.info.audioFile])
        for v in versions where !inUse.contains(v.info.audioFile) {
            let audio = take.folder.appendingPathComponent(v.info.audioFile)
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: Take.peaksURL(for: audio))
        }
    }

    // MARK: Sharing

    /// A name for an exported file: the take's, plus the times of the selection.
    func exportName(whole: Bool) -> String {
        guard !whole, let s = selection else { return take.name }
        return "\(take.name) \(TimeFormat.stamp(seconds(s.lowerBound)))-\(TimeFormat.stamp(seconds(s.upperBound)))"
    }

    func exportRange(whole: Bool) -> Range<Int64> {
        whole ? 0 ..< frames : selection ?? 0 ..< frames
    }

    /// Writes the selection (or the whole take) to a file to share.
    func export(_ format: ExportFormat, whole: Bool, smoothEdges: Bool) async -> URL? {
        guard busy == nil else { return nil }
        let (source, range, name) = (take.audioURL, exportRange(whole: whole), exportName(whole: whole))
        busy = "Exporting…"
        let result = await Task.detached(priority: .userInitiated) {
            try Exporter.export(source, range: range, format: format, name: name, smoothEdges: smoothEdges)
        }.result
        busy = nil
        switch result {
        case .success(let url): return url
        case .failure(let error):
            message = "Couldn't export: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves the selection as a take of its own.
    func saveSelectionAsTake() async {
        guard let s = selection, busy == nil else { return }
        let (take, root) = (self.take, library.root)
        let name = "\(take.name) \(TimeFormat.clock(seconds(s.lowerBound), decimals: 0))–\(TimeFormat.clock(seconds(s.upperBound), decimals: 0))"
        busy = "Saving the clip…"
        let result = await Task.detached(priority: .userInitiated) { try Library.clip(of: take, range: s, name: name, into: root) }.result
        busy = nil
        switch result {
        case .success(let clip):
            library.add(clip)
            message = "Saved “\(clip.name)” to your takes."
        case .failure(let error):
            message = "Couldn't save the clip: \(error.localizedDescription)"
        }
    }

    // MARK: Typed times

    enum Field { case begin, end, length }

    /// Sets a selection boundary from a typed time, like the macOS app's
    /// Begin/End/Length fields.
    func setSelection(_ field: Field, to text: String) {
        guard let t = TimeFormat.parse(text) else {
            message = "“\(text)” isn't a time. Try 1:23.456."
            return
        }
        let current = selection ?? cursor ..< cursor
        var lower = current.lowerBound, upper = current.upperBound
        switch field {
        case .begin: lower = frame(t); upper = max(upper, lower)
        case .end: upper = frame(t); lower = min(lower, upper)
        case .length: upper = min(frames, lower + frame(t))
        }
        if upper > lower {
            select(lower ..< upper)
        } else {
            setCursor(lower)
        }
        ensureVisible(lower)
    }
}
