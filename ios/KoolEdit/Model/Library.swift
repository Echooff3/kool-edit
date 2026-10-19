import Foundation
import Observation
import UniformTypeIdentifiers

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

    // MARK: Importing

    /// Copies audio files in as new takes, in the background.
    func importFiles(_ urls: [URL], removingOriginals: Bool = false) {
        let root = self.root
        for url in urls where !inFlight.contains(url) {
            inFlight.insert(url)
            importing += 1
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                let result = Result { try Library.importAudio(url, into: root) }
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
            files += contents.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
        }
        importFiles(files, removingOriginals: true)
    }

    nonisolated static let notImported = "Not Imported"

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

    nonisolated static func importAudio(_ url: URL, into root: URL) throws -> Take {
        let (id, folder) = try makeFolder(in: root)
        do {
            let audio = folder.appendingPathComponent(Take.firstAudioFile)
            let peaks = try AudioIO.convert(url, to: audio)
            try? peaks.write(to: Take.peaksURL(for: audio))
            let format = try AudioIO.reader(audio).fileFormat
            let info = TakeInfo(
                id: id, name: url.deletingPathExtension().lastPathComponent, created: Date(),
                audioFile: Take.firstAudioFile, frames: peaks.frames, sampleRate: format.sampleRate,
                channels: Int(format.channelCount), markers: [], overview: peaks.overview(columns: Take.overviewColumns))
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
                markers: EditOp.trim(range).moved(take.info.markers), overview: peaks.overview(columns: Take.overviewColumns))
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
