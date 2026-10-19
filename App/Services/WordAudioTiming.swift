import CryptoKit
import Foundation

/// Word times are local to the physical audio track; zero-duration words remain unavailable.
struct TranscriptWordTiming: Sendable {
    let range: NSRange
    let start: Double
    let end: Double
    let isSpoken: Bool
}

struct WordAudioTimingFile: Codable, Sendable {
    static let maximumBytes = 10_000_000
    static let maximumCombinedBytes = 50_000_000
    let schemaVersion: Int
    let trackID: String
    let audioSHA256: String
    let textSHA256: String
    let words: [Word]

    struct Word: Codable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    func applying(to document: TranscriptDocument, trackID: String, duration: Double) throws -> TranscriptDocument {
        let normalized = try BookTextNormalization.normalize(document.text)
        let expression = try NSRegularExpression(pattern: "\\S+")
        let tokens = expression.matches(in: document.text, range: NSRange(location: 0, length: (document.text as NSString).length))
        guard schemaVersion == 1, self.trackID == trackID,
              audioSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              textSHA256 == BookTextNormalization.sha256(normalized),
              !words.isEmpty, words.count == tokens.count,
              duration.isFinite, duration > 0 else {
            throw BookManifestError.invalid("Word timings do not match track \(trackID) and its subtitles.")
        }
        let text = document.text as NSString
        var previousEnd = 0.0
        let timings = try zip(words, tokens).map { word, token in
            guard word.text.precomposedStringWithCanonicalMapping == text.substring(with: token.range).precomposedStringWithCanonicalMapping,
                  word.start.isFinite, word.end.isFinite, word.start >= 0,
                  word.end >= word.start, word.start + 0.000_001 >= previousEnd,
                  word.end <= duration else {
                throw BookManifestError.invalid("Invalid word timing in track \(trackID).")
            }
            previousEnd = word.end
            return TranscriptWordTiming(range: token.range, start: word.start, end: word.end,
                                        isSpoken: word.text.rangeOfCharacter(from: .alphanumerics) != nil)
        }
        return TranscriptDocument(segments: document.segments, sourceIndices: document.sourceIndices, wordTimings: timings)
    }

    static func read(_ url: URL) throws -> Self {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes else {
            throw BookManifestError.invalid("Word timings must be nonempty JSON under 10 MB.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func audioHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared by reader and dictionary. The bounded cache avoids reparsing a chapter on playback ticks.
enum TrackTranscriptLoader {
    private final class Cached: NSObject {
        let document: TranscriptDocument
        init(_ document: TranscriptDocument) { self.document = document }
    }
    private final class Cache: @unchecked Sendable {
        let values = NSCache<NSString, Cached>()
        init() { values.totalCostLimit = 20_000_000; values.countLimit = 8 }
    }
    private static let cache = Cache()

    static func load(track: LearningTrack, directory: URL) throws -> TranscriptDocument {
        guard let filename = track.subtitleFilename else { throw BookManifestError.invalid("Track has no subtitles.") }
        let subtitle = directory.appending(path: filename)
        let timingURL = track.wordTimingsFilename.map { directory.appending(path: $0) }
        func signature(_ url: URL) -> String {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        let key = "\(track.id):\(track.duration):\(signature(subtitle)):\(timingURL.map(signature) ?? "")" as NSString
        if let cached = cache.values.object(forKey: key) { return cached.document }
        var document = try TranscriptParser.parse(String(contentsOf: subtitle, encoding: .utf8), extension: subtitle.pathExtension)
        if let timingURL {
            // A missing/corrupt optional sidecar leaves usable cue playback available.
            if let file = try? WordAudioTimingFile.read(timingURL),
               let aligned = try? file.applying(to: document, trackID: track.id, duration: track.duration) {
                document = aligned
            }
        }
        cache.values.setObject(Cached(document), forKey: key,
                               cost: document.text.utf8.count + document.wordTimings.count * 64)
        return document
    }
}
