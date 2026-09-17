import Foundation
import SwiftData

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

    init(id: UUID = UUID(), start: Double, end: Double, isCompleted: Bool = false, lastPosition: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.isCompleted = isCompleted
        self.lastPosition = lastPosition ?? start
    }
}

enum LearningPartPlanner {
    static func makeParts(segments: [TranscriptSegment], duration: Double, targetDuration: Double) -> [LearningPart] {
        guard duration > 0, targetDuration > 0,
              segments.contains(where: { $0.start != nil && $0.end != nil }) else { return [] }
        let cueEnds = segments.compactMap(\.end).filter { $0 > 0 && $0 < duration }.sorted()
        var parts: [LearningPart] = []
        var start = 0.0
        while duration - start > targetDuration {
            let target = start + targetDuration
            let boundary = cueEnds.min(by: { abs($0 - target) < abs($1 - target) }) ?? target
            guard boundary > start else { break }
            parts.append(LearningPart(start: start, end: boundary))
            start = boundary
        }
        if start < duration { parts.append(LearningPart(start: start, end: duration)) }
        return parts.count > 1 ? parts : []
    }
}

struct TranscriptDocument: Sendable {
    let segments: [TranscriptSegment]
    let sourceIndices: [Int]
    let text: String
    let ranges: [NSRange]

    init(segments: [TranscriptSegment], sourceIndices: [Int]? = nil) {
        self.segments = segments
        self.sourceIndices = sourceIndices ?? Array(segments.indices)
        self.text = segments.map(\.text).joined(separator: "\n\n")
        var offset = 0
        self.ranges = segments.map {
            let length = ($0.text as NSString).length
            defer { offset += length + 2 }
            return NSRange(location: offset, length: length)
        }
    }
    // Last-started segment wins for overlapping subtitles; gaps have no highlight.
    func activeSegment(at time: Double) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            guard let start = segments[middle].start else { return nil }
            if start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, let end = segments[low - 1].end, time < end else { return nil }
        return low - 1
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

    init(id: UUID, title: String, mediaKind: String, mediaFilename: String,
         transcriptFilename: String, duration: Double, segments: [TranscriptSegment], parts: [LearningPart] = [], sourceLanguageCode: String = "pl") {
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
         audioStart: Double? = nil, audioEnd: Double? = nil) {
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

enum TranslationStatus: String, Codable, Sendable { case pending, translating, needsDownload, ready, failed, unsupported }
enum TranslationOrigin: String, Codable, Sendable { case apple, manual, imported }

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

enum LearningLevel {
    static func adjusted(_ level: Int, correct: Bool) -> Int {
        correct ? min(4, max(1, level) + 1) : max(1, min(4, level) - 1)
    }

    static func title(_ level: Int) -> String {
        switch level { case 1: "New"; case 2: "Learning"; case 3: "Practising"; default: "Learnt" }
    }
}
