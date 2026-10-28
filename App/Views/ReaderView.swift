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
    @State private var chapterPicker: ChapterPickerSnapshot?
    @State private var selectedPart = 0
    @State private var manualChapterGeneration = 0
    @State private var sourceLanguages = [SourceLanguage.polish]
    @State private var translationPreview: SelectionTranslationPreview?
    @State private var followGeneration = 0
    @State private var translationCache = SelectionTranslationCache()
    @State private var openedRevision = ""
    @State private var selecting = false

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
            if item.hasAudio && item.hasText && item.segments.first?.start == nil {
                Text("This transcript has no timestamps. You can read and save phrases; synchronized scrolling requires SRT or WebVTT.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            if item.hasText {
            VocabularyTranscriptView(document: document, language: item.sourceLanguageCode,
                               activeSegment: document.activeSegment(at: playback.position),
                               following: $following,
                               followGeneration: followGeneration,
                               onSelectionBegan: {
                playback.pause()
                following = false
                selecting = true
            }, initialReadingOffset: item.readingCharacterOffset,
                onReadingOffsetChanged: { item.readingCharacterOffset = $0 }) { action, text, selectionRange, segment, selectionContext in
                let absoluteSegment = segment.flatMap { document.sourceIndices.indices.contains($0) ? document.sourceIndices[$0] : nil }
                let audio = audioRange(for: selectionRange)
                let normalized = DictionaryEntry.normalized(text)
                guard !normalized.isEmpty else { return }
                playback.pause()
                following = false
                translationPreview = .init(
                    selectedText: normalized, sourceLanguageCode: item.sourceLanguageCode,
                    context: selectionContext, sourceItemID: item.id, sourceTitle: item.title,
                    audioRange: audio, segmentIndex: absoluteSegment,
                    saveOnOpen: action == .addToDictionary
                )
                if audio != nil {
                    translationPreview?.phraseAudioRange = PhraseAudioTiming.sentenceRange(
                        for: selectionRange, in: document, duration: item.duration)
                }
            }
            .id(manualChapterGeneration)
            } else {
                ContentUnavailableView("Listen to your book", systemImage: "headphones", description: Text("Add text from the ⋮ menu to read and save phrases."))
            }
            if !following && item.segments.contains(where: { $0.start != nil && $0.end != nil }) {
                Button("Follow audio", systemImage: "arrow.down.to.line") {
                    followGeneration += 1
                    following = true
                }
                    .nativeSecondaryAction()
                    .padding(8)
            }
        }
        .safeAreaInset(edge: .bottom) { if item.hasAudio { playerBar } }
        .safeAreaInset(edge: .top) { OnboardingTip(step: .reading, allowed: item.hasText && !selecting && translationPreview == nil) }
        .readingActivity(language: item.sourceLanguageCode, isPlaying: { playback.player.timeControlStatus == .playing })
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    ReadingActionsMenu(item: item, chapterScope: currentPart.map { .part($0.id) })
                    Menu("Language", systemImage: "character.book.closed") {
                        ForEach(displayedLanguages) { language in
                            Button {
                                changeLanguage(to: language.code)
                            } label: {
                                if item.sourceLanguageCode == language.code { Label(SourceLanguage.name(for: language.code), systemImage: "checkmark") }
                                else { Text(SourceLanguage.name(for: language.code)) }
                            }
                        }
                    }
                    .disabled(item.isSourceLanguageLocked)
                    .help(AppLanguage.text(item.isSourceLanguageLocked ? "The language is locked after marking a text read." : "Source language"))
                    BookResourceMenu(item: item, beforeUpdate: { savePosition(); playback.pause() })
                }
            }
        }
        .onAppear {
            openedRevision = item.resourceRevision
            selectedPart = item.partIndex(containing: item.lastPosition)
            openCurrentPart()
        }
        .task { sourceLanguages = await SourceLanguage.availableForRussian() }
        .sheet(item: $chapterPicker) { snapshot in
            ChapterPickerView(snapshot: snapshot) { id in
                if let index = item.parts.firstIndex(where: { $0.id.uuidString == id }) { switchToPart(index) }
            }
        }
        .sheet(item: $translationPreview) {
            SelectionTranslationView(coordinator: translationCache.coordinator(for: $0), saveOnOpen: $0.saveOnOpen)
        }
        .onChange(of: playback.position) { _, position in
            guard openedRevision == item.resourceRevision, playback.player.currentItem != nil else { return }
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
        } message: { Text(AppLanguage.text(playback.errorMessage ?? "")) }
    }

    private var playerBar: some View {
        VStack(spacing: 8) {
            if !item.parts.isEmpty {
                HStack {
                    Button(AppLanguage.format("Part %d of %d", selectedPart + 1, item.parts.count)) {
                        chapterPicker = .init(chapters: item.parts.enumerated().map { index, part in
                            .init(id: part.id.uuidString, title: "Part \(index + 1)", completed: part.isCompleted,
                                  duration: part.end - part.start)
                        }, selectedID: currentPart?.id.uuidString)
                    }
                    .accessibilityIdentifier("reader.choose-chapter")
                    Spacer()
                    PlaybackRateMenu(playback: playback)
                }
            } else {
                HStack { Text("Audio").font(.subheadline.weight(.medium)); Spacer(); PlaybackRateMenu(playback: playback) }
            }
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(max(playback.position, lowerBound), upperBound) }, set: { scrubPosition = $0 }), in: lowerBound...max(upperBound, lowerBound + 0.01)) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubPosition); followGeneration += 1; following = true }
            }.accessibilityLabel("Playback position")
            HStack {
                Text(time(playback.position - lowerBound))
                Spacer()
                Text(time(upperBound - lowerBound))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            NativeTransportControls(isPlaying: playback.isPlaying, back: {
                playback.seek(to: max(lowerBound, playback.position - 10)); followGeneration += 1; following = true
            }, toggle: {
                let wasPlaying = playback.isPlaying
                playback.toggle()
                if !wasPlaying {
                    let previous = item.lastPlayedAt
                    item.lastPlayedAt = .now
                    do { try context.save() }
                    catch { item.lastPlayedAt = previous; message = error.localizedDescription }
                }
                if playback.isPlaying {
                    followGeneration += 1
                    following = true
                }
            }, forward: {
                playback.seek(to: min(upperBound, playback.position + 10)); followGeneration += 1; following = true
            })
        }
        .font(.subheadline)
        .padding(16)
        .nativeFloatingSurface()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func audioRange(for selectionRange: NSRange) -> ClosedRange<Double>? {
        PhraseAudioTiming.range(for: selectionRange, in: document, duration: item.duration)
    }

    private func openCurrentPart() {
        guard item.hasAudio else { return }
        let range = currentPart.map { $0.start...$0.end }
        playback.open(url: MediaImportService.directory(for: item.id).appending(path: item.mediaFilename), position: currentPart?.lastPosition ?? item.lastPosition, range: range)
    }

    private func switchToPart(_ index: Int) {
        savePosition()
        playback.close()
        selectedPart = index
        item.parts[index].lastPosition = item.parts[index].start
        manualChapterGeneration += 1
        followGeneration += 1
        following = true
        openCurrentPart()
    }

    private func updatePartPosition(_ position: Double) {
        guard item.parts.indices.contains(selectedPart) else { return }
        item.parts[selectedPart].lastPosition = position
    }

    private func savePosition() {
        guard openedRevision == item.resourceRevision else { return }
        if item.hasAudio && playback.player.currentItem != nil {
            item.lastPosition = playback.position
            updatePartPosition(playback.position)
        }
        try? context.save()
    }

    private func changeLanguage(to code: String) {
        guard !item.isSourceLanguageLocked, code != item.sourceLanguageCode else { return }
        let itemID = item.id
        let oldLanguage = item.sourceLanguageCode
        var snapshots: [(DictionaryEntry, DictionaryEntryRollbackSnapshot)] = []
        do {
            if context.hasChanges { try context.save() }
            let entries = try context.fetch(FetchDescriptor<DictionaryEntry>()).filter { ($0.localSourceItemID ?? $0.sourceItemID) == itemID }
            snapshots = entries.map { ($0, DictionaryEntryRollbackSnapshot($0)) }
            item.sourceLanguageCode = code
            for entry in entries {
                translationCoordinator.cancel(entry.id)
                entry.sourceLanguageCode = code
                entry.translationRevision += 1
                entry.invalidateGeneratedContextAnalysis()
                if entry.translationOrigin == .apple || entry.translationOrigin == .openAI || entry.translationOrigin == nil {
                    entry.translationText = nil
                    entry.translationOrigin = nil
                    entry.translationStatus = .pending
                    entry.translationErrorCode = nil
                }
            }
            try context.save()
            for entry in entries where !entry.hasTranslation { translationCoordinator.enqueue(entry, context: context) }
        } catch {
            context.rollback()
            item.sourceLanguageCode = oldLanguage
            for (entry, snapshot) in snapshots { snapshot.restore(entry) }
            message = error.localizedDescription
        }
    }
}
