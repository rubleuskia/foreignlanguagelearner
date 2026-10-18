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
        let storedRange = range(start: entry.audioStart, end: entry.audioEnd)
        let item = items.first { $0.id == (entry.localSourceItemID ?? entry.sourceItemID) }
            ?? items.first { $0.id == entry.sourceItemID }
        var audioRange = storedRange
        if let item, let storedRange, let index = entry.segmentIndex {
            let document: TranscriptDocument?
            if item.tracks.isEmpty {
                document = TranscriptDocument(segments: item.segments)
            } else if let track = item.tracks.first(where: { $0.id == entry.sourceTrackID }),
                      let filename = track.subtitleFilename {
                let url = MediaImportService.directory(for: item.id).appending(path: filename)
                document = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
                    try? TranscriptParser.parse($0, extension: url.pathExtension)
                }
            } else {
                document = nil
            }
            if let document {
                audioRange = PhraseAudioTiming.removingLegacyPadding(
                    from: storedRange, selectedText: entry.text, firstSegment: index, document: document)
            }
        }
        return resolve(localSourceItemID: entry.localSourceItemID,
                sourceItemID: entry.sourceItemID,
                audioRange: audioRange,
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

/// Uses actual subtitle boundaries; never estimates word timing from character positions.
enum PhraseAudioTiming {
    static func range(for selection: NSRange, in document: TranscriptDocument,
                      duration: Double) -> ClosedRange<Double>? {
        guard selection.location != NSNotFound, selection.length > 0,
              Range(selection, in: document.text) != nil,
              duration.isFinite, duration > 0 else { return nil }
        let indices = document.ranges.indices.filter {
            NSIntersectionRange(document.ranges[$0], selection).length > 0
        }
        guard !indices.isEmpty else { return nil }
        var starts: [Double] = []
        var ends: [Double] = []
        for index in indices {
            let segment = document.segments[index]
            guard let start = segment.start, let end = segment.end,
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  end <= duration else { return nil }
            starts.append(start)
            ends.append(end)
        }
        guard let start = starts.min(), let end = ends.max() else { return nil }
        return start...end
    }

    static func removingLegacyPadding(from stored: ClosedRange<Double>, selectedText: String,
                                      firstSegment: Int, document: TranscriptDocument) -> ClosedRange<Double> {
        guard document.ranges.indices.contains(firstSegment) else { return stored }
        let words = selectedText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return stored }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return stored }
        let firstRange = document.ranges[firstSegment]
        let searchRange = NSRange(location: firstRange.location,
                                  length: (document.text as NSString).length - firstRange.location)
        let matches = expression.matches(in: document.text, range: searchRange).filter {
            NSIntersectionRange($0.range, firstRange).length > 0
        }
        // Repeated text within the same cue is ambiguous; preserve the saved range.
        guard matches.count == 1,
              let exact = range(for: matches[0].range, in: document, duration: stored.upperBound),
              abs(exact.lowerBound - stored.lowerBound) < 0.001,
              stored.upperBound >= exact.upperBound,
              stored.upperBound - exact.upperBound <= 0.751 else { return stored }
        return exact
    }
}
