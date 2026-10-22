import SwiftUI
import SwiftData

struct PhraseAudioEditing: ViewModifier {
    let entry: DictionaryEntry
    let items: [LearningItem]
    let source: PhraseAudioSource
    let stopPlayback: () -> Void
    @State private var editing = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Edit audio boundaries", systemImage: "slider.horizontal.3") {
                    stopPlayback()
                    editing = true
                }
            }
            .sheet(isPresented: $editing) {
                PhraseAudioBoundaryEditor(entry: entry, items: items, source: source)
            }
    }
}

private struct PhraseAudioBoundaryEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let entry: DictionaryEntry
    let items: [LearningItem]
    let source: PhraseAudioSource
    @State private var start: Double
    @State private var end: Double
    @State private var editingEnd = false
    @State private var later = false
    @State private var seconds = "0.1"
    @State private var resetToAutomatic = false
    @State private var error: String?
    @State private var playback = PlaybackController()

    init(entry: DictionaryEntry, items: [LearningItem], source: PhraseAudioSource) {
        self.entry = entry
        self.items = items
        self.source = source
        _start = State(initialValue: source.identity.range.lowerBound)
        _end = State(initialValue: source.identity.range.upperBound)
    }

    private var amount: Double? {
        guard let value = Double(seconds.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    private func resolved(start: Double, end: Double) -> PhraseAudioSource? {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return PhraseAudioSourceResolver.resolve(localSourceItemID: entry.localSourceItemID,
            sourceItemID: entry.sourceItemID, audioRange: start...end,
            sourceTrackID: entry.sourceTrackID, items: items)
    }

    private var shifted: PhraseAudioSource? {
        guard let amount else { return nil }
        let delta = later ? amount : -amount
        return resolved(start: start + (editingEnd ? 0 : delta), end: end + (editingEnd ? delta : 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Phrase") {
                    Text(entry.text)
                    Text("Start: \(start.formatted(.number.precision(.fractionLength(2)))) s · End: \(end.formatted(.number.precision(.fractionLength(2)))) s")
                        .accessibilityIdentifier("audio-editor.range")
                }
                Section("Move boundary") {
                    Picker("Boundary", selection: $editingEnd) {
                        Text("Start").tag(false)
                        Text("End").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("Direction", selection: $later) {
                        Text("Earlier").tag(false)
                        Text("Later").tag(true)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Seconds")
                        TextField("Seconds", text: $seconds)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("audio-editor.seconds")
                    }
                    Button("Apply shift") {
                        guard let shifted else { return }
                        playback.close()
                        start = shifted.identity.range.lowerBound
                        end = shifted.identity.range.upperBound
                        resetToAutomatic = false
                    }
                    .disabled(shifted == nil)
                    .accessibilityIdentifier("audio-editor.apply")
                    Text("Choose a positive number of seconds. Boundaries must stay inside the track, with start before end.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(playback.isPlaying ? "Stop preview" : "Play preview", systemImage: "play.circle") {
                        if playback.isPlaying { playback.close(); return }
                        guard let preview = resolved(start: start, end: end) else { return }
                        playback.open(url: preview.identity.url, position: start, range: preview.identity.range)
                        playback.play()
                    }
                    .disabled(resolved(start: start, end: end) == nil)
                    Button("Reset to automatic boundaries") {
                        guard let automatic = PhraseAudioSourceResolver.resolve(entry: entry, items: items, ignoreManualRange: true) else { return }
                        playback.close()
                        start = automatic.identity.range.lowerBound
                        end = automatic.identity.range.upperBound
                        resetToAutomatic = true
                    }
                    .disabled(PhraseAudioSourceResolver.resolve(entry: entry, items: items, ignoreManualRange: true) == nil)
                    if resetToAutomatic { Text("Automatic boundaries will be restored when you save.").font(.caption) }
                    if let message = error ?? playback.errorMessage { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Audio boundaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(resolved(start: start, end: end) == nil)
                        .accessibilityIdentifier("audio-editor.save")
                }
            }
        }
        .onDisappear { playback.close() }
    }

    private func save() {
        guard resolved(start: start, end: end) != nil else { return }
        let previous = (entry.manualAudioStart, entry.manualAudioEnd)
        entry.manualAudioStart = resetToAutomatic ? nil : start
        entry.manualAudioEnd = resetToAutomatic ? nil : end
        do {
            try modelContext.save()
            dismiss()
        } catch {
            entry.manualAudioStart = previous.0
            entry.manualAudioEnd = previous.1
            self.error = "Could not save audio boundaries. Please try again."
        }
    }
}
