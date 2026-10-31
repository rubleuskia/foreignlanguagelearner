import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookReaderView: View {
    enum ReadingMode: String, CaseIterable, Identifiable {
        case track = "Track transcript"
        case full = "Full text"
        var id: String { rawValue }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.scenePhase) private var scenePhase
    let item: LearningItem
    @State private var playback = BookPlaybackController()
    @State private var manualChapterGeneration = 0
    @State private var completionTask: Task<Void, Never>?
    @State private var chapterPicker: ChapterPickerSnapshot?
    @State private var mode: ReadingMode = .track
    @State private var following = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var trackDocuments: [String: TranscriptDocument] = [:]
    @State private var fullDocument: TranscriptDocument?
    @State private var transcriptError: String?
    @State private var fullTextError: String?
    @State private var message: String?
    @State private var selectionPreview: SelectionTranslationPreview?
    @State private var lastSavedPosition = 0.0
    @State private var followGeneration = 0
    @State private var translationCache = SelectionTranslationCache()
    @State private var choosingWordTimings = false
    @State private var updatingWordTimings = false
    @State private var openedRevision = ""
    @State private var selecting = false
    @State private var showAudioTip = false
    private let timingUpdates = WordTimingUpdateService()

    private var activeTrack: LearningTrack? { item.tracks.first { $0.id == playback.activeTrackID } }
    private var displayedDocument: TranscriptDocument? {
        switch mode {
        case .track: playback.activeTrackID.flatMap { trackDocuments[$0] }
        case .full: fullDocument
        }
    }

    private var compactPlayer: Bool { verticalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 0) {
            if !compactPlayer && item.hasText && activeTrack?.alignmentStatus.hasTimedTranscript != true {
                Text("Read and listen independently. Add synchronization from the ⋮ menu to follow the recording.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 8)
            }
            transcriptContent
        }
        .safeAreaInset(edge: .bottom) { playerBar }
        .safeAreaInset(edge: .top) {
            OnboardingTip(step: showAudioTip ? .synchronization : .reading,
                allowed: !compactPlayer && item.hasText && !selecting && selectionPreview == nil && !updatingWordTimings)
                .id(showAudioTip)
        }
        .readingActivity(language: item.sourceLanguageCode, isPlaying: { playback.playback.player.timeControlStatus == .playing })
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    ReaderFontSizeMenu()
                    ReadingActionsMenu(item: item, chapterScope: activeTrack.map { .track($0.id) })
                    BookResourceMenu(item: item, beforeUpdate: { savePosition(); playback.pause() },
                        onUpdatePhraseAudio: { choosingWordTimings = true },
                        isUpdatingPhraseAudio: updatingWordTimings)
                }
            }
        }
        .fileImporter(isPresented: $choosingWordTimings, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): updateWordTimings(from: url)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onAppear {
            openedRevision = item.resourceRevision
            let initial = item.tracks.first(where: { $0.id == item.lastTrackID }) ?? item.tracks.first
            mode = initial?.alignmentStatus.hasTimedTranscript == true ? .track : .full
            playback.open(item: item)
            playback.didFinishTrack = { id in completeTrack(id) }
        }
        .task(id: transcriptTrack) { await loadTrackTranscript() }
        .task(id: item.transcriptFilename) { await loadFullText() }
        .onChange(of: playback.activeTrackID) { _, _ in
            scrubbing = false
            scrubPosition = playback.localPosition
            followGeneration += 1
            following = true
            mode = activeTrack?.alignmentStatus.hasTimedTranscript == true ? .track : .full
            showAudioTip = false
        }
        .onChange(of: mode) { _, _ in
            followGeneration += 1
            following = true
        }
        .onChange(of: playback.localPosition) { _, value in
            if abs(value - lastSavedPosition) >= 5 { savePosition(); lastSavedPosition = value }
        }
        .onChange(of: playback.wantsToPlay) { _, value in
            if value && mode == .track { showAudioTip = true }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition() } }
        .onDisappear { savePosition(); playback.close() }
        .sheet(item: $chapterPicker) { snapshot in
            ChapterPickerView(snapshot: snapshot) { id in
                guard item.tracks.contains(where: { $0.id == id }) else { return }
                savePosition()
                playback.selectTrack(id)
                mode = activeTrack?.alignmentStatus.hasTimedTranscript == true ? .track : .full
                manualChapterGeneration += 1
                followGeneration += 1
                following = true
            }
        }
        .sheet(item: $selectionPreview) { SelectionTranslationView(coordinator: translationCache.coordinator(for: $0), saveOnOpen: $0.saveOnOpen) }
        .alert("Book", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .alert("Playback error", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.dismissError() } })) {
            Button("Retry") { playback.retry() }
            Button("Stop", role: .cancel) { playback.pause(); playback.dismissError() }
        } message: { Text(AppLanguage.text(playback.errorMessage ?? "")) }
    }

    @ViewBuilder private var transcriptContent: some View {
        if !item.hasText {
            ContentUnavailableView("Listen to your book", systemImage: "headphones",
                description: Text("Add text from the ⋮ menu to read and save phrases."))
        } else if mode == .track, activeTrack?.alignmentStatus == .untimed {
            ContentUnavailableView("No timed transcript for this track", systemImage: "text.badge.xmark",
                                   description: Text("Open Full text to read the book without synchronized timing."))
        } else if let document = displayedDocument {
            let revision = documentRevision
            let trackID = mode == .track ? playback.activeTrackID : nil
            VocabularyTranscriptView(document: document, language: item.sourceLanguageCode,
                               activeSegment: mode == .track ? document.activeSegment(at: playback.localPosition) : nil,
                               following: $following,
                               followGeneration: followGeneration,
                               onSelectionBegan: {
                playback.pause()
                following = false
                selecting = true
            },
                onFollowAudio: { followGeneration += 1; following = true },
                initialReadingOffset: mode == .full ? item.readingCharacterOffset : nil,
                onReadingOffsetChanged: { if mode == .full { item.readingCharacterOffset = $0 } }) { action, text, selectionRange, segment, selectionContext in
                guard revision == documentRevision, trackID == (mode == .track ? playback.activeTrackID : nil) else {
                    message = "The transcript changed. Select the text again."
                    return
                }
                let audio = mode == .track ? audioRange(for: selectionRange, document: document) : nil
                playback.pause()
                following = false
                selectionPreview = .init(
                    selectedText: text, sourceLanguageCode: item.sourceLanguageCode,
                    context: selectionContext, sourceItemID: item.id, sourceTitle: item.title,
                    audioRange: audio, sourceTrackID: audio == nil ? nil : trackID,
                    segmentIndex: mode == .track ? segment : nil,
                    saveOnOpen: action == .addToDictionary
                )
                if audio != nil {
                    selectionPreview?.phraseAudioRange = PhraseAudioTiming.sentenceRange(
                        for: selectionRange, in: document, duration: activeTrack?.duration ?? 0)
                }
            }
            .id(manualChapterGeneration)
        } else if let transcriptError = mode == .full ? fullTextError : transcriptError {
            ContentUnavailableView("Transcript unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(AppLanguage.text(transcriptError)))
        } else {
            ProgressView("Loading transcript…")
        }
    }

    private var chapterButton: some View {
        Button {
            chapterPicker = .init(chapters: item.tracks.map {
                .init(id: $0.id, title: $0.title, completed: $0.isCompleted, duration: $0.duration)
            }, selectedID: playback.activeTrackID)
        } label: {
            Text(activeTrack?.title ?? AppLanguage.text("Track"))
                .lineLimit(1).frame(minHeight: 44)
        }
        .accessibilityIdentifier("reader.choose-chapter")
    }

    private var positionSlider: some View {
        Slider(value: Binding(
            get: { scrubbing ? scrubPosition : playback.localPosition },
            set: { scrubPosition = $0 }
        ), in: 0...max(activeTrack?.duration ?? 0, 0.01)) { editing in
            scrubbing = editing
            if !editing { savePosition(); playback.seekLocal(scrubPosition); followGeneration += 1; following = true }
        }
        .accessibilityLabel("Track playback position")
    }

    private var transport: some View {
        NativeTransportControls(isPlaying: playback.wantsToPlay, back: {
            playback.seekLocal(playback.localPosition - 10); followGeneration += 1; following = true
        }, toggle: {
            let wasPlaying = playback.wantsToPlay
            playback.toggle()
            if !wasPlaying {
                let previous = item.lastPlayedAt
                item.lastPlayedAt = .now
                do { try context.save() }
                catch { item.lastPlayedAt = previous; message = error.localizedDescription }
            }
            if playback.wantsToPlay { followGeneration += 1; following = true }
        }, forward: {
            playback.seekLocal(playback.localPosition + 10); followGeneration += 1; following = true
        })
    }

    private var playerBar: some View {
        Group {
            if compactPlayer {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        chapterButton
                        HStack {
                            Text(time(scrubbing ? scrubPosition : playback.localPosition))
                            positionSlider
                            Text(time(activeTrack?.duration ?? 0))
                        }
                        .font(.caption.monospacedDigit())
                    }
                    transport
                    PlaybackRateMenu(playback: playback.playback, compact: true)
                }
            } else {
                VStack(spacing: 4) {
                    HStack {
                        chapterButton
                        Spacer()
                        PlaybackRateMenu(playback: playback.playback)
                    }
                    positionSlider
                    HStack {
                        Text(time(scrubbing ? scrubPosition : playback.localPosition))
                        Spacer()
                        Text(time(activeTrack?.duration ?? 0))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    transport
                }
            }
        }
        .font(.subheadline)
        .padding(compactPlayer ? 8 : 10)
        .nativeFloatingSurface()
        .padding(.horizontal, 16)
        .padding(.bottom, compactPlayer ? 0 : 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.player")
    }

    private var documentRevision: String {
        switch mode {
        case .full: return "\(item.id.uuidString):full:\(item.transcriptFilename)"
        case .track:
            guard let track = activeTrack else { return "none" }
            return "\(item.id.uuidString):\(track.id):\(track.subtitleFilename ?? "untimed")"
        }
    }

    private func audioRange(for selectionRange: NSRange, document: TranscriptDocument) -> ClosedRange<Double>? {
        guard let track = activeTrack else { return nil }
        return PhraseAudioTiming.range(for: selectionRange, in: document, duration: track.duration)
    }

    /// Ignore playhead/completion changes when deciding whether a transcript needs loading.
    private var transcriptTrack: LearningTrack? {
        guard var track = activeTrack else { return nil }
        track.lastPosition = 0
        track.isCompleted = false
        return track
    }

    private func loadTrackTranscript() async {
        guard let track = transcriptTrack, track.alignmentStatus.hasTimedTranscript,
              trackDocuments[track.id] == nil, track.subtitleFilename != nil else { return }
        let directory = MediaImportService.directory(for: item.id)
        let worker = Task.detached(priority: .userInitiated) {
            try TrackTranscriptLoader.load(track: track, directory: directory)
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            trackDocuments[track.id] = value
            transcriptError = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            transcriptError = error.localizedDescription
        }
    }

    private func loadFullText() async {
        guard !item.transcriptFilename.isEmpty, fullDocument == nil else { return }
        let url = MediaImportService.directory(for: item.id).appending(path: item.transcriptFilename)
        let worker = Task.detached(priority: .userInitiated) {
            try TranscriptParser.parse(String(contentsOf: url, encoding: .utf8), extension: "txt")
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            fullDocument = value
            fullTextError = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            fullTextError = error.localizedDescription
        }
    }

    private func updateWordTimings(from url: URL) {
        updatingWordTimings = true
        let tracks = item.tracks
        let directory = MediaImportService.directory(for: item.id)
        Task {
            do {
                let prepared = try await timingUpdates.prepare(archiveURL: url, tracks: tracks, directory: directory)
                do {
                    let entries = try context.fetch(FetchDescriptor<DictionaryEntry>())
                    let updated = try WordTimingUpdateCommit.apply(prepared, to: item, entries: entries) { try context.save() }
                    trackDocuments.removeAll()
                    await loadTrackTranscript()
                    translationCache = SelectionTranslationCache()
                    message = "Phrase audio updated for \(prepared.filenames.count) tracks and \(updated) saved phrases. Words without usable timings still play their context."
                } catch {
                    try? FileManager.default.removeItem(at: prepared.directory)
                    throw error
                }
            } catch {
                message = error.localizedDescription
            }
            updatingWordTimings = false
        }
    }

    private func completeTrack(_ id: String) {
        savePosition()
        let previous = completionTask
        completionTask = Task {
            await previous?.value
            guard !ReadingVocabularyStore.completed(item, scope: .track(id)) else { return }
            do {
                let proposal = try await vocabulary.prepare(item: item, scope: .track(id))
                try await vocabulary.complete(proposal, context: context)
            } catch {
                message = "Could not mark chapter read: \(error.localizedDescription)"
            }
        }
    }

    private func savePosition() {
        guard openedRevision == item.resourceRevision else { return }
        playback.snapshot(into: item)
        try? context.save()
    }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
