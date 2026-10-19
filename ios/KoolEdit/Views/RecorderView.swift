import SwiftUI

/// Records a new take. The meter runs as soon as it opens, so levels can
/// be set first; the flag marks moments while recording.
struct RecorderView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onRecorded: (Take) -> Void
    @State private var recorder: Recorder?

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: recorder?.state == .recording ? "Recording…" : "New Recording")
            if let recorder {
                RecorderPanel(recorder: recorder, close: close)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(Theme.face)
        .task {
            guard recorder == nil else { return }
            let r = Recorder(library: library)
            recorder = r
            await r.prepare()
        }
        .onDisappear { recorder?.shutDown() }
    }

    private func close() {
        if let take = recorder?.stop() { onRecorded(take) }
        dismiss()
    }
}

private struct RecorderPanel: View {
    @Bindable var recorder: Recorder
    let close: () -> Void

    private var recording: Bool { recorder.state == .recording }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(recording ? "Stop & Close" : "Close", action: close)
                    .buttonStyle(ClassicButtonStyle())
                    .frame(width: 120, height: 34)
                Spacer()
            }

            ClassicGroup(title: "Input") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text(recorder.inputName.isEmpty ? "—" : recorder.inputName)
                            .font(Theme.font(13))
                            .lineLimit(1)
                    }
                    .sunkenField()
                    if let gain = recorder.inputGain {
                        HStack {
                            Text("Gain").font(Theme.font(12))
                            Slider(value: Binding(get: { Double(gain) }, set: { recorder.setInputGain(Float($0)) }), in: 0...1)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(recording ? "● REC" : recorder.state == .ready ? "READY" : "—")
                        .foregroundStyle(recording ? Color(hex: 0xFF3020) : Theme.lcdOn)
                    Text("\(Int(recorder.sampleRate)) Hz • \(recorder.channels == 1 ? "Mono" : "Stereo") • 24-bit")
                        .foregroundStyle(Theme.lcdOn)
                    Spacer()
                    if let left = recorder.spaceLeft {
                        Text("\(TimeFormat.span(left)) free").foregroundStyle(Theme.lcdOn)
                    }
                }
                .font(Theme.font(10))
                SevenSegment(text: TimeFormat.clock(recorder.elapsed, decimals: 1), height: 52)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black)
            .bevel(raised: false)

            LiveWave(peaks: recorder.recent)
                .frame(maxHeight: .infinity)
                .background(Color.black)
                .bevel(raised: false)

            LevelMeter(meter: recorder.meter) { recorder.resetClips() }
                .frame(height: 34)
                .bevel(raised: false)

            HStack {
                Text(recorder.markers.isEmpty
                     ? (recording ? "Tap the flag to mark a moment." : "Watch the meter while you play: aim to peak in the yellow.")
                     : recorder.markers.suffix(3).map { "\($0.name) \(TimeFormat.clock(Double($0.frame) / recorder.sampleRate, decimals: 1))" }.joined(separator: "   "))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.dark)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button {
                    recorder.mark()
                } label: {
                    Label("Mark", systemImage: "flag.fill")
                        .font(Theme.font(16, bold: true))
                        .foregroundStyle(recording ? Color(uiColor: Theme.marker) : Theme.disabled)
                }
                .buttonStyle(ClassicButtonStyle())
                .disabled(!recording)

                Button {
                    if recording { close() } else { recorder.record() }
                } label: {
                    HStack(spacing: 10) {
                        if recording {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.navy).frame(width: 18, height: 18)
                            Text("Stop")
                        } else {
                            Circle().fill(Theme.record).frame(width: 20, height: 20)
                            Text("Record")
                        }
                    }
                    .font(Theme.font(17, bold: true))
                }
                .buttonStyle(ClassicButtonStyle(latched: recording))
                .disabled(recorder.state == .off)
            }
            .frame(height: 64)
        }
        .padding(12)
        .alert("Kool Edit", isPresented: Binding(get: { recorder.message != nil }, set: { if !$0 { recorder.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.message ?? "")
        }
    }
}

/// The input's recent peaks, scrolling right to left.
private struct LiveWave: View {
    let peaks: [Float]

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: mid, width: size.width, height: 1)), with: .color(Color(uiColor: Theme.waveCenter)))
            let step = size.width / CGFloat(Recorder.recentCount)
            var path = Path()
            for (i, p) in peaks.reversed().enumerated() {
                let x = size.width - (CGFloat(i) + 0.5) * step
                let h = max(CGFloat(min(p, 1)) * (mid - 2), 0.5)
                path.move(to: CGPoint(x: x, y: mid - h))
                path.addLine(to: CGPoint(x: x, y: mid + h))
            }
            ctx.stroke(path, with: .color(Color(uiColor: Theme.wave)), lineWidth: max(step - 0.5, 1))
        }
    }
}
