import Foundation
import SwiftData

struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double?
    var end: Double?
    var text: String
}

struct TranscriptDocument: Sendable {
    let segments: [TranscriptSegment]
    let text: String
    let ranges: [NSRange]

    init(segments: [TranscriptSegment]) {
        self.segments = segments
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

    init(id: UUID, title: String, mediaKind: String, mediaFilename: String,
         transcriptFilename: String, duration: Double, segments: [TranscriptSegment]) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.mediaKind = mediaKind
        self.mediaFilename = mediaFilename
        self.transcriptFilename = transcriptFilename
        self.duration = duration
        self.lastPosition = 0
        self.segments = segments
    }
}

@Model final class DictionaryEntry {
    var id: UUID
    var text: String
    var sourceItemID: UUID
    var sourceTitle: String
    var segmentIndex: Int?
    var createdAt: Date

    init(text: String, item: LearningItem, segmentIndex: Int?) {
        id = UUID()
        self.text = Self.normalized(text)
        sourceItemID = item.id
        sourceTitle = item.title
        self.segmentIndex = segmentIndex
        createdAt = .now
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
