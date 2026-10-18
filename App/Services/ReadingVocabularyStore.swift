import Foundation
import Observation
import SwiftData

@MainActor @Observable final class ReadingVocabularyStore {
    private(set) var revision = 0
    private(set) var ready = false
    private(set) var errorMessage: String?
    private var known: [String: Set<String>] = [:]
    private var starting = false
    @ObservationIgnored private let commitSave: (ModelContext) throws -> Void

    init(commitSave: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.commitSave = commitSave
    }

    func forms(for language: String) -> Set<String> {
        guard let language = try? VocabularyTokenizer.language(language) else { return [] }
        return known[language] ?? []
    }

    func statistics(_ words: Set<String>, language: String) -> VocabularyStatistics {
        .init(total: words.count, new: words.subtracting(forms(for: language)).count)
    }

    func reload(context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<ReadVocabularyWord>())
        known = Dictionary(grouping: records, by: \.languageCode).mapValues { Set($0.map(\.normalizedForm)) }
        revision += 1
    }

    /// The app's main ModelContext is the sole writer. Preparation awaits only before mutations.
    /// Flush unrelated playback changes first, then save completion + vocabulary without suspension.
    func start(context: ModelContext) async {
        guard !starting else { return }
        starting = true; ready = false; errorMessage = nil
        defer { starting = false }
        var migrationTitle: String?
        do {
            try reload(context: context)
            let items = try context.fetch(FetchDescriptor<LearningItem>())
            for item in items where item.readingVocabularyMigrationVersion < 1 {
                migrationTitle = item.title
                var sources: [ReadingTextSource] = []
                if item.isBookCompleted { sources = try ReadingCompletionService.sources(item: item, scope: .book) }
                else {
                    for track in item.tracks where track.isCompleted { sources += try ReadingCompletionService.sources(item: item, scope: .track(track.id)) }
                    for part in item.parts where part.isCompleted { sources += try ReadingCompletionService.sources(item: item, scope: .part(part.id)) }
                }
                let language = sources.isEmpty ? "" : try VocabularyTokenizer.language(item.sourceLanguageCode)
                let result = try await ReadingCompletionService.analyze(sources)
                try Task.checkCancellation()
                guard item.modelContext != nil else { continue }
                try context.save()
                let previousMigrationVersion = item.readingVocabularyMigrationVersion
                do {
                    try Self.insert(words: result.words, language: language, context: context)
                    item.readingVocabularyMigrationVersion = 1
                    context.processPendingChanges()
                    try commitSave(context)
                } catch {
                    context.rollback()
                    item.readingVocabularyMigrationVersion = previousMigrationVersion
                    throw error
                }
            }
            try reload(context: context)
            ready = true
        } catch is CancellationError { errorMessage = "Updating reading vocabulary was interrupted. Retry." }
        catch { errorMessage = "Could not update reading vocabulary\(migrationTitle.map { " for \($0)" } ?? ""): \(error.localizedDescription)" }
    }

    func prepare(item: LearningItem, scope: ReadingScope) async throws -> ReadingCompletionProposal {
        guard ready else { throw ReadingVocabularyError.notReady }
        let itemID = item.id
        let language = try VocabularyTokenizer.language(item.sourceLanguageCode)
        let sources = try ReadingCompletionService.sources(item: item, scope: scope)
        let result = try await ReadingCompletionService.analyze(sources)
        try Task.checkCancellation()
        return .init(itemID: itemID, language: language, scope: scope, words: result.words,
                     fingerprint: result.fingerprint, added: statistics(result.words, language: language).new, hasText: !sources.isEmpty)
    }

    func complete(_ proposal: ReadingCompletionProposal, context: ModelContext) async throws {
        guard ready else { throw ReadingVocabularyError.notReady }
        let id = proposal.itemID
        guard let item = try context.fetch(FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == id })).first else {
            throw ReadingVocabularyError.missingItem
        }
        if Self.completed(item, scope: proposal.scope) { return }
        let fresh = try await prepare(item: item, scope: proposal.scope)
        guard fresh.language == proposal.language, fresh.fingerprint == proposal.fingerprint,
              fresh.added == proposal.added, statistics(fresh.words, language: fresh.language).new == proposal.added, item.modelContext != nil else { throw ReadingVocabularyError.changed }
        // No await from this point through commit: playback and UI edits use this same context.
        try context.save()
        let previousBookCompleted = item.isBookCompleted
        let previousTracks = item.tracks
        let previousParts = item.parts
        let previousMigrationVersion = item.readingVocabularyMigrationVersion
        do {
            try Self.insert(words: fresh.words, language: fresh.language, context: context)
            switch fresh.scope {
            case .book:
                item.isBookCompleted = true
                for index in item.tracks.indices { item.tracks[index].isCompleted = true }
                for index in item.parts.indices { item.parts[index].isCompleted = true }
            case .track(let id):
                guard let index = item.tracks.firstIndex(where: { $0.id == id }) else { throw ReadingVocabularyError.missingItem }
                item.tracks[index].isCompleted = true
            case .part(let id):
                guard let index = item.parts.firstIndex(where: { $0.id == id }) else { throw ReadingVocabularyError.missingItem }
                item.parts[index].isCompleted = true
            }
            item.readingVocabularyMigrationVersion = 1
            context.processPendingChanges()
            try commitSave(context)
        } catch {
            context.rollback()
            // SwiftData may leave observed scalar/Codable values cached after rollback.
            item.isBookCompleted = previousBookCompleted
            item.tracks = previousTracks
            item.parts = previousParts
            item.readingVocabularyMigrationVersion = previousMigrationVersion
            throw error
        }
        try reload(context: context)
    }

    static func completed(_ item: LearningItem, scope: ReadingScope) -> Bool {
        switch scope {
        case .book: item.isBookCompleted
        case .track(let id): item.tracks.first { $0.id == id }?.isCompleted == true
        case .part(let id): item.parts.first { $0.id == id }?.isCompleted == true
        }
    }

    static func insert(words: Set<String>, language: String, context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<ReadVocabularyWord>(predicate: #Predicate { $0.languageCode == language }))
        let forms = Set(existing.map(\.normalizedForm))
        for form in words.subtracting(forms) { context.insert(ReadVocabularyWord(languageCode: language, normalizedForm: form)) }
    }
}
