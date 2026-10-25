import Foundation

// Keep the historical JSON shape and file readable for dictionary backup export.
struct PolishLookupDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let operation: String
    let word: String
    let preferredLemma: String?
    let entryID: UUID?
    let errorType: String
    let errorDomain: String
    let errorCode: Int
    let message: String
}

// Read-only compatibility adapter; the retired lookup service no longer writes events.
struct PolishLookupDiagnosticLog: Sendable {
    static let shared = PolishLookupDiagnosticLog()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base.appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(path: "polish-definition-errors.json")
    }

    func events() -> [PolishLookupDiagnosticEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PolishLookupDiagnosticEvent].self, from: data)) ?? []
    }
}
