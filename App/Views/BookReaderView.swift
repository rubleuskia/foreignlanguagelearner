import SwiftData
import SwiftUI

struct BookReaderView: View {
    enum ReadingMode: String, CaseIterable, Identifiable {
        case track = "Track transcript"
        case full = "Full text"
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    let item: LearningItem
    @State private var playback = BookPlaybackController()
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
        .onAppear { playback.open(item: item); loadFullText() }
        .onChange(of: playback.activeTrackID) { _, _ in
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
        .sheet(item: $selectionPreview) { SelectionTranslationView(preview: $0) }
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
            TranscriptTextView(document: document,
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
                switch action {
                case .translateInContext:
                    playback.pause()
                    following = false
                    selectionPreview = .init(
                        selectedText: text,
                        sourceLanguageCode: item.sourceLanguageCode,
                        context: selectionContext,
                        sourceItemID: item.id,
                        sourceTitle: item.title,
                        audioRange: audio,
                        sourceTrackID: audio == nil ? nil : trackID
                    )
                case .addToDictionary:
                    let entry = DictionaryEntry(text: text, item: item,
                                                segmentIndex: mode == .track ? segment : nil,
                                                context: selectionContext,
                                                audioStart: audio?.lowerBound, audioEnd: audio?.upperBound,
                                                sourceTrackID: audio == nil ? nil : trackID)
                    guard !entry.text.isEmpty else { return }
                    context.insert(entry)
                    do {
                        try context.save()
                        translationCoordinator.enqueue(entry, context: context)
                        message = "Added to Dictionary"
                    } catch {
                        context.delete(entry)
                        message = error.localizedDescription
                    }
                }
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
                Menu(activeTrack?.title ?? "Track") {
                    ForEach(item.tracks) { track in
                        Button {
                            savePosition()
                            playback.selectTrack(track.id)
                        } label: {
                            if track.id == playback.activeTrackID { Label(track.title, systemImage: "checkmark") }
                            else { Text(track.title) }
                        }
                    }
                }
                Spacer()
                PlaybackRateMenu(playback: playback.playback)
            }
            if let id = playback.activeTrackID,
               let index = item.tracks.firstIndex(where: { $0.id == id }) {
                Button(item.tracks[index].isCompleted ? "Completed" : "Mark track completed",
                       systemImage: item.tracks[index].isCompleted ? "checkmark.circle.fill" : "circle") {
                    item.tracks[index].isCompleted.toggle()
                    try? context.save()
                }
                .font(.caption)
            }
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : playback.globalPosition },
                set: { scrubPosition = $0 }
            ), in: 0...max(playback.totalDuration, 0.01)) { editing in
                scrubbing = editing
                if !editing { savePosition(); playback.seek(global: scrubPosition); following = true }
            }
            .accessibilityLabel("Book playback position")
            HStack {
                Text(time(playback.globalPosition)).monospacedDigit()
                Spacer()
                Button { playback.seek(global: max(0, playback.globalPosition - 10)); following = true } label: {
                    Image(systemName: "gobackward.10")
                }
                Button { playback.toggle(); if playback.wantsToPlay { following = true } } label: {
                    Image(systemName: playback.wantsToPlay ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                Button { playback.seek(global: min(playback.totalDuration, playback.globalPosition + 10)); following = true } label: {
                    Image(systemName: "goforward.10")
                }
                Spacer()
                Text(time(playback.totalDuration)).monospacedDigit()
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
        let indices = document.ranges.indices.filter { NSIntersectionRange(document.ranges[$0], selectionRange).length > 0 }
        let timed = indices.compactMap { index -> TranscriptSegment? in
            guard document.segments.indices.contains(index), document.segments[index].start != nil,
                  document.segments[index].end != nil else { return nil }
            return document.segments[index]
        }
        guard let first = timed.compactMap(\.start).min(), let last = timed.compactMap(\.end).max(), last > first else { return nil }
        let nextStart = document.segments.compactMap(\.start).first { $0 >= last }
        let paddedEnd = min(last + 0.75, nextStart ?? track.duration, track.duration)
        return first...max(last, paddedEnd)
    }

    private func loadTrackTranscript() {
        guard let track = activeTrack, track.alignmentStatus.hasTimedTranscript,
              trackDocuments[track.id] == nil, let filename = track.subtitleFilename else { return }
        do {
            let url = MediaImportService.directory(for: item.id).appending(path: filename)
            let text = try String(contentsOf: url, encoding: .utf8)
            trackDocuments[track.id] = try TranscriptParser.parse(text, extension: url.pathExtension)
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

    private func savePosition() {
        playback.snapshot(into: item)
        try? context.save()
    }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
