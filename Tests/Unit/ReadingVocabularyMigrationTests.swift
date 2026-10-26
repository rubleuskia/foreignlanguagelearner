import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class ReadingVocabularyMigrationTests: XCTestCase {
    @MainActor func testOriginalStoreOpensWithNewVocabularySchemaAndPreservesData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "old.store")
        let id = UUID()
        do {
            let old = try ModelContainer(for: OriginalReadingModels.LearningItem.self, OriginalReadingModels.DictionaryEntry.self,
                                         configurations: ModelConfiguration(url: url))
            let item = OriginalReadingModels.LearningItem(id: id, title: "Existing book", mediaKind: "audio",
                mediaFilename: "media.wav", transcriptFilename: "text.srt", duration: 10,
                segments: [.init(start: 0, end: 10, text: "Kot śpi")],
                parts: [.init(start: 0, end: 10, isCompleted: true, lastPosition: 3)])
            item.lastPosition = 3
            let entry = OriginalReadingModels.DictionaryEntry(text: "Kot", item: item, segmentIndex: 0)
            entry.learningLevel = 3; entry.userNote = "Preserve this note"
            old.mainContext.insert(item); old.mainContext.insert(entry); try old.mainContext.save()
        }
        do {
            let upgraded = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                              configurations: ModelConfiguration(url: url))
            let item = try XCTUnwrap(upgraded.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
            XCTAssertEqual(item.id, id); XCTAssertEqual(item.lastPosition, 3)
            XCTAssertTrue(item.parts[0].isCompleted); XCTAssertFalse(item.isBookCompleted)
            let entry = try XCTUnwrap(upgraded.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first)
            XCTAssertEqual(entry.learningLevel, 3); XCTAssertEqual(entry.userNote, "Preserve this note")
            let store = ReadingVocabularyStore()
            await store.start(context: upgraded.mainContext)
            XCTAssertTrue(store.ready, store.errorMessage ?? "")
            XCTAssertEqual(store.forms(for: "pl"), ["kot", "śpi"])
        }
        let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                          configurations: ModelConfiguration(url: url))
        XCTAssertEqual(try ReadingKnowledge.words(context: reopened.mainContext).count, 2)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<LearningItem>()).first?.readingVocabularyMigrationVersion, 1)
    }
}

// Exact pre-feature model fields, kept independent of the production models.
private enum OriginalReadingModels {
@Model final class LearningItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var mediaKind: String
    var mediaFilename: String
    var transcriptFilename: String
    var duration: Double
    var lastPosition: Double
    var segments: [TranscriptSegment]
    var parts: [LearningPart] = []
    var sourceLanguageCode: String = "pl"
    var tracks: [LearningTrack] = []
    var lastTrackID: String? = nil

    init(id: UUID, title: String, mediaKind: String, mediaFilename: String,
         transcriptFilename: String, duration: Double, segments: [TranscriptSegment], parts: [LearningPart] = [], sourceLanguageCode: String = "pl",
         tracks: [LearningTrack] = [], lastTrackID: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.mediaKind = mediaKind
        self.mediaFilename = mediaFilename
        self.transcriptFilename = transcriptFilename
        self.duration = duration
        self.lastPosition = 0
        self.segments = segments
        self.parts = parts
        self.sourceLanguageCode = sourceLanguageCode
        self.tracks = tracks
        self.lastTrackID = lastTrackID
    }

    func partIndex(containing position: Double) -> Int {
        parts.firstIndex(where: { position >= $0.start && position < $0.end }) ?? 0
    }
}

@Model final class DictionaryEntry {
    var id: UUID
    var text: String
    var sourceItemID: UUID
    var sourceTitle: String
    var segmentIndex: Int?
    var createdAt: Date
    var sourceLanguageCode: String = "pl"
    var targetLanguageCode: String = "ru"
    var translationText: String?
    var translationOriginRaw: String?
    var translationStatusRaw: String = TranslationStatus.pending.rawValue
    var translationErrorCode: String?
    var translationUpdatedAt: Date?
    var translationRevision: Int = 0
    var learningLevel: Int = 1
    var localSourceItemID: UUID?
    var audioStart: Double?
    var audioEnd: Double?
    var sourceTrackID: String? = nil
    var contextText: String?
    var contextSelectionLocation: Int?
    var contextSelectionLength: Int?
    var contextSelectedTranslationText: String?
    var contextTranslationText: String?
    var contextAnalysisUpdatedAt: Date?
    var contextAnalysisRevision: Int = 0
    var wordHelpItems: [WordHelpItem] = []
    var wordHelpUpdatedAt: Date?
    var selectedSenseText: String?
    var userNote: String?

    init(text: String, item: LearningItem, segmentIndex: Int?, context: SelectionContext? = nil,
         audioStart: Double? = nil, audioEnd: Double? = nil, sourceTrackID: String? = nil) {
        id = UUID()
        self.text = Self.normalized(text)
        sourceItemID = item.id
        sourceTitle = item.title
        self.segmentIndex = segmentIndex
        createdAt = .now
        sourceLanguageCode = item.sourceLanguageCode
        localSourceItemID = item.id
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.sourceTrackID = sourceTrackID
        contextText = context?.text
        contextSelectionLocation = context?.selection.location
        contextSelectionLength = context?.selection.length
    }

    init(id: UUID, text: String, sourceItemID: UUID, sourceTitle: String, createdAt: Date,
         sourceLanguageCode: String, targetLanguageCode: String, translationText: String?,
         translationUpdatedAt: Date?, learningLevel: Int, context: SelectionContext?) {
        self.id = id
        self.text = Self.normalized(text)
        self.sourceItemID = sourceItemID
        self.sourceTitle = sourceTitle
        self.segmentIndex = nil
        self.createdAt = createdAt
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.translationText = translationText
        self.translationOriginRaw = translationText == nil ? nil : TranslationOrigin.imported.rawValue
        self.translationStatusRaw = translationText == nil ? TranslationStatus.pending.rawValue : TranslationStatus.ready.rawValue
        self.translationUpdatedAt = translationUpdatedAt
        self.learningLevel = min(4, max(1, learningLevel))
        self.audioStart = nil
        self.audioEnd = nil
        self.sourceTrackID = nil
        self.contextText = context?.text
        self.contextSelectionLocation = context?.selection.location
        self.contextSelectionLength = context?.selection.length
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var translationStatus: TranslationStatus {
        get { TranslationStatus(rawValue: translationStatusRaw) ?? .pending }
        set { translationStatusRaw = newValue.rawValue }
    }

    var translationOrigin: TranslationOrigin? {
        get { translationOriginRaw.flatMap(TranslationOrigin.init(rawValue:)) }
        set { translationOriginRaw = newValue?.rawValue }
    }

    var hasTranslation: Bool { translationText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    var isLearningEligible: Bool { targetLanguageCode == "ru" && hasTranslation && translationStatus == .ready && learningLevel < 4 }

    func invalidateGeneratedContextAnalysis() {
        contextAnalysisRevision += 1
        contextSelectedTranslationText = nil
        contextTranslationText = nil
        contextAnalysisUpdatedAt = nil
        wordHelpItems = []
        wordHelpUpdatedAt = nil
    }
}

}
