import SwiftUI
import UIKit

/// Late-90s Windows chrome around a black waveform, Cool Edit style: the
/// macOS app's palette (src/ui/theme.rs), with touch-sized controls.
enum Theme {
    static let face = Color(hex: 0xD4D0C8)
    static let light = Color(hex: 0xE8E6E0)
    static let shadow = Color(hex: 0x808080)
    static let dark = Color(hex: 0x404040)
    static let navy = Color(hex: 0x0A246A)
    static let titleEnd = Color(hex: 0xA6CAF0)
    static let text = Color.black
    static let disabled = Color(hex: 0x808080)
    static let lcdOn = Color(hex: 0x30FF50)
    static let lcdOff = Color(hex: 0x062A0C)
    static let record = Color(hex: 0xE01810)
    static let field = Color.white

    // The waveform, drawn with UIKit.
    static let waveBackground = UIColor(hex: 0x000000)
    static let wave = UIColor(hex: 0x20E840)
    static let waveCenter = UIColor(hex: 0x006018)
    static let waveGrid = UIColor(hex: 0x002C0C)
    static let selectionBackground = UIColor(hex: 0xF0F0F8)
    static let selectionWave = UIColor(hex: 0x102890)
    static let selectionCenter = UIColor(hex: 0xA0A8D0)
    static let cursor = UIColor(hex: 0xFFFF30)
    static let playhead = UIColor(hex: 0xFF4030)
    static let marker = UIColor(hex: 0xFF9C00)
    static let uiFace = UIColor(hex: 0xD4D0C8)
    static let uiShadow = UIColor(hex: 0x808080)
    static let uiDark = UIColor(hex: 0x404040)

    /// Verdana ships with iOS and is Tahoma's wider sibling, the closest
    /// thing to the Windows 2000 interface font.
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Verdana-Bold" : "Verdana", fixedSize: size)
    }

    static func uiFont(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Verdana-Bold" : "Verdana", size: size) ?? .systemFont(ofSize: size)
    }

    /// For the time fields, as in the macOS app.
    static func mono(_ size: CGFloat) -> Font {
        .custom("CourierNewPSMT", fixedSize: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The classic two-step bevel: light top-left and dark bottom-right when
/// raised, the other way round when pushed in.
struct Bevel: View {
    var raised = true
    var thin = false

    var body: some View {
        Canvas { ctx, size in
            func edge(_ inset: CGFloat, _ topLeft: Color, _ bottomRight: Color) {
                let r = CGRect(origin: .zero, size: size).insetBy(dx: inset + 0.5, dy: inset + 0.5)
                var tl = Path()
                tl.move(to: CGPoint(x: r.minX, y: r.maxY))
                tl.addLine(to: CGPoint(x: r.minX, y: r.minY))
                tl.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                ctx.stroke(tl, with: .color(topLeft), lineWidth: 1)
                var br = Path()
                br.move(to: CGPoint(x: r.maxX, y: r.minY))
                br.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                br.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                ctx.stroke(br, with: .color(bottomRight), lineWidth: 1)
            }
            if raised {
                edge(0, .white, Theme.dark)
                if !thin { edge(1, Theme.light, Theme.shadow) }
            } else {
                edge(0, Theme.shadow, .white)
                if !thin { edge(1, Theme.dark, Theme.light) }
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func bevel(raised: Bool = true, thin: Bool = false) -> some View {
        overlay(Bevel(raised: raised, thin: thin))
    }

    /// A sunken white box, like a text field.
    func sunkenField() -> some View {
        padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(Theme.field)
            .bevel(raised: false)
    }
}

/// A raised Windows push button that sinks when pressed (or while `latched`).
struct ClassicButtonStyle: ButtonStyle {
    var latched = false

    func makeBody(configuration: Configuration) -> some View {
        ClassicButton(configuration: configuration, latched: latched)
    }

    private struct ClassicButton: View {
        let configuration: Configuration
        let latched: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let down = configuration.isPressed || latched
            configuration.label
                .font(Theme.font(13))
                .foregroundStyle(enabled ? Theme.text : Theme.disabled)
                .offset(x: down ? 1 : 0, y: down ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(latched ? Theme.light : Theme.face)
                .bevel(raised: !down)
                .contentShape(Rectangle())
        }
    }
}

/// An etched group box with a title, like Cool Edit's "Transport" and "Zoom".
struct ClassicGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(EdgeInsets(top: 14, leading: 6, bottom: 6, trailing: 6))
            .background {
                ZStack {
                    Rectangle().stroke(Color.white, lineWidth: 1).offset(x: 1, y: 1)
                    Rectangle().stroke(Theme.shadow, lineWidth: 1)
                }
                .padding(.top, 6)
            }
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 3)
                    .background(Theme.face)
                    .padding(.leading, 7)
            }
    }
}

/// The Windows 2000 title bar gradient, for screen headers.
struct TitleBar: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.font(13, bold: true))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: 22)
            // Kept out of the status bar, where it would hide the clock.
            .background(LinearGradient(colors: [Theme.navy, Theme.titleEnd], startPoint: .leading, endPoint: .trailing), ignoresSafeAreaEdges: [])
    }
}
