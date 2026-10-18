import CryptoKit
import Foundation

struct VocabularyImportPreview: Sendable {
    let words: Set<String>
    let fingerprint: String
    init(text: String) throws {
        words = try VocabularyTokenizer.forms(in: text)
        fingerprint = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func file(_ url: URL, fileExtension: String? = nil, limit: Int = 10_000_000) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= limit else { throw TranscriptParser.ParseError.invalid("Transcript must be nonempty and smaller than 10 MB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw TranscriptParser.ParseError.invalid("Choose a UTF-8 transcript under 10 MB.")
        }
        return try .init(text: TranscriptParser.parse(text, extension: fileExtension ?? url.pathExtension).text)
    }
}
