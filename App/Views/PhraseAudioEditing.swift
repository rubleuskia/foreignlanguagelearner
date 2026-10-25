import SwiftUI
import SwiftData

struct PhraseAudioEditing: ViewModifier {
    let entry: DictionaryEntry
    let items: [LearningItem]
    let source: PhraseAudioSource
    let stopPlayback: () -> Void
    var mode: PhraseAudioMode = .selection
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
                PhraseAudioBoundaryEditor(entry: entry, items: items, source: source, mode: mode)
            }
    }
}

private struct PhraseAudioBoundaryEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let entry: DictionaryEntry
    let items: [LearningItem]
    let source: PhraseAudioSource
    let mode: PhraseAudioMode
    @State private var start: Double
    @State private var end: Double
    @State private var numeric = false
    @State private var editingEnd = false
    @State private var later = false
    @State private var seconds = "0.1"
    @State private var resetToAutomatic = false
    @State private var error: String?
    @State private var playback = PlaybackController()

    init(entry: DictionaryEntry, items: [LearningItem], source: PhraseAudioSource, mode: PhraseAudioMode) {
        self.mode = mode
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

    private var trackDuration: Double {
        guard let item = items.first(where: { $0.id == source.identity.itemID }) else { return end }
        return item.tracks.first(where: { $0.id == source.identity.trackID })?.duration ?? item.duration
    }

    // Keep the scale near the phrase so a tenth of a second remains practical on long chapters.
    @State private var sliderWindow: ClosedRange<Double>?
    private var window: ClosedRange<Double> {
        sliderWindow ?? max(0, start - 5)...min(trackDuration, end + 5)
    }

    private func changeBoundary(_ value: Double, isEnd: Bool) {
        if sliderWindow == nil { sliderWindow = window }
        let rounded = (value * 10).rounded() / 10
        let candidateStart = isEnd ? start : min(max(0, rounded), floor((end - 0.1) * 10) / 10)
        let candidateEnd = isEnd ? max(min(trackDuration, rounded), ceil((start + 0.1) * 10) / 10) : end
        guard resolved(start: candidateStart, end: candidateEnd) != nil else { return }
        playback.close()
        start = candidateStart
        end = candidateEnd
        resetToAutomatic = false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Phrase") {
                    Text(entry.text)
                    Text("Start: \(start.formatted(.number.precision(.fractionLength(2)))) s · End: \(end.formatted(.number.precision(.fractionLength(2)))) s")
                        .accessibilityIdentifier("audio-editor.range")
                }
                Section("Audio boundaries · 0.1 s") {
                    AudioRangeSlider(start: start, end: end, bounds: window) { value, isEnd in
                        changeBoundary(value, isEnd: isEnd)
                    }
                    HStack {
                        Text("Start: \(start.formatted(.number.precision(.fractionLength(1)))) s")
                        Spacer()
                        Text("End: \(end.formatted(.number.precision(.fractionLength(1)))) s")
                    }.font(.caption).monospacedDigit()
                    Button("Show whole track") { sliderWindow = 0...trackDuration }
                    Button("Zoom to phrase") { sliderWindow = max(0, start - 5)...min(trackDuration, end + 5) }
                }
                Section {
                    DisclosureGroup("Move boundary", isExpanded: $numeric) {
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
                            sliderWindow = nil
                        }
                        .disabled(shifted == nil)
                        .accessibilityIdentifier("audio-editor.apply")
                        Text("Choose a positive number of seconds. Boundaries must stay inside the track, with start before end.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                        guard let automatic = PhraseAudioSourceResolver.resolve(entry: entry, items: items, mode: mode, ignoreManualRange: true) else { return }
                        playback.close()
                        start = automatic.identity.range.lowerBound
                        end = automatic.identity.range.upperBound
                        resetToAutomatic = true
                        sliderWindow = nil
                    }
                    .disabled(PhraseAudioSourceResolver.resolve(entry: entry, items: items, mode: mode, ignoreManualRange: true) == nil)
                    if resetToAutomatic { Text("Automatic boundaries will be restored when you save.").font(.caption) }
                    if let message = error ?? playback.errorMessage { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle(mode == .sentence ? "Phrase boundaries" : "Audio boundaries")
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
        let previous = (entry.manualAudioStart, entry.manualAudioEnd,
                        entry.manualPhraseAudioStart, entry.manualPhraseAudioEnd)
        if mode == .sentence {
            entry.manualPhraseAudioStart = resetToAutomatic ? nil : start
            entry.manualPhraseAudioEnd = resetToAutomatic ? nil : end
        } else {
            entry.manualAudioStart = resetToAutomatic ? nil : start
            entry.manualAudioEnd = resetToAutomatic ? nil : end
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            entry.manualAudioStart = previous.0
            entry.manualAudioEnd = previous.1
            entry.manualPhraseAudioStart = previous.2
            entry.manualPhraseAudioEnd = previous.3
            self.error = "Could not save audio boundaries. Please try again."
        }
    }
}

/// Two independently accessible handles on one timeline; native shift controls remain available.
private struct AudioRangeSlider: View {
    let start: Double
    let end: Double
    let bounds: ClosedRange<Double>
    let change: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 44)
            let span = max(0.1, bounds.upperBound - bounds.lowerBound)
            let startX = 22 + width * (start - bounds.lowerBound) / span
            let endX = 22 + width * (end - bounds.lowerBound) / span
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25)).frame(height: 4).padding(.horizontal, 22)
                Capsule().fill(.tint).frame(width: max(0, endX - startX), height: 4).offset(x: startX)
                handle(isEnd: false, x: startX, width: width, span: span)
                handle(isEnd: true, x: endX, width: width, span: span)
            }
            .frame(height: 64)
            .coordinateSpace(name: "audio-range")
        }
        .frame(height: 64)
    }

    private func handle(isEnd: Bool, x: Double, width: Double, span: Double) -> some View {
        // Vertical separation keeps both targets usable even for very short phrases.
        Image(systemName: isEnd ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
            .font(.caption).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(.tint, in: Circle())
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .offset(x: x - 22, y: isEnd ? 12 : -12)
            .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .named("audio-range"))
                .onChanged { gesture in
                    guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                    let fraction = min(1, max(0, (gesture.location.x - 22) / width))
                    change(bounds.lowerBound + fraction * span, isEnd)
                })
            .accessibilityLabel(isEnd ? "Audio end" : "Audio start")
            .accessibilityValue("\((isEnd ? end : start).formatted(.number.precision(.fractionLength(1)))) seconds")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                change((isEnd ? end : start) + delta, isEnd)
            }
            .accessibilityIdentifier(isEnd ? "audio-editor.end-slider" : "audio-editor.start-slider")
    }
}
