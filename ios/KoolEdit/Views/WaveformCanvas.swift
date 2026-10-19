import SwiftUI
import UIKit

/// The waveform display, drawn with Core Graphics and driven by UIKit
/// gestures (SwiftUI has no two-finger pan):
///
/// - one finger drags a selection (drag near an edge to move that edge;
///   edges snap to markers), or scrubs when it starts on the time ruler
/// - two fingers scroll (with momentum) and pinch to zoom
/// - a tap puts the cursor down (seeking while playing); a tap on a marker
///   flag jumps to it
/// - a long press selects between the markers either side
struct WaveformView: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> WaveformCanvas {
        WaveformCanvas(model: model)
    }

    func updateUIView(_ view: WaveformCanvas, context: Context) {}
}

final class WaveformCanvas: UIView, UIGestureRecognizerDelegate {
    static let rulerHeight: CGFloat = 28
    /// How close (in points) a touch has to be to grab a selection edge.
    static let edgeReach: CGFloat = 26

    private enum Drag {
        case select(anchor: Int64)
        case scrub
    }

    let model: EditorModel
    private let playhead = CALayer()
    private var link: CADisplayLink?
    private var drag: Drag?
    private var dragX: CGFloat = 0
    private var fling: CGFloat = 0
    private var fingers = 0
    private var following = false
    private var snapped: Int64?
    private var selectPan: UIPanGestureRecognizer!
    private var scrollPan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = Theme.waveBackground
        isOpaque = true
        contentMode = .redraw
        playhead.backgroundColor = Theme.playhead.cgColor
        playhead.isHidden = true
        layer.addSublayer(playhead)
        isAccessibilityElement = true
        accessibilityLabel = "Waveform"
        accessibilityHint = "Drag to select. Pinch to zoom, two fingers to scroll."
        addGestures()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var waveRect: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.rulerHeight))
    }

    private var rulerRect: CGRect {
        CGRect(x: 0, y: waveRect.maxY, width: bounds.width, height: Self.rulerHeight)
    }

    /// Redraws whenever anything drawn changes.
    private func observe() {
        withObservationTracking {
            _ = model.viewport
            _ = model.selection
            _ = model.cursor
            _ = model.pausedAt
            _ = model.take.info.markers
            _ = model.version
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.setNeedsDisplay()
                self?.observe()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = Double(bounds.width)
        Task { @MainActor [model] in model.setViewWidth(width) }
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    // MARK: Coordinates

    private func frame(atX x: CGFloat) -> Int64 {
        let f = model.viewport.frame(at: Double(x)).rounded()
        return Int64(min(max(f, 0), Double(model.frames)))
    }

    private func x(of frame: Int64) -> CGFloat {
        CGFloat(model.viewport.x(at: Double(frame)))
    }

    private var pixel: CGFloat { 1 / max(traitCollection.displayScale, 1) }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let wave = waveRect
        let sel = model.selection.map { (max(x(of: $0.lowerBound), -2), min(x(of: $0.upperBound), bounds.width + 2)) }
        let outside: [CGRect]
        let inside: [CGRect]
        if case let (a, b)? = sel, b > 0, a < wave.width {
            outside = [CGRect(x: 0, y: wave.minY, width: max(a, 0), height: wave.height),
                       CGRect(x: b, y: wave.minY, width: max(wave.width - b, 0), height: wave.height)]
            inside = [CGRect(x: a, y: wave.minY, width: max(b - a, pixel), height: wave.height)]
        } else {
            outside = [wave]
            inside = []
        }

        ctx.setFillColor(Theme.waveBackground.cgColor)
        ctx.fill(wave)
        if let r = inside.first {
            ctx.setFillColor(Theme.selectionBackground.cgColor)
            ctx.fill(r)
        }

        // Centre line and the half-scale lines.
        let mid = wave.midY, amp = wave.height / 2 * 0.95
        let grid = CGMutablePath()
        for y in [mid - amp / 2, mid + amp / 2] {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: wave.width, y: y))
        }
        let center = CGMutablePath()
        center.move(to: CGPoint(x: 0, y: mid))
        center.addLine(to: CGPoint(x: wave.width, y: mid))
        stroke(ctx, grid, 1, Theme.waveGrid, clip: outside)
        stroke(ctx, center, 1, Theme.waveCenter, clip: outside)
        stroke(ctx, center, 1, Theme.selectionCenter, clip: inside)

        if case let (path, width, dots)? = wavePath(wave) {
            stroke(ctx, path, width, Theme.wave, clip: outside)
            stroke(ctx, path, width, Theme.selectionWave, clip: inside)
            if let dots {
                fill(ctx, dots, Theme.wave, clip: outside)
                fill(ctx, dots, Theme.selectionWave, clip: inside)
            }
        }

        // The ruler first so the marker flags sit on it, and the selection
        // edges under the markers so a marker on an edge still shows.
        drawRuler(ctx)
        if case let (a, b)? = sel { drawEdges(ctx, wave, a, b) }
        drawMarkers(ctx, wave)
        drawCursor(ctx, wave)
        if case let (a, b)? = sel { drawHandles(ctx, wave, a, b) }
    }

    private func stroke(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat, _ color: UIColor, clip: [CGRect]) {
        guard !clip.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, _ color: UIColor, clip: [CGRect]) {
        guard !clip.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The waveform as a path: a min/max line per pixel when zoomed out,
    /// the samples joined up (with dots when they're far apart) when in close.
    private func wavePath(_ wave: CGRect) -> (CGPath, CGFloat, CGPath?)? {
        let vp = model.viewport
        let px = pixel
        let perPixel = vp.scale * Double(px)
        let mid = wave.midY, amp = wave.height / 2 * 0.95
        let total = Double(model.frames)
        let path = CGMutablePath()

        func column(_ x: CGFloat, _ lo: Float, _ hi: Float) {
            let top = mid - CGFloat(hi) * amp, bottom = mid - CGFloat(lo) * amp
            path.move(to: CGPoint(x: x + px / 2, y: top))
            path.addLine(to: CGPoint(x: x + px / 2, y: max(bottom, top + px)))
        }

        if perPixel >= Double(Peaks.base), let peaks = model.peaks {
            var x: CGFloat = 0
            while x < wave.width {
                let f0 = vp.frame(at: Double(x)), f1 = f0 + perPixel
                if f1 > 0, f0 < total,
                   let m = peaks.minMax(from: max(0, f0), to: min(total, f1), framesPerPixel: perPixel) {
                    column(x, m.lo, m.hi)
                }
                x += px
            }
            return (path, px, nil)
        }

        guard let reader = model.reader else { return nil }
        let first = Int64(vp.start.rounded(.down)) - 1
        let last = Int64(vp.end(width: Double(wave.width)).rounded(.up)) + 1
        let (start, values) = reader.samples(first ..< last)
        guard !values.isEmpty else { return nil }

        if perPixel >= 1 {
            var x: CGFloat = 0
            while x < wave.width {
                let f0 = Int64(vp.frame(at: Double(x))), f1 = max(Int64(vp.frame(at: Double(x + px))), f0 + 1)
                let a = values.startIndex + max(0, Int(f0 - start))
                let b = values.startIndex + min(values.count, Int(f1 - start))
                if a < b {
                    var lo = values[a], hi = values[a]
                    for i in a ..< b {
                        lo = min(lo, values[i])
                        hi = max(hi, values[i])
                    }
                    column(x, lo, hi)
                }
                x += px
            }
            return (path, px, nil)
        }

        let pointsPerSample = 1 / vp.scale
        let dots = pointsPerSample >= 6 ? CGMutablePath() : nil
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: x(of: start + Int64(i)), y: mid - CGFloat(v) * amp)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            dots?.addRect(CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
        }
        return (path, 1, dots)
    }

    private func drawMarkers(_ ctx: CGContext, _ wave: CGRect) {
        let ruler = rulerRect
        let font = Theme.uiFont(9, bold: true)
        for (i, marker) in model.markers.enumerated() {
            let mx = x(of: marker.frame)
            guard mx > -30, mx < bounds.width + 30 else { continue }
            ctx.saveGState()
            ctx.setStrokeColor(Theme.marker.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.move(to: CGPoint(x: mx, y: wave.minY))
            ctx.addLine(to: CGPoint(x: mx, y: wave.maxY))
            ctx.strokePath()
            ctx.restoreGState()
            // A flag on the ruler with the marker's number.
            let label = "\(i + 1)" as NSString
            let size = label.size(withAttributes: [.font: font])
            let flag = CGRect(x: mx, y: ruler.maxY - 13, width: size.width + 6, height: 12)
            ctx.setFillColor(Theme.marker.cgColor)
            ctx.fill(flag)
            ctx.fill(CGRect(x: mx, y: ruler.minY, width: 1, height: ruler.height))
            label.draw(at: CGPoint(x: flag.minX + 3, y: flag.minY + (12 - size.height) / 2), withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
    }

    private func drawCursor(_ ctx: CGContext, _ wave: CGRect) {
        guard model.selection == nil || model.pausedAt != nil else { return }
        let cx = x(of: model.pausedAt ?? model.cursor)
        guard cx >= -1, cx <= bounds.width + 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(Theme.cursor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: cx, y: wave.minY))
        ctx.addLine(to: CGPoint(x: cx, y: wave.maxY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawEdges(_ ctx: CGContext, _ wave: CGRect, _ a: CGFloat, _ b: CGFloat) {
        for hx in [a, b] where hx >= -8 && hx <= bounds.width + 8 {
            ctx.setStrokeColor(Theme.selectionWave.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: hx, y: wave.minY))
            ctx.addLine(to: CGPoint(x: hx, y: wave.maxY))
            ctx.strokePath()
        }
    }

    /// Grab handles on the selection edges, sized for fingers.
    private func drawHandles(_ ctx: CGContext, _ wave: CGRect, _ a: CGFloat, _ b: CGFloat) {
        for hx in [a, b] where hx >= -8 && hx <= bounds.width + 8 {
            let knob = CGRect(x: hx - 8, y: wave.maxY - 22, width: 16, height: 16)
            ctx.setFillColor(Theme.selectionWave.cgColor)
            ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: knob.insetBy(dx: 1, dy: 1))
        }
    }

    private func drawRuler(_ ctx: CGContext) {
        let r = rulerRect
        ctx.setFillColor(Theme.uiFace.cgColor)
        ctx.fill(r)
        ctx.setFillColor(Theme.uiDark.cgColor)
        ctx.fill(CGRect(x: 0, y: r.minY, width: r.width, height: 1))
        let vp = model.viewport
        let rate = model.sampleRate
        guard rate > 0, vp.scale > 0 else { return }
        let (step, minor) = TimeFormat.rulerStep(secondsPerPoint: vp.scale / rate, spacing: 76)
        let t0 = vp.start / rate, t1 = vp.end(width: Double(r.width)) / rate
        let font = Theme.uiFont(10)
        let ticks = CGMutablePath()
        var k = (t0 / step).rounded(.down)
        while k * step <= t1 + step {
            let t = k * step
            let tx = CGFloat(vp.x(at: t * rate))
            ticks.addRect(CGRect(x: tx, y: r.minY, width: 1, height: 7))
            for m in 1 ..< minor {
                let mx = CGFloat(vp.x(at: (t + step * Double(m) / Double(minor)) * rate))
                ticks.addRect(CGRect(x: mx, y: r.minY, width: 1, height: 3))
            }
            if t >= 0 {
                (TimeFormat.ruler(t, step: step) as NSString).draw(
                    at: CGPoint(x: tx + 3, y: r.minY + 3), withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
            k += 1
        }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.addPath(ticks)
        ctx.fillPath()
    }

    // MARK: The playhead and animation

    @objc private func tick(_ link: CADisplayLink) {
        let dt = CGFloat(max(link.targetTimestamp - link.timestamp, 1 / 120))
        if fling != 0, fingers == 0 {
            scroll(by: fling * dt)
            fling *= pow(0.05, dt)
            if abs(fling) < 15 { fling = 0 }
        }
        if case .select = drag {
            // Scroll when a selection is dragged to either edge.
            let zone: CGFloat = 32
            let push = dragX < zone ? -(zone - dragX) / zone : dragX > bounds.width - zone ? (dragX - bounds.width + zone) / zone : 0
            if push != 0 {
                scroll(by: -push * 700 * dt)
                updateDrag(at: dragX)
            }
        }
        updatePlayhead()
    }

    private func updatePlayhead() {
        let player = model.player
        guard player.isPlaying else {
            playhead.isHidden = true
            following = false
            return
        }
        let position = player.position
        var px = x(of: position)
        // Page along with playback, unless a finger is on the waveform or
        // the view was scrolled away from the playhead.
        if following, fingers == 0, drag == nil, px > bounds.width * 0.92 {
            var vp = model.viewport
            vp.start = Double(position) - Double(bounds.width) * 0.05 * vp.scale
            vp.clamp(width: Double(bounds.width), frames: model.frames)
            model.viewport = vp
            px = x(of: position)
        }
        following = px >= 0 && px <= bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.isHidden = !following
        playhead.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: waveRect.height)
        CATransaction.commit()
    }

    private func scroll(by points: CGFloat) {
        var vp = model.viewport
        vp.start -= Double(points) * vp.scale
        vp.clamp(width: Double(bounds.width), frames: model.frames)
        if vp != model.viewport { model.viewport = vp } else { fling = 0 }
    }

    // MARK: Gestures

    private func addGestures() {
        selectPan = UIPanGestureRecognizer(target: self, action: #selector(selecting(_:)))
        selectPan.maximumNumberOfTouches = 1
        scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrolling(_:)))
        scrollPan.minimumNumberOfTouches = 2
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinching(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 10
        for g in [selectPan, scrollPan, pinch, tap, press] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === scrollPan && other === pinch) || (g === pinch && other === scrollPan)
    }

    /// Gestures further up (the navigation back-swipe, which on iOS 26 works
    /// from anywhere on the screen) wait for the waveform's, so dragging a
    /// selection never leaves the editor.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let view = other.view, view !== self else { return false }
        return isDescendant(of: view)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        fingers += touches.count
        fling = 0
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        fingers = max(0, fingers - touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        fingers = max(0, fingers - touches.count)
    }

    @objc private func selecting(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: self)
        dragX = location.x
        switch g.state {
        case .began:
            let start = CGPoint(x: location.x - g.translation(in: self).x, y: location.y - g.translation(in: self).y)
            snapped = nil
            if start.y >= rulerRect.minY {
                drag = .scrub
            } else if let s = model.selection, let anchor = edgeAnchor(s, near: start.x) {
                drag = .select(anchor: anchor)
            } else {
                drag = .select(anchor: frame(atX: start.x))
            }
            selection.prepare()
            updateDrag(at: location.x)
        case .changed:
            updateDrag(at: location.x)
        default:
            if case .select(let anchor) = drag, model.selection == nil { model.setCursor(anchor) }
            drag = nil
        }
    }

    /// When `x` is near an edge of the selection, the other edge (which
    /// stays put while this one moves).
    private func edgeAnchor(_ s: Range<Int64>, near x: CGFloat) -> Int64? {
        let (a, b) = (self.x(of: s.lowerBound), self.x(of: s.upperBound))
        let (da, db) = (abs(x - a), abs(x - b))
        guard min(da, db) <= Self.edgeReach else { return nil }
        return da < db ? s.upperBound : s.lowerBound
    }

    private func updateDrag(at x: CGFloat) {
        switch drag {
        case .scrub:
            model.setCursor(frame(atX: x))
        case .select(let anchor):
            var f = frame(atX: x)
            let mark = model.markers.first { abs(self.x(of: $0.frame) - x) < 10 }
            if let mark { f = mark.frame }
            if mark?.frame != snapped {
                snapped = mark?.frame
                if mark != nil { selection.selectionChanged() }
            }
            model.select(min(anchor, f) ..< max(anchor, f))
        case nil:
            break
        }
    }

    @objc private func scrolling(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .changed:
            scroll(by: g.translation(in: self).x)
            g.setTranslation(.zero, in: self)
        case .ended:
            fling = g.velocity(in: self).x
        default:
            break
        }
    }

    @objc private func pinching(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed || g.state == .began, g.numberOfTouches >= 2 else { return }
        var vp = model.viewport
        vp.zoom(by: Double(g.scale), at: Double(g.location(in: self).x), width: Double(bounds.width), frames: model.frames)
        g.scale = 1
        model.viewport = vp
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if p.y >= rulerRect.minY,
           let mark = model.markers.min(by: { abs(x(of: $0.frame) - p.x) < abs(x(of: $1.frame) - p.x) }),
           abs(x(of: mark.frame) + 6 - p.x) < 18 {
            model.jump(to: mark)
            return
        }
        model.setCursor(frame(atX: p.x))
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, g.location(in: self).y < rulerRect.minY else { return }
        model.selectAround(frame(atX: g.location(in: self).x))
        impact.impactOccurred()
    }
}
