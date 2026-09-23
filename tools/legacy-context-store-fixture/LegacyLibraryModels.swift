import Foundation
import SwiftData

// Frozen copy of the persisted schema at commit a4a8f4a. Keep this file unchanged when the
// production schema evolves: its purpose is to reproduce a genuinely old on-disk store.

struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double?
    var end: Double?
    var text: String
}

struct LearningPart: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var isCompleted: Bool
    var lastPosition: Double

    init(id: UUID = UUID(), start: Double, end: Double, isCompleted: Bool = false,
         lastPosition: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.isCompleted = isCompleted
        self.lastPosition = lastPosition ?? start
    }
}

enum TrackAlignmentStatus: String, Codable, Sendable, CaseIterable {
    case aligned
    case reviewRequired = "review-required"
    case untimed
}

struct LearningTrack: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var mediaFilename: String
    var subtitleFilename: String?
    var duration: Double
    var alignmentStatus: TrackAlignmentStatus
    var lastPosition: Double
    var isCompleted: Bool

    init(id: String, title: String, mediaFilename: String, subtitleFilename: String? = nil,
         duration: Double, alignmentStatus: TrackAlignmentStatus = .untimed,
         lastPosition: Double = 0, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.mediaFilename = mediaFilename
        self.subtitleFilename = subtitleFilename
        self.duration = duration
        self.alignmentStatus = alignmentStatus
        self.lastPosition = lastPosition
        self.isCompleted = isCompleted
    }
}

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
         transcriptFilename: String, duration: Double, segments: [TranscriptSegment],
         parts: [LearningPart] = [], sourceLanguageCode: String = "pl",
         tracks: [LearningTrack] = [], lastTrackID: String? = nil) {
        self.id = id
        self.title = title
        createdAt = .now
        self.mediaKind = mediaKind
        self.mediaFilename = mediaFilename
        self.transcriptFilename = transcriptFilename
        self.duration = duration
        lastPosition = 0
        self.segments = segments
        self.parts = parts
        self.sourceLanguageCode = sourceLanguageCode
        self.tracks = tracks
        self.lastTrackID = lastTrackID
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
}

enum TranslationStatus: String, Codable, Sendable {
    case pending, translating, needsDownload, ready, failed, unsupported
}

enum TranslationOrigin: String, Codable, Sendable {
    case apple, manual, imported
}

struct SelectionContext: Equatable, Sendable {
    var text: String
    var selection: NSRange
}

struct WordHelpItem: Codable, Equatable, Sendable {
    var sourceText: String
    var translationText: String
    var isGrammarWord: Bool
    var polishDictionaryResult: PolishDictionaryResult? = nil
}
