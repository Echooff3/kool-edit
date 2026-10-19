import Foundation

/// Level meter ballistics for two channels: instant attack, a steady fall,
/// peak hold for a moment, and clip lights that stay on until reset.
struct Meter: Equatable {
    static let floor: Float = -60

    var db: [Float] = [-120, -120]
    var hold: [Float] = [-120, -120]
    var clipped = [false, false]
    private var holdTime: [Date] = [.distantPast, .distantPast]
    private var lastFeed = Date.distantPast

    /// Takes the latest peaks (linear, one per channel; mono feeds both bars).
    mutating func feed(_ peaks: [Float], now: Date = Date()) {
        guard let first = peaks.first else { return }
        let elapsed = Float(min(now.timeIntervalSince(lastFeed), 0.5))
        lastFeed = now
        for c in 0..<2 {
            let peak = c < peaks.count ? peaks[c] : first
            let level = Meter.decibels(peak)
            // Falls 24 dB a second.
            db[c] = max(level, db[c] - 24 * elapsed)
            if level >= hold[c] || now.timeIntervalSince(holdTime[c]) > 1.5 {
                hold[c] = level
                holdTime[c] = now
            }
            if peak >= 0.999 { clipped[c] = true }
        }
    }

    /// Lets the bars fall when nothing is feeding them.
    mutating func silence() {
        feed([0, 0])
    }

    mutating func resetClips() {
        clipped = [false, false]
    }

    static func decibels(_ linear: Float) -> Float {
        linear <= 1e-6 ? -120 : 20 * log10(linear)
    }
}
