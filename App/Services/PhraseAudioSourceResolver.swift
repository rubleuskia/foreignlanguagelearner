import Foundation

struct PhraseAudioSource: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let itemID: UUID
        let url: URL
        let range: ClosedRange<Double>
    }

    let identity: Identity
    let itemTitle: String
}

enum PhraseAudioSourceResolver {
    static func resolve(entry: DictionaryEntry, items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        resolve(localSourceItemID: entry.localSourceItemID,
                sourceItemID: entry.sourceItemID,
                audioRange: range(start: entry.audioStart, end: entry.audioEnd),
                items: items, fileExists: fileExists)
    }

    static func resolve(preview: SelectionTranslationPreview, items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        resolve(localSourceItemID: preview.sourceItemID,
                sourceItemID: preview.sourceItemID,
                audioRange: preview.audioRange,
                items: items, fileExists: fileExists)
    }

    static func resolve(localSourceItemID: UUID?, sourceItemID: UUID,
                        audioRange: ClosedRange<Double>?, items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        let item = localSourceItemID.flatMap { localID in items.first { $0.id == localID } }
            ?? items.first { $0.id == sourceItemID }
        guard let item, item.duration.isFinite, item.duration > 0,
              let audioRange, audioRange.lowerBound.isFinite, audioRange.upperBound.isFinite,
              audioRange.lowerBound >= 0, audioRange.upperBound > audioRange.lowerBound,
              audioRange.upperBound <= item.duration else { return nil }
        let url = MediaImportService.directory(for: item.id).appending(path: item.mediaFilename)
        guard fileExists(url.path) else { return nil }
        return PhraseAudioSource(identity: .init(itemID: item.id, url: url, range: audioRange),
                                 itemTitle: item.title)
    }

    private static func range(start: Double?, end: Double?) -> ClosedRange<Double>? {
        guard let start, let end, start.isFinite, end.isFinite,
              start >= 0, end > start else { return nil }
        return start...end
    }
}
