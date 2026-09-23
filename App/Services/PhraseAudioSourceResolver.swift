import Foundation

struct PhraseAudioSource: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let itemID: UUID
        let trackID: String?
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
                sourceTrackID: entry.sourceTrackID,
                items: items, fileExists: fileExists)
    }

    static func resolve(preview: SelectionTranslationPreview, items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        resolve(localSourceItemID: preview.sourceItemID,
                sourceItemID: preview.sourceItemID,
                audioRange: preview.audioRange,
                sourceTrackID: preview.sourceTrackID,
                items: items, fileExists: fileExists)
    }

    static func resolve(localSourceItemID: UUID?, sourceItemID: UUID,
                        audioRange: ClosedRange<Double>?, sourceTrackID: String? = nil,
                        items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        let item = localSourceItemID.flatMap { localID in items.first { $0.id == localID } }
            ?? items.first { $0.id == sourceItemID }
        guard let item else { return nil }
        let mediaFilename: String
        let duration: Double
        let sourceDescription: String
        if item.tracks.isEmpty {
            guard sourceTrackID == nil else { return nil }
            mediaFilename = item.mediaFilename
            duration = item.duration
            sourceDescription = item.title
        } else {
            guard let sourceTrackID,
                  let track = item.tracks.first(where: { $0.id == sourceTrackID }) else { return nil }
            mediaFilename = track.mediaFilename
            duration = track.duration
            sourceDescription = "\(item.title) · \(track.title)"
        }
        guard duration.isFinite, duration > 0,
              let audioRange, audioRange.lowerBound.isFinite, audioRange.upperBound.isFinite,
              audioRange.lowerBound >= 0, audioRange.upperBound > audioRange.lowerBound,
              audioRange.upperBound <= duration else { return nil }
        let url = MediaImportService.directory(for: item.id).appending(path: mediaFilename)
        guard fileExists(url.path) else { return nil }
        return PhraseAudioSource(identity: .init(itemID: item.id, trackID: sourceTrackID,
                                                  url: url, range: audioRange),
                                 itemTitle: sourceDescription)
    }

    private static func range(start: Double?, end: Double?) -> ClosedRange<Double>? {
        guard let start, let end, start.isFinite, end.isFinite,
              start >= 0, end > start else { return nil }
        return start...end
    }
}
