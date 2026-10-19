import Foundation
import Observation
import SwiftData

@MainActor @Observable final class ReadingVocabularyStore {
    private(set) var revision = 0
    private(set) var ready = false
    private(set) var errorMessage: String?
    private var known: [String: Set<String>] = [:]
    private var starting = false
    private(set) var bookSummaries: [UUID: BookVocabularySummary] = [:]
    private(set) var bookErrors: [UUID: String] = [:]
    private(set) var summariesUpdating = false
    @ObservationIgnored let index: VocabularyIndex
    @ObservationIgnored private var indexedKnowledgeRevision = -1
    @ObservationIgnored private var pendingKnowledge: [String: Set<String>] = [:]
    @ObservationIgnored private var indexedCatalog: [UUID: String] = [:]
    @ObservationIgnored private var needsReconcile = true
    @ObservationIgnored private var refreshGeneration = 0

    @ObservationIgnored private let commitSave: (ModelContext) throws -> Void

    init(indexURL: URL? = nil, commitSave: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.commitSave = commitSave
        index = VocabularyIndex(url: indexURL)
    }

    func forms(for language: String) -> Set<String> {
        guard let language = try? VocabularyTokenizer.language(language) else { return [] }
        return known[language] ?? []
    }

    func statistics(_ words: Set<String>, language: String) -> VocabularyStatistics {
        let knownForms = forms(for: language)
        return .init(total: words.count, new: words.reduce(into: 0) { count, word in
            if !knownForms.contains(word) { count += 1 }
        })
    }

    func reload(context: ModelContext) throws {
        known = try ReadingKnowledge.forms(context: context)
        needsReconcile = true
        summariesUpdating = true
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
            known = try await ReadingKnowledge.loadForms(context: context)
            needsReconcile = true
            revision += 1
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
                let result = try await index.analyze(sources, language: language)
                try Task.checkCancellation()
                guard item.modelContext != nil else { continue }
                let delta = result.words.subtracting(forms(for: language))
                let blobs = try await Task.detached { try ReadingKnowledge.encode(delta) }.value
                try Task.checkCancellation()
                guard item.modelContext != nil else { continue }
                try context.save()
                let previousMigrationVersion = item.readingVocabularyMigrationVersion
                do {
                    ReadingKnowledge.insert(blobs, language: language, context: context)
                    item.readingVocabularyMigrationVersion = 1
                    context.processPendingChanges()
                    try commitSave(context)
                    known[language, default: []].formUnion(result.words)
                } catch {
                    context.rollback()
                    item.readingVocabularyMigrationVersion = previousMigrationVersion
                    throw error
                }
            }
            needsReconcile = true
            revision += 1
            ready = true
        } catch is CancellationError { errorMessage = "Updating reading vocabulary was interrupted. Retry." }
        catch { errorMessage = "Could not update reading vocabulary\(migrationTitle.map { " for \($0)" } ?? ""): \(error.localizedDescription)" }
    }

    func prepare(item: LearningItem, scope: ReadingScope) async throws -> ReadingCompletionProposal {
        guard ready else { throw ReadingVocabularyError.notReady }
        let itemID = item.id
        let language = try VocabularyTokenizer.language(item.sourceLanguageCode)
        let sources = try ReadingCompletionService.sources(item: item, scope: scope)
        let result = try await index.analyze(sources, language: language)
        try Task.checkCancellation()
        guard item.modelContext != nil,
              try VocabularyTokenizer.language(item.sourceLanguageCode) == language,
              try ReadingCompletionService.sources(item: item, scope: scope) == sources else { throw ReadingVocabularyError.changed }
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
        let delta = fresh.words.subtracting(forms(for: fresh.language))
        let knowledgeRevision = revision
        let sourceSnapshot = try ReadingCompletionService.sources(item: item, scope: proposal.scope)
        let encoding = Task.detached { try ReadingKnowledge.encode(delta) }
        let blobs = try await encoding.value
        try Task.checkCancellation()
        guard knowledgeRevision == revision, item.modelContext != nil,
              try VocabularyTokenizer.language(item.sourceLanguageCode) == fresh.language,
              try ReadingCompletionService.sources(item: item, scope: proposal.scope) == sourceSnapshot else { throw ReadingVocabularyError.changed }
        if Self.completed(item, scope: proposal.scope) { return }
        // No await from this point through commit: playback and UI edits use this same context.
        try context.save()
        let previousBookCompleted = item.isBookCompleted
        let previousTracks = item.tracks
        let previousParts = item.parts
        let previousMigrationVersion = item.readingVocabularyMigrationVersion
        do {
            ReadingKnowledge.insert(blobs, language: fresh.language, context: context)
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
        known[fresh.language, default: []].formUnion(delta)
        pendingKnowledge[fresh.language, default: []].formUnion(delta)
        revision += 1
        summariesUpdating = true
        // A projection failure never turns a successfully committed reading action into a failure.
        // The library task reconciles the authoritative snapshot before publishing fresh counts.
    }

    func refreshLibrary(_ items: [LearningItem]) async {
        guard ready else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let expectedRevision = revision
        let knowledge = known
        let pending = pendingKnowledge
        summariesUpdating = true
        do {
            if indexedKnowledgeRevision != expectedRevision {
                if needsReconcile {
                    _ = try await index.reconcile(knowledge)
                } else {
                    for (language, delta) in pending {
                        if !delta.isEmpty {
                            _ = try await index.learn(delta, language: language)
                        }
                    }
                }
                let summaries = try await index.summaries()
                try Task.checkCancellation()
                guard revision == expectedRevision, generation == refreshGeneration else { return }
                bookSummaries = summaries
                indexedKnowledgeRevision = expectedRevision
                for (language, forms) in pending { pendingKnowledge[language]?.subtract(forms) }
                needsReconcile = false
            }
            let ids = Set(items.map(\.id))
            bookSummaries = bookSummaries.filter { ids.contains($0.key) }
            bookErrors = bookErrors.filter { ids.contains($0.key) }
            for item in items {
                try Task.checkCancellation()
                let id = item.id
                let language = item.sourceLanguageCode
                let catalogKey = Self.catalogKey(item)
                if indexedCatalog[id] == catalogKey, bookSummaries[id] != nil, bookErrors[id] == nil { continue }
                do {
                    let sources = try ReadingCompletionService.sources(item: item, scope: .book)
                    let summary = try await index.indexBook(id: id, language: VocabularyTokenizer.language(language), sources: sources)
                    try Task.checkCancellation()
                    guard revision == expectedRevision, generation == refreshGeneration, item.modelContext != nil, Self.catalogKey(item) == catalogKey else { return }
                    bookSummaries[id] = summary
                    indexedCatalog[id] = catalogKey
                    bookErrors[id] = nil
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard generation == refreshGeneration else { return }
                    bookErrors[id] = error.localizedDescription; bookSummaries[id] = nil
                }
            }
            guard revision == expectedRevision, generation == refreshGeneration else { return }
            try await index.retainBooks(ids)
            try Task.checkCancellation()
            if revision == expectedRevision, generation == refreshGeneration { summariesUpdating = false }
        } catch is CancellationError { }
        catch {
            guard generation == refreshGeneration else { return }
            for item in items { bookErrors[item.id] = error.localizedDescription }
        }
    }

    func rebuildLibrary(_ items: [LearningItem]) async {
        refreshGeneration += 1
        summariesUpdating = true
        do {
            try await index.reset()
            indexedKnowledgeRevision = -1
            indexedCatalog = [:]
            needsReconcile = true
            bookSummaries = [:]
            bookErrors = [:]
            await refreshLibrary(items)
        } catch { for item in items { bookErrors[item.id] = error.localizedDescription } }
    }

    static func completed(_ item: LearningItem, scope: ReadingScope) -> Bool {
        switch scope {
        case .book: item.isBookCompleted
        case .track(let id): item.tracks.first { $0.id == id }?.isCompleted == true
        case .part(let id): item.parts.first { $0.id == id }?.isCompleted == true
        }
    }

    static func catalogKey(_ item: LearningItem) -> String {
        "\(item.id):\(item.sourceLanguageCode):\(item.transcriptFilename):" + item.tracks.map { "\($0.id):\($0.subtitleFilename ?? "")" }.joined(separator: "|")
    }
}
