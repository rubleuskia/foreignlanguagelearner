import SwiftUI
import SwiftData
import AVKit

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    let item: LearningItem
    @State private var playback = PlaybackController()
    @State private var following = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var message: String?
    @State private var selectedPart = 0
    @State private var sourceLanguages = [SourceLanguage.polish]
    @State private var translationPreview: SelectionTranslationPreview?
    @State private var followGeneration = 0

    private var currentPart: LearningPart? { item.parts.indices.contains(selectedPart) ? item.parts[selectedPart] : nil }
    private var document: TranscriptDocument {
        guard let part = currentPart else { return TranscriptDocument(segments: item.segments) }
        let indexed = item.segments.enumerated().filter { ($0.element.end ?? -.infinity) > part.start && ($0.element.start ?? .infinity) < part.end }
        return TranscriptDocument(segments: indexed.map(\.element), sourceIndices: indexed.map(\.offset))
    }
    private var lowerBound: Double { currentPart?.start ?? 0 }
    private var upperBound: Double { currentPart?.end ?? item.duration }
    private var displayedLanguages: [SourceLanguage] {
        sourceLanguages.contains(where: { $0.code == item.sourceLanguageCode })
            ? sourceLanguages
            : [.init(code: item.sourceLanguageCode, name: SourceLanguage.name(for: item.sourceLanguageCode))] + sourceLanguages
    }

    var body: some View {
        VStack(spacing: 0) {
            if item.mediaKind == "video" {
                VideoPlayer(player: playback.player).frame(height: 200)
            }
            if item.segments.first?.start == nil {
                Text("This transcript has no timestamps. You can read and save phrases; synchronized scrolling requires SRT or WebVTT.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            TranscriptTextView(document: document,
                               activeSegment: document.activeSegment(at: playback.position),
                               following: $following,
                               followGeneration: followGeneration,
                               onSelectionBegan: {
                playback.pause()
                following = false
            }) { action, text, selectionRange, segment, selectionContext in
                let absoluteSegment = segment.flatMap { document.sourceIndices.indices.contains($0) ? document.sourceIndices[$0] : nil }
                let audio = audioRange(for: selectionRange)
                let normalized = DictionaryEntry.normalized(text)
                guard !normalized.isEmpty else { return }
                switch action {
                case .addToDictionary:
                    let entry = DictionaryEntry(text: normalized, item: item,
                                                segmentIndex: absoluteSegment,
                                                context: selectionContext,
                                                audioStart: audio?.lowerBound,
                                                audioEnd: audio?.upperBound)
                    context.insert(entry)
                    do {
                        try context.save()
                        translationCoordinator.enqueue(entry, context: context)
                        message = "Added to Dictionary"
                    } catch {
                        context.delete(entry)
                        message = error.localizedDescription
                    }
                case .translateInContext:
                    playback.pause()
                    following = false
                    translationPreview = SelectionTranslationPreview(
                        selectedText: normalized,
                        sourceLanguageCode: item.sourceLanguageCode,
                        context: selectionContext,
                        sourceItemID: item.id,
                        sourceTitle: item.title,
                        audioRange: audio
                    )
                }
            }
            if !following && item.segments.contains(where: { $0.start != nil && $0.end != nil }) {
                Button("Follow audio", systemImage: "arrow.down.to.line") {
                    followGeneration += 1
                    following = true
                }
                    .padding(8)
            }
        }
        .safeAreaInset(edge: .bottom) { playerBar }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Language", systemImage: "character.book.closed") {
                    ForEach(displayedLanguages) { language in
                        Button {
                            changeLanguage(to: language.code)
                        } label: {
                            if item.sourceLanguageCode == language.code { Label(language.name, systemImage: "checkmark") }
                            else { Text(language.name) }
                        }
                    }
                }
            }
        }
        .onAppear {
            selectedPart = item.partIndex(containing: item.lastPosition)
            openCurrentPart()
        }
        .task { sourceLanguages = await SourceLanguage.availableForRussian() }
        .sheet(item: $translationPreview) {
            SelectionTranslationView(preview: $0)
        }
        .onChange(of: playback.position) { _, position in
            if abs(item.lastPosition - position) >= 5 {
                item.lastPosition = position
                updatePartPosition(position)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { savePosition() }
        }
        .onDisappear { savePosition(); playback.close() }
        .alert("Dictionary", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .alert("Playback error", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
            Button("OK") { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
    }

    private var playerBar: some View {
        VStack(spacing: 8) {
            if !item.parts.isEmpty {
                HStack {
                    Menu("Part \(selectedPart + 1) of \(item.parts.count)") {
                        ForEach(item.parts.indices, id: \.self) { index in
                            Button("Part \(index + 1)\(item.parts[index].isCompleted ? " · Completed" : "")") { switchToPart(index) }
                        }
                    }
                    Spacer()
                    Button(currentPart?.isCompleted == true ? "Completed" : "Mark completed", systemImage: currentPart?.isCompleted == true ? "checkmark.circle.fill" : "circle") { toggleCompleted() }
                }
            }
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(max(playback.position, lowerBound), upperBound) }, set: { scrubPosition = $0 }), in: lowerBound...max(upperBound, lowerBound + 0.01)) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubPosition); following = true }
            }.accessibilityLabel("Playback position")
            HStack {
                Text(time(playback.position)).monospacedDigit()
                Spacer()
                Button { playback.seek(to: max(lowerBound, playback.position - 10)); following = true } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Back 10 seconds")
                Button { playback.toggle(); if playback.isPlaying { following = true } } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.seek(to: min(upperBound, playback.position + 10)); following = true } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel("Forward 10 seconds")
                Spacer()
                PlaybackRateMenu(playback: playback)
                Text(time(upperBound)).monospacedDigit()
            }
        }.padding().background(.bar)
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func audioRange(for selectionRange: NSRange) -> ClosedRange<Double>? {
        let matching = document.ranges.indices.filter {
            NSIntersectionRange(document.ranges[$0], selectionRange).length > 0
        }
        let absoluteIndices = matching.compactMap { index -> Int? in
            guard document.sourceIndices.indices.contains(index) else { return nil }
            return document.sourceIndices[index]
        }
        let timed = absoluteIndices.compactMap { index -> (index: Int, segment: TranscriptSegment)? in
            guard item.segments.indices.contains(index), item.segments[index].start != nil,
                  item.segments[index].end != nil else { return nil }
            return (index, item.segments[index])
        }
        guard let first = timed.compactMap({ $0.segment.start }).min(),
              let last = timed.compactMap({ $0.segment.end }).max(), last > first else { return nil }

        let nextStart = item.segments.drop(while: { ($0.end ?? -.infinity) <= last })
            .compactMap(\.start).first
        let paddedEnd = min(last + 0.75, nextStart ?? item.duration, item.duration)
        guard paddedEnd > first else { return first...last }
        return first...paddedEnd
    }

    private func openCurrentPart() {
        let range = currentPart.map { $0.start...$0.end }
        playback.open(url: MediaImportService.directory(for: item.id).appending(path: item.mediaFilename), position: currentPart?.lastPosition ?? item.lastPosition, range: range)
    }

    private func switchToPart(_ index: Int) {
        savePosition()
        playback.close()
        selectedPart = index
        following = true
        openCurrentPart()
    }

    private func toggleCompleted() {
        guard item.parts.indices.contains(selectedPart) else { return }
        item.parts[selectedPart].isCompleted.toggle()
        try? context.save()
    }

    private func updatePartPosition(_ position: Double) {
        guard item.parts.indices.contains(selectedPart) else { return }
        item.parts[selectedPart].lastPosition = position
    }

    private func savePosition() {
        item.lastPosition = playback.position
        updatePartPosition(playback.position)
        try? context.save()
    }

    private func changeLanguage(to code: String) {
        guard code != item.sourceLanguageCode else { return }
        let itemID = item.id
        do {
            let entries = try context.fetch(FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.localSourceItemID == itemID }))
            item.sourceLanguageCode = code
            for entry in entries {
                translationCoordinator.cancel(entry.id)
                entry.sourceLanguageCode = code
                entry.translationRevision += 1
                entry.invalidateGeneratedContextAnalysis()
                if entry.translationOrigin == .apple || entry.translationOrigin == nil {
                    entry.translationText = nil
                    entry.translationOrigin = nil
                    entry.translationStatus = .pending
                    entry.translationErrorCode = nil
                }
            }
            try context.save()
            for entry in entries where !entry.hasTranslation { translationCoordinator.enqueue(entry, context: context) }
        } catch { message = error.localizedDescription }
    }
}
