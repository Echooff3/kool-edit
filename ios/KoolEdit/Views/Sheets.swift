import SwiftUI
import UIKit

/// The take's markers: jump to one, grab the stretch up to the next, rename
/// or delete.
struct MarkersSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Marker?
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                    Button {
                        model.jump(to: marker)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(Theme.font(12, bold: true))
                                .foregroundStyle(.black)
                                .frame(minWidth: 24, minHeight: 20)
                                .background(Color(uiColor: Theme.marker))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(marker.name).font(Theme.font(14)).foregroundStyle(Theme.text)
                                Text(TimeFormat.clock(model.seconds(marker.frame))).font(Theme.mono(12)).foregroundStyle(Theme.shadow)
                            }
                            Spacer()
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.deleteMarker(marker.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { rename(marker) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                    }
                    .contextMenu {
                        Button("Select to Next Marker", systemImage: "arrow.right.to.line") {
                            model.selectAround(marker.frame)
                            model.ensureVisible(marker.frame)
                            dismiss()
                        }
                        Button("Rename…", systemImage: "pencil") { rename(marker) }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteMarker(marker.id) }
                    }
                }
            }
            .overlay {
                if model.markers.isEmpty {
                    ContentUnavailableView(
                        "No Markers", systemImage: "flag",
                        description: Text("Tap the flag while playing or recording to mark a moment worth keeping."))
                }
            }
            .navigationTitle("Markers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !model.markers.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear All", role: .destructive) { model.deleteAllMarkers() }
                    }
                }
            }
            .alert("Rename Marker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") { if let renaming { model.renameMarker(renaming.id, to: name) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func rename(_ marker: Marker) {
        name = marker.name
        renaming = marker
    }
}

/// Picks a format, writes the file, then hands it to the share sheet
/// (Messages, AirDrop, Save to Files…).
struct ExportSheet: View {
    let model: EditorModel
    let whole: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format = ExportFormat.m4a
    @AppStorage("smoothEdges") private var smoothEdges = true
    @State private var file: SharedFile?

    var body: some View {
        let range = model.exportRange(whole: whole)
        let seconds = model.seconds(Int64(range.count))
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: model.exportName(whole: whole))
                    LabeledContent("From", value: "\(TimeFormat.clock(model.seconds(range.lowerBound))) to \(TimeFormat.clock(model.seconds(range.upperBound)))")
                    LabeledContent("Length", value: TimeFormat.clock(seconds))
                }
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            VStack(alignment: .leading) {
                                Text(f.title)
                                Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    LabeledContent("Size", value: ByteCountFormatter.string(
                        fromByteCount: Int64(seconds * format.bytesPerSecond(sampleRate: model.sampleRate, channels: model.take.info.channels)),
                        countStyle: .file))
                }
                Section {
                    Toggle("Smooth Edges", isOn: $smoothEdges)
                } footer: {
                    Text("Fades the first and last 5 ms so the clip doesn't start or end with a click.")
                }
            }
            .navigationTitle(whole ? "Share Take" : "Share Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") {
                        Task {
                            if let url = await model.export(format, whole: whole, smoothEdges: smoothEdges) {
                                file = SharedFile(url: url)
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.busy != nil || range.isEmpty)
                }
            }
            .overlay {
                if let busy = model.busy { BusyOverlay(text: busy) }
            }
            .sheet(item: $file) { file in
                ActivityView(items: [file.url]) { dismiss() }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var completion: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { completion() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Amplify by a number of decibels.
struct AmplifySheet: View {
    let apply: (Float) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("amplifyDB") private var dB = 3.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(format: "%+.1f dB", dB)).font(Theme.mono(20)).monospacedDigit()
                        Spacer()
                        Text(String(format: "×%.2f", pow(10, dB / 20))).foregroundStyle(.secondary)
                    }
                    Slider(value: $dB, in: -24...24, step: 0.5) {
                        Text("Gain")
                    } minimumValueLabel: {
                        Text("-24")
                    } maximumValueLabel: {
                        Text("+24")
                    }
                } footer: {
                    Text("Boosting past the loudest peak clips. Normalize raises it as far as it can go without clipping.")
                }
            }
            .navigationTitle("Amplify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(Float(dB))
                        dismiss()
                    }
                    .disabled(dB == 0)
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}
