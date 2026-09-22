import CryptoKit
import Foundation

struct BookImportLimits: Sendable, Equatable {
    let maximumArchiveBytes: UInt64
    let maximumExtractedBytes: UInt64
    let maximumAudioBytes: UInt64
    let maximumTracks: Int
    let maximumEntries: Int
    let maximumManifestBytes: Int
    let maximumTranscriptBytes: Int
    let maximumSubtitleBytes: Int
    let maximumCombinedSubtitleBytes: Int
    let reservedCapacityBytes: Int64

    static let standard = BookImportLimits(
        maximumArchiveBytes: 4 * 1_024 * 1_024 * 1_024,
        maximumExtractedBytes: 8 * 1_024 * 1_024 * 1_024,
        maximumAudioBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumTracks: 100,
        maximumEntries: 1_000,
        maximumManifestBytes: 1 * 1_024 * 1_024,
        maximumTranscriptBytes: 10_000_000,
        maximumSubtitleBytes: 10_000_000,
        maximumCombinedSubtitleBytes: 50_000_000,
        reservedCapacityBytes: 256 * 1_024 * 1_024
    )
}
struct BookManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "foreign-language-learner.book"
    static let schemaVersion = 1

    let format: String
    let schemaVersion: Int
    var title: String
    let sourceLanguage: String
    let transcript: String
    let tracks: [Track]
    let textMapping: TextMapping?

    struct Track: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let audio: String
        let alignmentStatus: TrackAlignmentStatus
        let subtitle: String?
        let textRange: TextRange?
    }
    struct TextMapping: Codable, Equatable, Sendable {
        let normalization: String
        let normalizedSHA256: String
        let wordCount: Int
    }
    struct TextRange: Codable, Equatable, Sendable {
        let startWord: Int
        let endWord: Int
    }
}

enum BookManifestError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        guard case .invalid(let message) = self else { return nil }
        return message
    }
}

enum BookTextNormalization {
    static let version = "aligner-nfc-whitespace-v1"
    private static let whitespace = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{001C}\u{001D}\u{001E}\u{001F}\u{0020}\u{0085}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")

    static func normalize(_ input: String) throws -> String {
        let withoutBOM = input.replacingOccurrences(of: "\u{FEFF}", with: "")
        let nfc = withoutBOM.precomposedStringWithCanonicalMapping
        let words = nfc.components(separatedBy: whitespace).filter { !$0.isEmpty }
        guard !words.isEmpty else { throw BookManifestError.invalid("Transcript is empty after normalization.") }
        return words.joined(separator: " ")
    }

    static func words(_ input: String) throws -> [String] { try normalize(input).split(separator: " ").map(String.init) }
    static func sha256(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum BookManifestValidator {
    private static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")
    private static let language = try! NSRegularExpression(pattern: "^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$")
    private static let topLevelKeys: Set<String> = ["format", "schemaVersion", "title", "sourceLanguage", "transcript", "tracks", "textMapping"]
    private static let trackKeys: Set<String> = ["id", "title", "audio", "alignmentStatus", "subtitle", "textRange"]
    private static let mappingKeys: Set<String> = ["normalization", "normalizedSHA256", "wordCount"]
    private static let rangeKeys: Set<String> = ["startWord", "endWord"]

    static func decode(_ data: Data, transcriptData: Data? = nil,
                       limits: BookImportLimits = .standard) throws -> BookManifest {
        guard data.count <= limits.maximumManifestBytes else { throw invalid("Manifest exceeds 1 MiB.") }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw invalid("Manifest root must be an object.") }
        try rejectUnknown(dictionary, allowed: topLevelKeys, context: "manifest")
        if let tracks = dictionary["tracks"] as? [[String: Any]] {
            for (index, track) in tracks.enumerated() { try rejectUnknown(track, allowed: trackKeys, context: "track \(index + 1)") }
        }
        if let mapping = dictionary["textMapping"] as? [String: Any] {
            try rejectUnknown(mapping, allowed: mappingKeys, context: "textMapping")
        }
        if let tracks = dictionary["tracks"] as? [[String: Any]] {
            for (index, track) in tracks.enumerated() {
                if let range = track["textRange"] as? [String: Any] {
                    try rejectUnknown(range, allowed: rangeKeys, context: "track \(index + 1) textRange")
                }
            }
        }
        let decoder = JSONDecoder()
        let manifest: BookManifest
        do { manifest = try decoder.decode(BookManifest.self, from: data) }
        catch { throw invalid("Manifest JSON does not match schema v1: \(error.localizedDescription)") }
        try validate(manifest, transcriptData: transcriptData, limits: limits)
        return manifest
    }

    static func validate(_ manifest: BookManifest, transcriptData: Data? = nil,
                         limits: BookImportLimits = .standard) throws {
        guard manifest.format == BookManifest.formatIdentifier else { throw invalid("Unknown book format.") }
        guard manifest.schemaVersion == BookManifest.schemaVersion else { throw invalid("Unsupported book schema version \(manifest.schemaVersion).") }
        let title = manifest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 500 else { throw invalid("Book title must contain 1–500 Unicode scalars.") }
        guard manifest.sourceLanguage.utf8.count <= 64,
              matches(language, manifest.sourceLanguage) else { throw invalid("sourceLanguage must be a nonempty ASCII language tag.") }
        try validatePath(manifest.transcript, extensions: ["txt"])
        guard (1...limits.maximumTracks).contains(manifest.tracks.count) else { throw invalid("A book must contain 1–100 tracks.") }
        var ids = Set<String>()
        var audioPaths = Set<String>()
        for track in manifest.tracks {
            guard matches(identifier, track.id), ids.insert(track.id).inserted else { throw invalid("Track IDs must be unique ASCII identifiers.") }
            let trackTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trackTitle.isEmpty, trackTitle.unicodeScalars.count <= 500 else { throw invalid("Track \(track.id) has an invalid title.") }
            try validatePath(track.audio, extensions: ["mp3", "m4a", "wav"])
            guard audioPaths.insert(normalizedCollisionKey(track.audio)).inserted else { throw invalid("Audio paths must be unique.") }
            switch track.alignmentStatus {
            case .untimed:
                guard track.subtitle == nil else { throw invalid("Untimed track \(track.id) must not reference subtitles.") }
            case .aligned, .reviewRequired:
                guard let subtitle = track.subtitle else { throw invalid("Timed track \(track.id) requires subtitles.") }
                try validatePath(subtitle, extensions: ["srt", "vtt"])
            }
        }
        try validateMapping(manifest, transcriptData: transcriptData)
    }

    static func validatePath(_ path: String, extensions: Set<String>? = nil) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw invalid("Unsafe archive path: \(path)") }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw invalid("Archive paths cannot contain control characters.") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid("Unsafe archive path: \(path)") }
        guard components.first?.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else { throw invalid("Windows drive paths are not allowed.") }
        if let extensions, !extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { throw invalid("Unsupported file type: \(path)") }
    }

    static func normalizedCollisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validateMapping(_ manifest: BookManifest, transcriptData: Data?) throws {
        let ranges = manifest.tracks.compactMap(\.textRange)
        guard (manifest.textMapping == nil) == ranges.isEmpty,
              ranges.isEmpty || ranges.count == manifest.tracks.count else { throw invalid("textMapping and every track textRange must appear together.") }
        guard let mapping = manifest.textMapping else { return }
        guard mapping.normalization == BookTextNormalization.version,
              mapping.normalizedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              mapping.wordCount > 0 else { throw invalid("Invalid textMapping.") }
        var expectedStart = 0
        for range in ranges {
            guard range.startWord == expectedStart, range.endWord > range.startWord,
                  range.endWord <= mapping.wordCount else { throw invalid("Track text ranges must be contiguous half-open ranges.") }
            expectedStart = range.endWord
        }
        guard expectedStart == mapping.wordCount else { throw invalid("Track text ranges must cover the full transcript.") }
        if let transcriptData {
            guard transcriptData.count <= BookImportLimits.standard.maximumTranscriptBytes,
                  let text = String(data: transcriptData, encoding: .utf8) else { throw invalid("Transcript must be nonempty UTF-8 under 10 MB.") }
            let normalized = try BookTextNormalization.normalize(text)
            guard normalized.split(separator: " ").count == mapping.wordCount,
                  BookTextNormalization.sha256(normalized) == mapping.normalizedSHA256 else { throw invalid("Transcript does not match textMapping hash and word count.") }
        }
    }

    private static func rejectUnknown(_ dictionary: [String: Any], allowed: Set<String>, context: String) throws {
        let unknown = Set(dictionary.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw invalid("Unknown \(context) field(s): \(unknown.sorted().joined(separator: ", ")).") }
    }

    private static func matches(_ expression: NSRegularExpression, _ string: String) -> Bool {
        expression.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }
    private static func invalid(_ message: String) -> BookManifestError { .invalid(message) }
}

enum BookSynchronizationState: Equatable, Sendable {
    case synced, reviewRequired, partlySynced(hasReview: Bool), untimed

    static func resolve(_ tracks: [LearningTrack]) -> Self {
        let timed = tracks.filter { $0.alignmentStatus.hasTimedTranscript }
        let hasReview = tracks.contains { $0.alignmentStatus == .reviewRequired }
        if timed.isEmpty { return .untimed }
        if timed.count != tracks.count { return .partlySynced(hasReview: hasReview) }
        return hasReview ? .reviewRequired : .synced
    }
}
