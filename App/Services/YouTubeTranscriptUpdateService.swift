import Foundation
import SwiftData

@MainActor enum YouTubeTranscriptUpdateService {
    static func replace(_ payload: YouTubeImport, language: String, item: LearningItem,
                        expectedRevision: String? = nil, context: ModelContext, save: (() throws -> Void)? = nil) throws {
        let value = try payload.validated()
        guard item.modelContext != nil, item.youtubeVideoID == value.videoID else {
            throw TranscriptParser.ParseError.invalid("Open the original YouTube video to replace its subtitles.")
        }
        _ = try VocabularyTokenizer.language(language)
        guard value.language.split(separator: "-").first.map(String.init) == language else {
            throw TranscriptParser.ParseError.invalid("Choose different subtitles to change their language.")
        }
        guard expectedRevision == nil || expectedRevision == item.resourceRevision else { throw ReadingVocabularyError.changed }
        if context.hasChanges { try context.save() }
        let oldSegments = item.segments
        let oldLanguage = item.sourceLanguageCode
        let oldDuration = item.duration
        let oldPosition = item.lastPosition
        let oldOffset = item.readingCharacterOffset
        let oldCompletion = item.isBookCompleted
        let oldRevision = item.resourceRevision
        let oldURL = item.youtubeSourceURL
        let entries = try context.fetch(FetchDescriptor<DictionaryEntry>()).filter {
            ($0.localSourceItemID ?? $0.sourceItemID) == item.id
        }
        let oldIndices = entries.map { ($0, $0.segmentIndex) }
        item.segments = value.cues.map { .init(start: $0.start, end: $0.end, text: $0.text) }
        item.sourceLanguageCode = language
        item.duration = value.duration
        item.lastPosition = min(value.duration, oldPosition)
        item.readingCharacterOffset = 0
        item.isBookCompleted = false
        item.resourceRevision = UUID().uuidString
        item.youtubeSourceURL = "https://www.youtube.com/watch?v=\(value.videoID)"
        // Dictionary entries keep their original text/language, but old cue indices no longer apply.
        for entry in entries { entry.segmentIndex = nil }
        do { try (save ?? { try context.save() })() }
        catch {
            context.rollback()
            item.segments = oldSegments
            item.sourceLanguageCode = oldLanguage
            item.duration = oldDuration
            item.lastPosition = oldPosition
            item.readingCharacterOffset = oldOffset
            item.isBookCompleted = oldCompletion
            item.resourceRevision = oldRevision
            item.youtubeSourceURL = oldURL
            for (entry, index) in oldIndices { entry.segmentIndex = index }
            throw error
        }
    }
}
