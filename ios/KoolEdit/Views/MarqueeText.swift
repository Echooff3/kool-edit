import SwiftUI

/// A name too long for its space scrolls by itself, so one take can be
/// told from another; a name that fits sits still. The roll waits at
/// each end, then scrolls across and back.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color

    @State private var contentWidth = 0.0

    /// Room left before the roll starts, how fast it goes, and how long
    /// it waits at each end.
    private static let gap: Double = 14
    private static let speed: Double = 24
    private static let hold: Double = 1.8

    init(_ text: String, font: Font = Theme.font(15), color: Color = Theme.text) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            let travel = contentWidth + MarqueeText.gap - geo.size.width
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let offset = travel > 2
                    ? MarqueeText.roll(timeline.date.timeIntervalSinceReferenceDate, travel: travel)
                    : 0
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize()
                    .offset(x: offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        // Measured once, off the animated branch.
        .background(
            Text(text)
                .font(font)
                .fixedSize()
                .overlay(GeometryReader { g in Color.clear.onAppear { contentWidth = g.size.width } })
                .hidden()
        )
    }

    /// Hold, roll to the end, hold, roll back — repeating. The period
    /// covers the whole trip, so the jump home is a roll, not a snap.
    private static func roll(_ now: Double, travel: Double) -> Double {
        let d = travel / speed
        let period = 2 * (hold + d)
        let t = now.truncatingRemainder(dividingBy: period)
        if t < hold { return 0 }
        if t < hold + d { return -travel * (t - hold) / d }
        if t < 2 * hold + d { return -travel }
        return -travel * (1 - (t - 2 * hold - d) / d)
    }
}