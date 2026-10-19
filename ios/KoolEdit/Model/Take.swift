import Foundation

/// A moment worth coming back to.
struct Marker: Codable, Identifiable, Hashable {
    var id = UUID()
    var frame: Int64
    var name: String
}

/// What's saved in a take's take.json, beside its audio.
struct TakeInfo: Codable, Hashable {
    var id: UUID
    var name: String
    var created: Date
    /// The current audio file in the take's folder (each edit writes a new one).
    var audioFile: String
    var frames: Int64
    var sampleRate: Double
    var channels: Int
    var markers: [Marker]
    /// A small waveform for the take list, one byte per column.
    var overview: [UInt8]
}

/// A recording (or imported file): a folder holding its audio, the audio's
/// peaks and take.json.
struct Take: Identifiable, Hashable {
    var info: TakeInfo
    let folder: URL

    static let firstAudioFile = "audio.caf"
    static let overviewColumns = 96

    var id: UUID { info.id }
    var name: String { info.name }
    var audioURL: URL { folder.appendingPathComponent(info.audioFile) }
    var peaksURL: URL { Take.peaksURL(for: audioURL) }
    var duration: Double { info.sampleRate > 0 ? Double(info.frames) / info.sampleRate : 0 }
    var sortedMarkers: [Marker] { info.markers.sorted { $0.frame < $1.frame } }

    static func peaksURL(for audio: URL) -> URL {
        audio.appendingPathExtension("peaks")
    }

    /// "Jam Oct 19, 3:42 PM"
    static func defaultName(_ date: Date) -> String {
        "Jam " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A description of the audio, like the macOS app's status bar.
    var formatSummary: String {
        let channels = info.channels == 1 ? "Mono" : info.channels == 2 ? "Stereo" : "\(info.channels) ch"
        return "\(Int(info.sampleRate)) Hz • \(channels)"
    }
}
