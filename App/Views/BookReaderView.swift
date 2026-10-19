import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookReaderView: View {
    enum ReadingMode: String, CaseIterable, Identifiable {
        case track = "Track transcript"
        case full = "Full text"
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let item: LearningItem
    @State private var playback = BookPlaybackController()
    @State private var chapterPicker: ChapterPickerSnapshot?
    @State private var mode: ReadingMode = .track
    @State private var following = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var trackDocuments: [String: TranscriptDocument] = [:]
    @State private var fullDocument: TranscriptDocument?
    @State private var transcriptError: String?
    @State private var message: String?
    @State private var selectionPreview: SelectionTranslationPreview?
    @State private var lastSavedPosition = 0.0
    @State private var followGeneration = 0
    @State private var translationCache = SelectionTranslationCache()
    @State private var choosingWordTimings = false
    @State private var updatingWordTimings = false
    private let timingUpdates = WordTimingUpdateService()

    private var activeTrack: LearningTrack? { item.tracks.first { $0.id == playback.activeTrackID } }
    private var displayedDocument: TranscriptDocument? {
        switch mode {
        case .track: playback.activeTrackID.flatMap { trackDocuments[$0] }
        case .full: fullDocument
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Reading mode", selection: $mode) {
                ForEach(ReadingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            transcriptContent
            if !following, mode == .track {
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
        .toolbar { ReadingCompletionButton(item: item, scope: .book) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    choosingWordTimings = true
                } label: {
                    if updatingWordTimings { ProgressView() }
                    else { Label("Update phrase audio", systemImage: "waveform.badge.plus") }
                }
                .disabled(updatingWordTimings)
                .accessibilityIdentifier("reader.update-phrase-audio")
                .fileImporter(isPresented: $choosingWordTimings, allowedContentTypes: [.zip]) { result in
                    switch result {
                    case .success(let url): updateWordTimings(from: url)
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }
        }
        .onAppear { playback.open(item: item); loadFullText() }
        .onChange(of: playback.activeTrackID) { _, _ in
            scrubbing = false
            scrubPosition = playback.localPosition
            followGeneration += 1
            following = true
            loadTrackTranscript()
        }
        .onChange(of: mode) { _, _ in
            followGeneration += 1
            following = true
        }
        .onChange(of: playback.localPosition) { _, value in
            if abs(value - lastSavedPosition) >= 5 { savePosition(); lastSavedPosition = value }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition() } }
        .onDisappear { savePosition(); playback.close() }
        .sheet(item: $chapterPicker) { snapshot in
            ChapterPickerView(snapshot: snapshot) { id in
                guard item.tracks.contains(where: { $0.id == id }) else { return }
                savePosition()
                playback.selectTrack(id)
            }
        }
        .sheet(item: $selectionPreview) { SelectionTranslationView(coordinator: translationCache.coordinator(for: $0), saveOnOpen: $0.saveOnOpen) }
        .alert("Book", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .alert("Playback error", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.dismissError() } })) {
            Button("Retry") { playback.retry() }
            Button("Stop", role: .cancel) { playback.pause(); playback.dismissError() }
        } message: { Text(playback.errorMessage ?? "") }
    }

    @ViewBuilder private var transcriptContent: some View {
        if mode == .track, activeTrack?.alignmentStatus == .untimed {
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
            }) { action, text, selectionRange, segment, selectionContext in
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
            }
        } else if let transcriptError {
            ContentUnavailableView("Transcript unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(transcriptError))
        } else {
            ProgressView("Loading transcript…")
        }
    }

    private var playerBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(activeTrack?.title ?? "Track") {
                    chapterPicker = .init(chapters: item.tracks.map {
                        .init(id: $0.id, title: $0.title, completed: $0.isCompleted)
                    }, selectedID: playback.activeTrackID)
                }
                .accessibilityIdentifier("reader.choose-chapter")
                Spacer()
                PlaybackRateMenu(playback: playback.playback)
            }
            if let id = playback.activeTrackID,
               let index = item.tracks.firstIndex(where: { $0.id == id }) {
                ReadingCompletionButton(item: item, scope: .track(item.tracks[index].id))
                .font(.caption)
            }
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : playback.localPosition },
                set: { scrubPosition = $0 }
            ), in: 0...max(activeTrack?.duration ?? 0, 0.01)) { editing in
                scrubbing = editing
                if !editing { savePosition(); playback.seekLocal(scrubPosition); followGeneration += 1; following = true }
            }
            .accessibilityLabel("Track playback position")
            HStack {
                Text(time(scrubbing ? scrubPosition : playback.localPosition)).monospacedDigit()
                Spacer()
                Button { playback.seekLocal(playback.localPosition - 10); followGeneration += 1; following = true } label: {
                    Image(systemName: "gobackward.10")
                }
                Button { playback.toggle(); if playback.wantsToPlay { followGeneration += 1; following = true } } label: {
                    Image(systemName: playback.wantsToPlay ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(playback.wantsToPlay ? "Pause" : "Play")
                Button { playback.seekLocal(playback.localPosition + 10); followGeneration += 1; following = true } label: {
                    Image(systemName: "goforward.10")
                }
                Spacer()
                Text(time(activeTrack?.duration ?? 0)).monospacedDigit()
            }
        }
        .padding()
        .background(.bar)
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

    private func loadTrackTranscript() {
        guard let track = activeTrack, track.alignmentStatus.hasTimedTranscript,
              trackDocuments[track.id] == nil, track.subtitleFilename != nil else { return }
        do {
            trackDocuments[track.id] = try TrackTranscriptLoader.load(
                track: track, directory: MediaImportService.directory(for: item.id))
            transcriptError = nil
        } catch { transcriptError = error.localizedDescription }
    }

    private func loadFullText() {
        do {
            let url = MediaImportService.directory(for: item.id).appending(path: item.transcriptFilename)
            fullDocument = try TranscriptParser.parse(String(contentsOf: url, encoding: .utf8), extension: "txt")
            transcriptError = nil
        } catch { transcriptError = error.localizedDescription }
        loadTrackTranscript()
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
                    loadTrackTranscript()
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

    private func savePosition() {
        playback.snapshot(into: item)
        try? context.save()
    }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
