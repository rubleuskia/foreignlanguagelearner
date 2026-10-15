import Foundation
import OSLog

/// Only typed diagnostic metadata is accepted: never keys, prompts, selected text or responses.
actor DiagnosticLog {
    struct Entry: Codable, Sendable {
        var timestamp = Date()
        let event: String
        var error: ContextAnalysisError? = nil
        var model: OpenAITranslationModel? = nil
        var requestID: UUID? = nil
        var httpStatus: Int? = nil
        var promptVersion = OpenAIContextAnalysisProvider.promptVersion
    }

    static let shared = DiagnosticLog()
    private let fileURL: URL
    private let maximumEntries: Int
    private let logger = Logger(subsystem: "com.rubleuskia.foreignlanguagelearner", category: "Diagnostics")

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "Diagnostics/context-log.json"),
         maximumEntries: Int = 200) {
        self.fileURL = fileURL
        self.maximumEntries = max(1, maximumEntries)
    }

    func record(_ entry: Entry) {
        do {
            var entries = try readEntries()
            entries.append(entry)
            entries = Array(entries.suffix(maximumEntries))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoded(entries).write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Could not persist diagnostic log: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func export() throws -> Data { try encoded(readEntries()) }

    private func readEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
    }

    private func encoded(_ entries: [Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }
}
