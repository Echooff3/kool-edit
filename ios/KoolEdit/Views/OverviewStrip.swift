import SwiftUI

/// The whole take in a strip above the waveform, with the part on screen
/// outlined in yellow (as in the macOS app). Touch it to move the view there.
struct OverviewStrip: View {
    let model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = Double(max(model.frames, 1))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let mid = size.height / 2, amp = size.height / 2 - 2
                    if let s = model.selection {
                        let a = CGFloat(Double(s.lowerBound) / total) * size.width
                        let b = CGFloat(Double(s.upperBound) / total) * size.width
                        ctx.fill(Path(CGRect(x: a, y: 0, width: max(b - a, 1), height: size.height)), with: .color(Color(uiColor: Theme.selectionBackground).opacity(0.35)))
                    }
                    if let peaks = model.peaks {
                        let per = total / Double(size.width)
                        var wave = Path()
                        for i in 0..<Int(size.width) {
                            guard let m = peaks.minMax(from: Double(i) * per, to: Double(i + 1) * per, framesPerPixel: per) else { continue }
                            let x = CGFloat(i) + 0.5
                            wave.move(to: CGPoint(x: x, y: mid - CGFloat(m.hi) * amp))
                            wave.addLine(to: CGPoint(x: x, y: max(mid - CGFloat(m.lo) * amp, mid - CGFloat(m.hi) * amp + 1)))
                        }
                        ctx.stroke(wave, with: .color(Color(uiColor: Theme.wave)), lineWidth: 1)
                    }
                    for marker in model.take.info.markers {
                        let x = CGFloat(Double(marker.frame) / total) * size.width
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color(uiColor: Theme.marker)))
                    }
                    // The part of the take on screen.
                    let v = model.visibleFrames
                    let a = CGFloat(v.lowerBound / total) * size.width
                    let b = CGFloat(v.upperBound / total) * size.width
                    ctx.stroke(Path(CGRect(x: a + 0.5, y: 0.5, width: max(b - a - 1, 2), height: size.height - 1)), with: .color(Color(uiColor: Theme.cursor)), lineWidth: 1)
                }
                if model.player.isPlaying {
                    TimelineView(.animation) { _ in
                        let x = CGFloat(Double(model.player.position) / total) * width
                        Rectangle()
                            .fill(Color(uiColor: Theme.playhead))
                            .frame(width: 1.5)
                            .offset(x: x)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                model.center(on: Double(drag.location.x / width) * total)
            })
        }
        .background(Color.black)
        .bevel(raised: false)
        .accessibilityLabel("Overview")
        .accessibilityHint("Touch to show that part of the take.")
    }
}
