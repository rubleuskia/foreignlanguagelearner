import CryptoKit
import Foundation

struct ReadingTextSource: Sendable {
    let text: String?
    let url: URL?
    let fileExtension: String

    func load() throws -> String {
        if let text { return text }
        guard let url else { throw ReadingVocabularyError.missingItem }
        return try TranscriptParser.parse(String(contentsOf: url, encoding: .utf8), extension: fileExtension).text
    }
}

enum ReadingScope: Equatable, Sendable {
    case book
    case track(String)
    case part(UUID)
}

struct ReadingCompletionProposal: Identifiable, Sendable {
    let id = UUID()
    let itemID: UUID
    let language: String
    let scope: ReadingScope
    let words: Set<String>
    let fingerprint: String
    let added: Int
    let hasText: Bool
    var isBook: Bool { scope == .book }
}

enum ReadingCompletionService {
    @MainActor static func sources(item: LearningItem, scope: ReadingScope) throws -> [ReadingTextSource] {
        let directory = MediaImportService.directory(for: item.id)
        func trackSource(_ track: LearningTrack) -> ReadingTextSource? {
            guard let filename = track.subtitleFilename else { return nil }
            return .init(text: nil, url: directory.appending(path: filename), fileExtension: URL(fileURLWithPath: filename).pathExtension)
        }
        switch scope {
        case .book:
            if item.tracks.isEmpty {
                return [.init(text: TranscriptDocument(segments: item.segments).text, url: nil, fileExtension: "txt")]
            }
            return [.init(text: nil, url: directory.appending(path: item.transcriptFilename), fileExtension: "txt")]
                + item.tracks.compactMap(trackSource)
        case .track(let id):
            guard let track = item.tracks.first(where: { $0.id == id }) else { throw ReadingVocabularyError.missingItem }
            return trackSource(track).map { [$0] } ?? []
        case .part(let id):
            guard let part = item.parts.first(where: { $0.id == id }) else { throw ReadingVocabularyError.missingItem }
            let segments = item.segments.filter { ($0.end ?? -.infinity) > part.start && ($0.start ?? .infinity) < part.end }
            return [.init(text: TranscriptDocument(segments: segments).text, url: nil, fileExtension: "txt")]
        }
    }

    static func analyze(_ sources: [ReadingTextSource]) async throws -> (words: Set<String>, fingerprint: String) {
        let job = Task.detached(priority: .userInitiated) {
            var words = Set<String>()
            var hash = SHA256()
            for source in sources {
                try Task.checkCancellation()
                let text = try source.load()
                let data = Data(text.utf8)
                // Length prefixes distinguish source arrays with the same concatenation.
                hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
                words.formUnion(try VocabularyTokenizer.forms(in: text))
            }
            return (words, SHA256DigestString(hash.finalize()))
        }
        return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
    }

    private static func SHA256DigestString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
