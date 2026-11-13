import Foundation
import Observation
import os
import UniformTypeIdentifiers

private let libraryLog = Logger(subsystem: "com.trilsoft.kooledit", category: "Library")

/// All the takes, newest first. Each lives in a folder under Application
/// Support/Takes. Audio files dropped into the app's Documents folder (from
/// Finder, or "Open in Kool Edit" from another app) are imported as takes.
@Observable @MainActor
final class Library {
    private(set) var takes: [Take] = []
    /// Imports still running.
    private(set) var importing = 0
    var error: String?

    let root: URL
    @ObservationIgnored private var inFlight: Set<URL> = []

    init(root: URL = Library.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        Exporter.cleanUp()
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes", isDirectory: true)
    }

    func take(_ id: UUID) -> Take? {
        takes.first { $0.id == id }
    }

    func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [Take] = []
        for folder in folders where folder.hasDirectoryPath {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("take.json")),
                  let info = try? JSONDecoder.takes.decode(TakeInfo.self, from: data)
            else { continue }
            let take = Take(info: info, folder: folder)
            guard fm.fileExists(atPath: take.audioURL.path) else { continue }
            Library.removeOldVersions(of: take)
            found.append(take)
        }
        takes = found.sorted { $0.info.created > $1.info.created }
    }

    func add(_ take: Take) {
        takes.removeAll { $0.id == take.id }
        takes.insert(take, at: 0)
        takes.sort { $0.info.created > $1.info.created }
    }

    /// Saves the take's take.json and updates the list.
    func save(_ take: Take) {
        do {
            try Library.write(take.info, to: take.folder)
        } catch {
            self.error = "Couldn't save \(take.name): \(error.localizedDescription)"
        }
        if let i = takes.firstIndex(where: { $0.id == take.id }) { takes[i] = take }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var take = take(id) else { return }
        take.info.name = name
        save(take)
    }

    func delete(_ id: UUID) {
        guard let take = take(id) else { return }
        try? FileManager.default.removeItem(at: take.folder)
        takes.removeAll { $0.id == id }
    }

    // MARK: Cleaning up

    /// Takes that are the same recording twice: matching name, length and
    /// format. The list is newest-first, so the *last* of each group is the
    /// original import; the rest came from importing the same file again.
    func duplicateGroups() -> [[Take]] {
        var seen: [String: Int] = [:]
        var groups: [Int: [Take]] = [:]
        for take in takes {
            let key = "\(take.info.name)|\(take.info.frames)|\(take.info.sampleRate)|\(take.info.channels)"
            if let i = seen[key] {
                groups[i, default: []].append(take)
            } else {
                seen[key] = groups.count
                groups[groups.count] = [take]
            }
        }
        return groups.values.filter { $0.count > 1 }
    }

    /// The copies to throw away (one kept per group, the original).
    var duplicates: [Take] {
        duplicateGroups().flatMap { group in
            // Newest-first list: keep the last, drop the rest.
            group.dropLast()
        }
    }

    /// Deletes the duplicate imports (the newest copy of each), keeping
    /// the originals. Returns how many were deleted.
    @discardableResult
    func deleteDuplicates() -> Int {
        let ids = Set(duplicates.map(\.id))
        for id in ids { delete(id) }
        return ids.count
    }

    /// Deletes every take (and with it every recording, import and edit).
    func deleteAll() {
        let folders = takes.map(\.folder)
        takes = []
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Importing

    /// Copies audio files in as new takes, in the background. Files from one
    /// folder share `group`, numbered by their place in it.
    func importFiles(_ urls: [URL], removingOriginals: Bool = false, group: UUID? = nil) {
        let root = self.root
        for (order, url) in urls.enumerated() where !inFlight.contains(url) {
            inFlight.insert(url)
            importing += 1
            let groupInfo = group.map { (id: $0, order: Int64(order)) }
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                let result = Result { try Library.importAudio(url, into: root, group: groupInfo) }
                if scoped { url.stopAccessingSecurityScopedResource() }
                // A file that wouldn't import is kept, out of the way of the
                // next look in the inbox.
                var setAside = false
                if removingOriginals {
                    if case .success = result {
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        setAside = Library.setAside(url)
                    }
                }
                let keptIn = setAside ? " It's in the \(Library.notImported) folder." : ""
                await MainActor.run {
                    self.importing -= 1
                    self.inFlight.remove(url)
                    switch result {
                    case .success(let take): self.add(take)
                    case .failure(let error): self.error = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)\(keptIn)"
                    }
                }
            }
        }
    }

    /// Imports audio dropped into Documents (and its Inbox, where files
    /// opened from other apps arrive), then removes the originals.
    func importInbox() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var files: [URL] = []
        for folder in [documents, documents.appendingPathComponent("Inbox")] {
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            files += contents.filter(Library.looksLikeAudio)
        }
        importFiles(files, removingOriginals: true)
    }

    /// Imports every audio file in a picked folder, in the folder's own
    /// order, as a group that plays one take after another. The picker's
    /// permission covers the folder, not its files, so the scope is held
    /// until the last one is read (releasing it first fails with
    /// `ExtAudioFileOpenURL` error -54).
    func importFolder(_ url: URL) {
        let root = self.root
        importing += 1
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let files = contents
                .filter(Library.looksLikeAudio)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let group = UUID()
            for (order, file) in files.enumerated() {
                let result = Result { try Library.importAudio(file, into: root, group: (id: group, order: Int64(order))) }
                await MainActor.run {
                    switch result {
                    case .success(let take): self.add(take)
                    case .failure(let error):
                        self.error = "Couldn't import \(file.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            await MainActor.run { self.importing -= 1 }
        }
    }

    /// The take after `take` in its import group, if any (and `take` has one).
    func nextInGroup(after take: Take) -> Take? {
        let ordered = groupOf(take)
        guard let i = ordered.firstIndex(where: { $0.id == take.id }), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    /// The takes imported from the same folder as `take` (or just `take`
    /// alone), in the folder's own order — a playlist.
    func groupOf(_ take: Take) -> [Take] {
        guard let group = take.info.group else { return [take] }
        return takes
            .filter { $0.info.group == group }
            .sorted { ($0.info.groupOrder ?? 0) < ($1.info.groupOrder ?? 0) }
    }

    /// Marks `id` as the take to start playing as soon as it opens (the
    /// folder chain handing over from the take before it).
    func requestChainPlay(_ id: UUID) { chainPlayID = id }

    /// True once for the take marked by `requestChainPlay`; consumes it.
    func takeChainPlay(_ id: UUID) -> Bool {
        guard chainPlayID == id else { return false }
        chainPlayID = nil
        return true
    }

    private var chainPlayID: UUID?

    nonisolated static let notImported = "Not Imported"

    /// The extensions the app opens, from the macOS app's list: what the
    /// Import and Open dialogs go by, and the first word of the README's
    /// format promises.
    nonisolated static let audioExtensions: Set<String> = [
        "wav", "wave", "mp3", "flac", "ogg", "oga", "m4a", "m4v", "mp4", "aac",
        "aif", "aiff", "aifc", "caf", "mka", "webm",
    ]

    /// True when `url` looks like audio by its name: the extension is on the
    /// list, or UTType calls it audio. The extension list leads because the
    /// system's extension-to-type mapping is unreliable where it matters:
    /// ".m4a" and ".mp4" can resolve to the mpeg-4 *movie* type, which is
    /// not audio, and the mapping moves between OS builds — a folder of M4As
    /// then imports as "no audio files".
    nonisolated static func looksLikeAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && audioExtensions.contains(ext) { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }

    /// A coordinated read of `url`, which downloads an iCloud Drive file
    /// that is still only a placeholder up there before anything tries to
    /// open it — the file picked from iCloud that hasn't been opened on the
    /// device yet fails AVAudioFile with "isn't audio that iOS can read".
    /// A local file goes through unchanged (and un-delayed).
    nonisolated static func downloaded(_ url: URL) -> URL {
        var failure: NSError?
        var resolved: URL?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &failure) { safe in
            resolved = safe
        }
        if let failure {
            // Coordinating a plain local file should never fail; if it does,
            // hand back the original and let the reader report the error.
            libraryLog.warning("Coordinated read of \(url.lastPathComponent, privacy: .public) failed: \(failure.localizedDescription)")
            return url
        }
        return resolved ?? url
    }

    /// Moves a file that wouldn't import into Documents/Not Imported.
    nonisolated static func setAside(_ url: URL) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent(notImported)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: url, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// A file opened from another app.
    func open(_ url: URL) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) {
            importInbox()
        } else {
            importFiles([url])
        }
    }

    // MARK: Files

    /// A new, empty take folder.
    nonisolated static func makeFolder(in root: URL) throws -> (UUID, URL) {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder)
    }

    nonisolated static func write(_ info: TakeInfo, to folder: URL) throws {
        try JSONEncoder.takes.encode(info).write(to: folder.appendingPathComponent("take.json"), options: .atomic)
    }

    nonisolated static func importAudio(_ url: URL, into root: URL, group: (id: UUID, order: Int64)? = nil) throws -> Take {
        let (id, folder) = try makeFolder(in: root)
        do {
            let audio = folder.appendingPathComponent(Take.firstAudioFile)
            let peaks = try AudioIO.convert(Library.downloaded(url), to: audio)
            try? peaks.write(to: Take.peaksURL(for: audio))
            let format = try AudioIO.reader(audio).fileFormat
            let info = TakeInfo(
                id: id, name: url.deletingPathExtension().lastPathComponent, created: Date(),
                audioFile: Take.firstAudioFile, frames: peaks.frames, sampleRate: format.sampleRate,
                channels: Int(format.channelCount), markers: [], overview: peaks.overview(columns: Take.overviewColumns),
                group: group?.id, groupOrder: group.map { Int($0.order) })
            try write(info, to: folder)
            return Take(info: info, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// A new take holding `range` of `take` (with the markers inside it).
    nonisolated static func clip(of take: Take, range: Range<Int64>, name: String, into root: URL) throws -> Take {
        let (id, folder) = try makeFolder(in: root)
        do {
            let audio = folder.appendingPathComponent(Take.firstAudioFile)
            let peaks = try Edits.render(.trim(range), from: take.audioURL, to: audio)
            try? peaks.write(to: Take.peaksURL(for: audio))
            let info = TakeInfo(
                id: id, name: name, created: Date(), audioFile: Take.firstAudioFile, frames: peaks.frames,
                sampleRate: take.info.sampleRate, channels: take.info.channels,
                markers: EditOp.trim(range).moved(take.info.markers), overview: peaks.overview(columns: Take.overviewColumns),
                group: nil, groupOrder: nil)
            try write(info, to: folder)
            return Take(info: info, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Deletes audio left over from edits (kept for undo while the take was open).
    nonisolated static func removeOldVersions(of take: Take) {
        let keep: Set<String> = [take.info.audioFile, take.peaksURL.lastPathComponent, "take.json"]
        let files = (try? FileManager.default.contentsOfDirectory(at: take.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Copied audio, kept as a file so it survives switching takes (and
/// relaunching).
enum Clipboard {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipboard.caf")
    }

    static var isEmpty: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// Copies `range` of the audio at `source`.
    static func copy(_ source: URL, range: Range<Int64>) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent("Clipboard-new.caf")
        try? FileManager.default.removeItem(at: temp)
        _ = try Edits.render(.trim(range), from: source, to: temp)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    /// The clipboard in a take's format: itself if it already matches,
    /// otherwise converted into `scratch`. Returns the file and its length.
    static func conformed(sampleRate: Double, channels: Int, scratch: URL) throws -> (URL, Int64) {
        let file = try AudioIO.reader(url)
        let format = file.processingFormat
        if format.sampleRate == sampleRate && Int(format.channelCount) == channels {
            return (url, file.length)
        }
        let frames = try AudioIO.conform(url, to: scratch, sampleRate: sampleRate, channels: channels)
        return (scratch, frames)
    }
}

extension JSONEncoder {
    static let takes: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let takes: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
