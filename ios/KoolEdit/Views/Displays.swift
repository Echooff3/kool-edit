import SwiftUI

/// Glowing seven-segment digits with the unlit segments faintly behind
/// them, drawn the same way as the macOS app's LCD.
struct SevenSegment: View {
    let text: String
    var height: CGFloat
    var on = Theme.lcdOn
    var off = Theme.lcdOff

    private static let masks: [UInt8] = [
        0b0111111, 0b0000110, 0b1011011, 0b1001111, 0b1100110,
        0b1101101, 0b1111101, 0b0000111, 0b1111111, 0b1101111,
    ]

    static func advance(_ c: Character, height h: CGFloat) -> CGFloat {
        c == ":" || c == "." ? h * 0.32 : h * 0.62
    }

    static func width(_ text: String, height h: CGFloat) -> CGFloat {
        text.reduce(0) { $0 + advance($1, height: h) } + h * 0.08
    }

    var body: some View {
        Canvas { ctx, _ in
            let h = height
            let t = max(h * 0.11, 2)
            let w = h * 0.5
            let skew: CGFloat = 0.07
            func k(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + (h - y) * skew, y: y) }
            func polygon(_ points: [CGPoint]) -> Path {
                var p = Path()
                p.addLines(points)
                p.closeSubpath()
                return p
            }
            var x: CGFloat = 0
            for c in text {
                switch c {
                case ":":
                    for fy in [0.3, 0.72] {
                        let p = k(x + h * 0.12, h * fy)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - t * 0.6, y: p.y - t * 0.6, width: t * 1.2, height: t * 1.2)), with: .color(on))
                    }
                case ".":
                    let p = k(x + h * 0.1, h - t * 0.6)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - t * 0.6, y: p.y - t * 0.6, width: t * 1.2, height: t * 1.2)), with: .color(on))
                default:
                    let mask = c.wholeNumberValue.map { Self.masks[$0] } ?? 0
                    let (x0, x1) = (x + t * 0.5, x + w - t * 0.5)
                    let (y0, ym, y1) = (t * 0.5, h * 0.5, h - t * 0.5)
                    let g = t * 0.18
                    func horizontal(_ y: CGFloat) -> Path {
                        polygon([
                            k(x0 + g, y), k(x0 + g + t * 0.5, y - t * 0.5), k(x1 - g - t * 0.5, y - t * 0.5),
                            k(x1 - g, y), k(x1 - g - t * 0.5, y + t * 0.5), k(x0 + g + t * 0.5, y + t * 0.5),
                        ])
                    }
                    func vertical(_ sx: CGFloat, _ ya: CGFloat, _ yb: CGFloat) -> Path {
                        polygon([
                            k(sx, ya + g), k(sx + t * 0.5, ya + g + t * 0.5), k(sx + t * 0.5, yb - g - t * 0.5),
                            k(sx, yb - g), k(sx - t * 0.5, yb - g - t * 0.5), k(sx - t * 0.5, ya + g + t * 0.5),
                        ])
                    }
                    let segments = [
                        horizontal(y0), vertical(x1, y0, ym), vertical(x1, ym, y1), horizontal(y1),
                        vertical(x0, ym, y1), vertical(x0, y0, ym), horizontal(ym),
                    ]
                    for (i, segment) in segments.enumerated() {
                        ctx.fill(segment, with: .color(mask & (1 << i) != 0 ? on : off))
                    }
                }
                x += Self.advance(c, height: h)
            }
        }
        .frame(width: Self.width(text, height: height), height: height)
        .shadow(color: on.opacity(0.45), radius: height * 0.08)
        .accessibilityLabel(text)
    }
}

/// Cool Edit's LED level meter: two bars of segments, green to yellow to
/// red, with peak hold, clip lights and a dB scale. Tap to reset the clips.
struct LevelMeter: View {
    let meter: Meter
    var onReset: () -> Void = {}

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let clipWidth: CGFloat = 10, scaleHeight: CGFloat = 12
            let bars = CGRect(x: 2, y: 2, width: size.width - clipWidth - 6, height: size.height - scaleHeight - 3)
            let barHeight = (bars.height - 2) / 2
            func x(_ db: Float) -> CGFloat {
                bars.minX + CGFloat(min(max((db - Meter.floor) / -Meter.floor, 0), 1)) * bars.width
            }
            func color(_ db: Float) -> Color {
                db >= -6 ? Color(hex: 0xFF3020) : db >= -18 ? Color(hex: 0xF0E020) : Color(hex: 0x20E040)
            }
            let segment: CGFloat = 4
            for ch in 0..<2 {
                let y0 = bars.minY + CGFloat(ch) * (barHeight + 2)
                var sx = bars.minX
                while sx + segment - 1 <= bars.maxX {
                    let db = Meter.floor + Float((sx - bars.minX + segment / 2) / bars.width) * -Meter.floor
                    let lit = db <= meter.db[ch]
                    ctx.fill(Path(CGRect(x: sx, y: y0, width: segment - 1, height: barHeight)), with: .color(color(db).opacity(lit ? 1 : 0.16)))
                    sx += segment
                }
                if meter.hold[ch] > Meter.floor {
                    ctx.fill(Path(CGRect(x: x(meter.hold[ch]) - 1, y: y0, width: 2, height: barHeight)), with: .color(color(meter.hold[ch])))
                }
                let clip = CGRect(x: size.width - clipWidth - 1, y: y0, width: clipWidth - 1, height: barHeight)
                ctx.fill(Path(clip), with: .color(Color(hex: 0xFF2020).opacity(meter.clipped[ch] ? 1 : 0.18)))
            }
            let step = size.width > 520 ? 3 : size.width > 300 ? 6 : 12
            for db in stride(from: Int(Meter.floor), through: 0, by: step) {
                let px = x(Float(db)), y = size.height - scaleHeight
                ctx.fill(Path(CGRect(x: px - 0.5, y: y, width: 1, height: 3)), with: .color(Color(white: 0.6)))
                let label = db == Int(Meter.floor) ? "dB" : "\(db)"
                let anchor: UnitPoint = db == 0 ? .topTrailing : db == Int(Meter.floor) ? .topLeading : .top
                ctx.draw(Text(label).font(Theme.font(8)).foregroundStyle(Color(white: 0.8)), at: CGPoint(x: px, y: y + 2), anchor: anchor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onReset)
        .accessibilityLabel("Level meter")
    }
}
