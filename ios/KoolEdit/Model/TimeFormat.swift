import Foundation

/// `m:ss.ddd` style times, as in the macOS app's timefmt.rs.
enum TimeFormat {
    /// Seconds as `m:ss.ddd` (or `h:mm:ss.ddd`) with `decimals` fractional digits.
    static func clock(_ seconds: Double, decimals: Int = 3) -> String {
        let scale = pow(10, Double(decimals))
        let total = UInt64((max(0, seconds) * scale).rounded())
        let unit = UInt64(scale)
        let frac = Int(total % unit), whole = Int(total / unit)
        let (h, m, s) = (whole / 3600, (whole / 60) % 60, whole % 60)
        var out = h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
        if decimals > 0 { out += "." + String(format: "%0\(decimals)ld", frac) }
        return out
    }

    /// Parses `ss.ddd`, `m:ss.ddd` or `h:mm:ss.ddd`.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for (i, part) in parts.enumerated() {
            guard let v = Double(part.trimmingCharacters(in: .whitespaces)), v >= 0,
                  i == parts.count - 1 || v.rounded() == v
            else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    /// "2h 05m", "12m 30s", "45s": for durations and space left.
    static func span(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 { return String(format: "%ldh %02ldm", s / 3600, (s / 60) % 60) }
        if s >= 60 { return String(format: "%ldm %02lds", s / 60, s % 60) }
        return "\(s)s"
    }

    /// "2m03s" for file names.
    static func stamp(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 { return String(format: "%ldh%02ldm%02lds", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%ldm%02lds", s / 60, s % 60)
    }

    /// A tidy interval between time ruler labels at least `spacing` points
    /// apart, and how many minor ticks to split it into.
    static func rulerStep(secondsPerPoint: Double, spacing: Double) -> (step: Double, minor: Int) {
        let steps: [(Double, Int)] = [
            (0.001, 5), (0.002, 4), (0.005, 5), (0.01, 5), (0.02, 4), (0.05, 5), (0.1, 5), (0.2, 4), (0.5, 5),
            (1, 5), (2, 4), (5, 5), (10, 5), (15, 3), (30, 6), (60, 6), (120, 4), (300, 5), (600, 5), (900, 3),
            (1800, 6), (3600, 6),
        ]
        for (step, minor) in steps where step / secondsPerPoint >= spacing {
            return (step, minor)
        }
        return (7200, 4)
    }

    /// A ruler label, with as many decimals as the step needs.
    static func ruler(_ seconds: Double, step: Double) -> String {
        clock(seconds, decimals: step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3)
    }
}
