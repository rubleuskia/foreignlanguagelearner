import Foundation

enum PhraseAudioMode: String, CaseIterable, Identifiable {
    case selection, sentence
    var id: Self { self }
    var title: String { self == .selection ? "Selected word" : "Whole phrase" }
}

struct PhraseAudioSource: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let itemID: UUID
        let trackID: String?
        let url: URL
        let range: ClosedRange<Double>
    }

    let identity: Identity
    let itemTitle: String
    var usesWordTimings = false
    var mode: PhraseAudioMode? = nil

    var playLabel: String { mode.map { "Play " + ($0 == .selection ? "selected word" : "whole phrase") } ?? (usesWordTimings ? "Play phrase" : "Play context") }
    var pauseLabel: String { mode.map { "Pause " + ($0 == .selection ? "selected word" : "whole phrase") } ?? (usesWordTimings ? "Pause phrase" : "Pause context") }
}

enum PhraseAudioSourceResolver {
    static func resolve(entry: DictionaryEntry, items: [LearningItem], mode: PhraseAudioMode = .selection, ignoreManualRange: Bool = false,
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        if mode == .sentence {
            let manual = !ignoreManualRange && (entry.manualPhraseAudioStart != nil || entry.manualPhraseAudioEnd != nil)
            var source = resolve(localSourceItemID: entry.localSourceItemID, sourceItemID: entry.sourceItemID,
                audioRange: range(start: manual ? entry.manualPhraseAudioStart : entry.phraseAudioStart,
                                  end: manual ? entry.manualPhraseAudioEnd : entry.phraseAudioEnd),
                sourceTrackID: entry.sourceTrackID, items: items, fileExists: fileExists)
            source?.mode = .sentence
            return source
        }
        if !ignoreManualRange, entry.manualAudioStart != nil || entry.manualAudioEnd != nil {
            var source = resolve(localSourceItemID: entry.localSourceItemID, sourceItemID: entry.sourceItemID,
                           audioRange: range(start: entry.manualAudioStart, end: entry.manualAudioEnd),
                           sourceTrackID: entry.sourceTrackID, items: items, fileExists: fileExists)
            if entry.phraseAudioStart != nil { source?.mode = .selection }
            return source
        }
        let storedRange = range(start: entry.audioStart, end: entry.audioEnd)
        let item = items.first { $0.id == (entry.localSourceItemID ?? entry.sourceItemID) }
            ?? items.first { $0.id == entry.sourceItemID }
        var audioRange = storedRange
        var usesWordTimings = false
        if let item, let storedRange, let index = entry.segmentIndex {
            let document: TranscriptDocument?
            if item.tracks.isEmpty {
                document = TranscriptDocument(segments: item.segments)
            } else if let track = item.tracks.first(where: { $0.id == entry.sourceTrackID }) {
                document = try? TrackTranscriptLoader.load(track: track, directory: MediaImportService.directory(for: item.id))
            } else {
                document = nil
            }
            if let document {
                if let selection = PhraseAudioTiming.savedSelection(selectedText: entry.text, firstSegment: index,
                                                                   document: document, storedRange: storedRange),
                   let aligned = PhraseAudioTiming.wordRange(for: selection, in: document, duration: item.tracks.first(where: { $0.id == entry.sourceTrackID })?.duration ?? item.duration) {
                    audioRange = aligned
                    usesWordTimings = true
                } else {
                    audioRange = PhraseAudioTiming.removingLegacyPadding(
                        from: storedRange, selectedText: entry.text, firstSegment: index, document: document)
                }
            }
        }
        var source = resolve(localSourceItemID: entry.localSourceItemID,
                sourceItemID: entry.sourceItemID,
                audioRange: audioRange,
                sourceTrackID: entry.sourceTrackID,
                items: items, fileExists: fileExists)
        source?.usesWordTimings = usesWordTimings
        if entry.phraseAudioStart != nil { source?.mode = .selection }
        return source
    }

    static func resolve(preview: SelectionTranslationPreview, items: [LearningItem],
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        var source = resolve(localSourceItemID: preview.sourceItemID,
                sourceItemID: preview.sourceItemID,
                audioRange: preview.audioRange,
                sourceTrackID: preview.sourceTrackID,
                items: items, fileExists: fileExists)
        if let item = items.first(where: { $0.id == preview.sourceItemID }),
           let track = item.tracks.first(where: { $0.id == preview.sourceTrackID }),
           let document = try? TrackTranscriptLoader.load(track: track, directory: MediaImportService.directory(for: item.id)),
           let index = preview.segmentIndex, let storedRange = preview.audioRange,
           let selection = PhraseAudioTiming.savedSelection(selectedText: preview.selectedText, firstSegment: index,
                                                            document: document, storedRange: storedRange),
           let aligned = PhraseAudioTiming.wordRange(for: selection, in: document, duration: track.duration) {
            source = resolve(localSourceItemID: item.id, sourceItemID: item.id, audioRange: aligned,
                             sourceTrackID: track.id, items: items, fileExists: fileExists)
            source?.usesWordTimings = true
        }
        return source
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

/// Prefers aligned word boundaries, falling back to subtitle cues without estimating speech speed.
enum PhraseAudioTiming {
    static func sentenceRange(for selection: NSRange, in document: TranscriptDocument,
                              duration: Double) -> ClosedRange<Double>? {
        guard selection.length > 0, Range(selection, in: document.text) != nil else { return nil }
        var sentenceSelection: NSRange?
        document.text.enumerateSubstrings(in: document.text.startIndex..<document.text.endIndex,
                                          options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let candidate = NSRange(range, in: document.text)
            if NSIntersectionRange(candidate, selection).length > 0 {
                sentenceSelection = sentenceSelection.map { NSUnionRange($0, candidate) } ?? candidate
            }
        }
        guard let sentenceSelection else { return nil }
        return range(for: sentenceSelection, in: document, duration: duration)
    }

    static func range(for selection: NSRange, in document: TranscriptDocument,
                      duration: Double) -> ClosedRange<Double>? {
        guard selection.location != NSNotFound, selection.length > 0,
              Range(selection, in: document.text) != nil,
              duration.isFinite, duration > 0 else { return nil }
        if let words = wordRange(for: selection, in: document, duration: duration) { return words }
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

    static func wordRange(for selection: NSRange, in document: TranscriptDocument,
                          duration: Double) -> ClosedRange<Double>? {
        guard selection.location != NSNotFound, selection.length > 0,
              Range(selection, in: document.text) != nil, duration.isFinite, duration > 0 else { return nil }
        let timings = document.wordTimings
        var low = 0
        var high = timings.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(timings[middle].range) <= selection.location { low = middle + 1 }
            else { high = middle }
        }
        var selected: [TranscriptWordTiming] = []
        while low < timings.count, timings[low].range.location < NSMaxRange(selection) {
            if timings[low].isSpoken { selected.append(timings[low]) }
            low += 1
        }
        guard let first = selected.first, let last = selected.last,
              selected.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration }),
              last.end > first.start else { return nil }
        return first.start...last.end
    }

    /// Old dictionary ranges describe cues. Resolve only an unambiguous occurrence in the saved cue.
    static func savedSelection(selectedText: String, firstSegment: Int, document: TranscriptDocument,
                               storedRange: ClosedRange<Double>) -> NSRange? {
        guard document.ranges.indices.contains(firstSegment) else { return nil }
        let words = selectedText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        guard let expression = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + pattern + "(?![\\p{L}\\p{N}])") else { return nil }
        let firstRange = document.ranges[firstSegment]
        let search = NSRange(location: firstRange.location, length: (document.text as NSString).length - firstRange.location)
        let matches = expression.matches(in: document.text, range: search).filter { NSIntersectionRange($0.range, firstRange).length > 0 }
        if matches.count == 1 { return matches[0].range }
        let matchingStored = matches.filter {
            guard let range = wordRange(for: $0.range, in: document, duration: storedRange.upperBound) else { return false }
            return abs(range.lowerBound - storedRange.lowerBound) < 0.001 && abs(range.upperBound - storedRange.upperBound) < 0.001
        }
        return matchingStored.count == 1 ? matchingStored[0].range : nil
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
              let exact = range(for: matches[0].range, in: TranscriptDocument(segments: document.segments), duration: stored.upperBound),
              abs(exact.lowerBound - stored.lowerBound) < 0.001,
              stored.upperBound >= exact.upperBound,
              stored.upperBound - exact.upperBound <= 0.751 else { return stored }
        return exact
    }
}
