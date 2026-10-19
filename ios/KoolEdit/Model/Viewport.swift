import Foundation

/// The stretch of a take on screen: the frame at the left edge and how many
/// frames each point covers.
struct Viewport: Equatable {
    /// Zoomed all the way in: 20 points per sample.
    static let closest = 0.05

    var start: Double = 0
    var scale: Double = 1000

    func frame(at x: Double) -> Double {
        start + x * scale
    }

    func x(at frame: Double) -> Double {
        (frame - start) / scale
    }

    func end(width: Double) -> Double {
        frame(at: width)
    }

    /// Keeps the view inside the take: no further out than the whole take,
    /// no further in than `closest`, and no scrolling past either end.
    mutating func clamp(width: Double, frames: Int64) {
        guard width > 0 else { return }
        let total = Double(max(frames, 1))
        scale = min(max(scale, Viewport.closest), max(total / width, Viewport.closest))
        start = min(max(start, 0), max(0, total - width * scale))
    }

    /// Zooms in by `factor` (out when below 1), keeping the frame at `x` still.
    mutating func zoom(by factor: Double, at x: Double, width: Double, frames: Int64) {
        let anchor = frame(at: x)
        scale /= factor
        clamp(width: width, frames: frames)
        start = anchor - x * scale
        clamp(width: width, frames: frames)
    }

    /// Shows `range` filling the width.
    mutating func show(_ range: Range<Double>, width: Double, frames: Int64) {
        guard width > 0 else { return }
        scale = (range.upperBound - range.lowerBound) / width
        start = range.lowerBound
        clamp(width: width, frames: frames)
    }
}
