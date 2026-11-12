import SwiftUI
import SwiftData

struct YouTubeReaderView: View {
    let item: LearningItem
    let videoID: String
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @State private var playback = YouTubePlayback()
    @State private var following = true
    @State private var followGeneration = 0
    @State private var preview: SelectionTranslationPreview?
    @State private var cache = SelectionTranslationCache()

    var body: some View {
        let document = TranscriptDocument(segments: item.segments)
        VStack(spacing: 0) {
            YouTubePlayerView(videoID: videoID, start: item.lastPosition, playback: playback)
                .frame(height: 220)
                .accessibilityIdentifier("youtube.player")
            if let error = playback.error { Text(AppLanguage.text(error)).font(.caption).foregroundStyle(.red).padding() }
            VocabularyTranscriptView(document: document, language: item.sourceLanguageCode,
                activeSegment: document.activeSegment(at: playback.position), following: $following,
                followGeneration: followGeneration,
                onSelectionBegan: { playback.pause(); following = false },
                onFollowAudio: { following = true; followGeneration += 1 },
                initialReadingOffset: item.readingCharacterOffset,
                onReadingOffsetChanged: { item.readingCharacterOffset = $0 }) { action, text, _, segment, selectionContext in
                    playback.pause(); following = false
                    preview = .init(selectedText: DictionaryEntry.normalized(text), sourceLanguageCode: item.sourceLanguageCode,
                        context: selectionContext, sourceItemID: item.id, sourceTitle: item.title,
                        audioRange: nil, segmentIndex: segment, saveOnOpen: action == .addToDictionary)
                }
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { ReaderFontSizeMenu(); ReadingActionsMenu(item: item, chapterScope: nil) }
        .readingActivity(language: item.sourceLanguageCode, isPlaying: { playback.isPlaying })
        .sheet(item: $preview) { SelectionTranslationView(coordinator: cache.coordinator(for: $0), saveOnOpen: $0.saveOnOpen) }
        .onChange(of: playback.isPlaying) { _, playing in
            if playing { item.lastPlayedAt = .now; try? context.save() }
        }
        .onChange(of: playback.position) { _, position in
            if abs(item.lastPosition - position) >= 5 { item.lastPosition = min(item.duration, position) }
        }
        .onChange(of: phase) { _, phase in if phase != .active { save(); playback.pause() } }
        .onDisappear { save(); playback.pause() }
    }

    private func save() {
        item.lastPosition = min(item.duration, playback.position)
        try? context.save()
    }
}
