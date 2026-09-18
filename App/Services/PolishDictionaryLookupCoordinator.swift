import Foundation
import Observation
import OSLog
import SwiftData

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

final class PolishLookupDiagnosticLog: @unchecked Sendable {
    static let shared = PolishLookupDiagnosticLog()

    private let fileURL: URL
    private let maximumEntries: Int
    private let lock = NSLock()
    private let systemLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeignLanguageLearner",
                                      category: "PolishDefinition")

    init(fileURL: URL? = nil, maximumEntries: Int = 200) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.maximumEntries = max(1, maximumEntries)
    }

    func record(error: any Error, operation: String = "lookup", word: String,
                preferredLemma: String? = nil, entryID: UUID? = nil, timestamp: Date = .now) {
        let cocoaError = error as NSError
        let event = PolishLookupDiagnosticEvent(
            timestamp: timestamp,
            operation: Self.limited(operation, to: 100),
            word: Self.limited(word, to: 200),
            preferredLemma: preferredLemma.map { Self.limited($0, to: 200) },
            entryID: entryID,
            errorType: String(reflecting: type(of: error)),
            errorDomain: Self.limited(cocoaError.domain, to: 200),
            errorCode: cocoaError.code,
            message: Self.limited(cocoaError.localizedDescription, to: 2_000)
        )
        systemLogger.error("Polish definition \(event.operation, privacy: .public) failed [\(event.errorDomain, privacy: .public):\(event.errorCode)]: \(event.message, privacy: .private)")
        lock.withLock {
            var retained = readUnlocked()
            retained.append(event)
            retained = Array(retained.suffix(maximumEntries))
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(retained).write(to: fileURL, options: [.atomic])
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: fileURL.path)
            } catch {
                systemLogger.error("Could not persist Polish definition diagnostics: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func events() -> [PolishLookupDiagnosticEvent] {
        lock.withLock { readUnlocked() }
    }

    private func readUnlocked() -> [PolishLookupDiagnosticEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PolishLookupDiagnosticEvent].self, from: data)) ?? []
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(path: "polish-definition-errors.json")
    }

    private static func limited(_ value: String, to limit: Int) -> String {
        String(value.prefix(limit))
    }
}

enum PolishDictionaryLookupState: Equatable {
    case idle
    case loading
    case choosingLemma([String])
    case failed(String)
}

@MainActor @Observable
final class PolishDictionaryLookupCoordinator {
    private let provider: any PolishDictionaryProviding
    private let diagnostics: PolishLookupDiagnosticLog
    private var states: [String: PolishDictionaryLookupState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(provider: any PolishDictionaryProviding = PolishWiktionaryClient(),
         diagnostics: PolishLookupDiagnosticLog = .shared) {
        self.provider = provider
        self.diagnostics = diagnostics
    }

    func state(for word: String) -> PolishDictionaryLookupState {
        states[key(for: word)] ?? .idle
    }

    func lookup(_ word: String, lemma: String? = nil, for entry: DictionaryEntry, context: ModelContext) {
        let lookupKey = key(for: word)
        tasks[lookupKey]?.cancel()
        states[lookupKey] = .loading
        tasks[lookupKey] = Task { [provider] in
            do {
                let result = try await provider.lookup(word, preferredLemma: lemma)
                try Task.checkCancellation()
                let originalItems = entry.wordHelpItems
                var items = entry.wordHelpItems
                var changed = false
                for index in items.indices where key(for: items[index].sourceText) == lookupKey {
                    items[index].polishDictionaryResult = result
                    changed = true
                }
                guard changed else { return }
                entry.wordHelpItems = items
                do { try context.save() }
                catch {
                    entry.wordHelpItems = originalItems
                    throw error
                }
                states[lookupKey] = .idle
            } catch is CancellationError {
                states[lookupKey] = .idle
            } catch PolishWiktionaryError.ambiguousLemmas(let lemmas) {
                diagnostics.record(error: PolishWiktionaryError.ambiguousLemmas(lemmas),
                                   word: word, preferredLemma: lemma, entryID: entry.id)
                states[lookupKey] = .choosingLemma(lemmas)
            } catch {
                diagnostics.record(error: error, word: word, preferredLemma: lemma, entryID: entry.id)
                states[lookupKey] = .failed(error.localizedDescription)
            }
            tasks[lookupKey] = nil
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func key(for word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
    }
}
