import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class VocabularyIndexTests: XCTestCase {
    private func source(_ text: String) -> ReadingTextSource { .init(text: text, url: nil, fileExtension: "txt") }
    private func uniqueForm(_ number: Int) -> String {
        var value = number, letters = ""
        repeat { letters.append(Character(UnicodeScalar(97 + value % 26)!)); value /= 26 } while value > 0
        return "word" + letters
    }

    func testPostingsUpdateOnlyMatchingBooksAndAreIdempotent() async throws {
        let index = VocabularyIndex()
        let a = UUID(), b = UUID(), english = UUID(), unrelated = UUID()
        _ = try await index.reconcile(["pl": ["kot"]])
        let first = try await index.indexBook(id: a, language: "pl", sources: [source("kot dom dom")])
        let second = try await index.indexBook(id: b, language: "pl", sources: [source("dom pies")])
        _ = try await index.indexBook(id: english, language: "en", sources: [source("dom")])
        _ = try await index.indexBook(id: unrelated, language: "pl", sources: [source("koń")])
        XCTAssertEqual(first, .init(total: 2, new: 1)); XCTAssertEqual(second.new, 2)
        let changed = try await index.learn(["dom"], language: "pl")
        XCTAssertEqual(Set(changed.keys), [a, b])
        XCTAssertEqual(changed[a]?.new, 0); XCTAssertEqual(changed[b]?.new, 1)
        let visits = await index.visitedPostings
        XCTAssertEqual(visits, 2)
        let repeated = try await index.learn(["dom"], language: "pl")
        XCTAssertTrue(repeated.isEmpty)
        let visitsAgain = await index.visitedPostings
        XCTAssertEqual(visitsAgain, visits)
    }

    func testPersistentSourceCacheReconcilesAfterMissedKnowledgeUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite")
        let id = UUID()
        let original = VocabularyIndex(url: url)
        _ = try await original.reconcile([:])
        _ = try await original.indexBook(id: id, language: "pl", sources: [source("kot pies")])
        let reopened = VocabularyIndex(url: url)
        // Simulates primary commit followed by termination before projection update.
        let recovered = try await reopened.reconcile(["pl": ["kot"]])
        XCTAssertEqual(recovered[id]?.new, 1)
        let warm = try await reopened.indexBook(id: id, language: "pl", sources: [source("kot pies")])
        XCTAssertEqual(warm.new, 1)
        let tokenizations = await reopened.tokenizedSources
        XCTAssertEqual(tokenizations, 0)
        try await reopened.retainBooks([])
        let removed = try await reopened.summaries()
        XCTAssertTrue(removed.isEmpty)
        let afterDeletion = try await reopened.indexBook(id: UUID(), language: "pl", sources: [source("kot")])
        XCTAssertEqual(afterDeletion.new, 0, "Removing books never removes knowledge")
    }

    func testSourceChangesAndMissingFilesNeverPublishPartialCounts() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "kot".write(to: url, atomically: true, encoding: .utf8)
        let index = VocabularyIndex(), id = UUID()
        let sources = [ReadingTextSource(text: nil, url: url, fileExtension: "txt")]
        let first = try await index.indexBook(id: id, language: "pl", sources: sources)
        XCTAssertEqual(first.total, 1)
        try "kot pies".write(to: url, atomically: true, encoding: .utf8)
        let changed = try await index.indexBook(id: id, language: "pl", sources: sources)
        XCTAssertEqual(changed.total, 2)
        try FileManager.default.removeItem(at: url)
        do { _ = try await index.indexBook(id: id, language: "pl", sources: sources); XCTFail("Missing file accepted") } catch { }
        let preserved = try await index.summaries()
        XCTAssertEqual(preserved[id]?.total, 2, "A failed replacement preserves the previous committed generation")
    }

    func testRandomizedMembershipMatchesSetReference() async throws {
        let index = VocabularyIndex()
        var books: [UUID: Set<String>] = [:]
        var known = Set<String>()
        for book in 0..<20 {
            let words = Set((0..<400).filter { ($0 + book) % 7 == 0 || $0 % 17 == 0 }.map(uniqueForm))
            let id = UUID(); books[id] = words
            _ = try await index.indexBook(id: id, language: "pl", sources: [source(words.joined(separator: " "))])
        }
        for step in 0..<12 {
            let delta = Set((0..<400).filter { ($0 + step) % 13 == 0 }.map(uniqueForm))
            known.formUnion(delta)
            _ = try await index.learn(delta, language: "pl")
            let summaries = try await index.summaries()
            for (id, words) in books {
                XCTAssertEqual(summaries[id], .init(total: words.count, new: words.subtracting(known).count))
            }
        }
    }

    func testHundredBooksCommonWordDeltaAndIndexRebuild() async throws {
        let index = VocabularyIndex()
        let common = Set((0..<1000).map(uniqueForm))
        let ids = (0..<100).map { _ in UUID() }
        for (offset, id) in ids.enumerated() {
            _ = try await index.indexBook(id: id, language: "pl", sources: [source(common.union([uniqueForm(1000 + offset)]).joined(separator: " "))])
        }
        let start = Date()
        let changed = try await index.learn(common, language: "pl")
        let visits = await index.visitedPostings
        XCTAssertEqual(visits, 100_000)
        XCTAssertEqual(changed.count, 100)
        XCTAssertTrue(changed.values.allSatisfy { $0.new == 1 && $0.total == 1001 })
        print("100-book projection: 100k affected postings in \(Date().timeIntervalSince(start))s")
        // A startup with unchanged knowledge must not walk book memberships again.
        _ = try await index.reconcile(["pl": common])
        let afterReconcile = await index.visitedPostings
        XCTAssertEqual(afterReconcile, visits)
        try await index.reset()
        _ = try await index.reconcile(["pl": common])
        let restored = try await index.indexBook(id: ids[0], language: "pl", sources: [source(common.union([uniqueForm(1000)]).joined(separator: " "))])
        XCTAssertEqual(restored, .init(total: 1001, new: 1))
    }

    func testCompactPositionsRoundTripUnicodeAndVisibleRange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "👩🏽‍🚀 KÓT kót kot kota l’amour " + String(repeating: "kot pies ", count: 50_000)
        let first = try VocabularyTextIndex.load(text: text, directory: directory)
        let warm = try VocabularyTextIndex.load(text: text, directory: directory)
        XCTAssertEqual(first.forms, warm.forms)
        XCTAssertEqual(first.positions.count, warm.positions.count)
        let range = NSRange(location: 500, length: 100)
        let expected = try VocabularyTokenizer.occurrences(in: text).filter {
            NSIntersectionRange($0.rangeUTF16, range).length > 0 && $0.normalizedForm != "kot"
        }.map(\.rangeUTF16)
        XCTAssertEqual(warm.unknownRanges(in: range, known: ["kot"]), expected)
        XCTAssertLessThan(warm.forms.count, 10)
        XCTAssertLessThan(warm.unknownRanges(in: range, known: []).count, 30)
    }

    @MainActor func testLargeDistinctCompletionUsesBoundedWritesAndRestoresFromBackup() async throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReadingVocabularyStore()
        let text = (0..<50_000).map(uniqueForm).joined(separator: " ")
        let item = LearningItem(id: UUID(), title: "Large", mediaKind: "audio", mediaFilename: "missing.wav", transcriptFilename: "text.txt", duration: 1, segments: [.init(start: nil, end: nil, text: text)])
        item.readingVocabularyMigrationVersion = 1
        container.mainContext.insert(item); try container.mainContext.save()
        await store.start(context: container.mainContext)
        await store.refreshLibrary([item])
        XCTAssertEqual(store.bookSummaries[item.id]?.new, 50_000)
        let tokenizations = await store.index.tokenizedSources
        let start = Date()
        let proposal = try await store.prepare(item: item, scope: .book)
        try await store.complete(proposal, context: container.mainContext)
        let completed = Date()
        await store.refreshLibrary([item])
        let after = await store.index.tokenizedSources
        XCTAssertEqual(after, tokenizations, "Warm preparation/completion never tokenize sources")
        XCTAssertEqual(store.bookSummaries[item.id], .init(total: 50_000, new: 0))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ReadVocabularyBatch>()), 25)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ReadVocabularyWord>()), 0)
        XCTAssertEqual(store.forms(for: "pl").count, 50_000)
        print("50k distinct forms: warm prepare+commit=\(completed.timeIntervalSince(start))s, postings=\(Date().timeIntervalSince(completed))s")
        let exported = try DictionaryTransferService.export(entries: [], includeContext: true, readingWords: ReadingKnowledge.words(context: container.mainContext))
        let document = try DictionaryTransferService.decode(exported.data)
        XCTAssertEqual(document.readingVocabulary?.words.count, 50_000)
        let restored = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let preview = DictionaryTransferService.preview(document: document, mode: .restore, existing: [], existingVocabulary: [])
        _ = try DictionaryTransferService.apply(preview, context: restored.mainContext)
        XCTAssertEqual(try restored.mainContext.fetchCount(FetchDescriptor<ReadVocabularyBatch>()), 25)
        XCTAssertEqual(try ReadingKnowledge.forms(context: restored.mainContext)["pl"], store.forms(for: "pl"))
    }

    @MainActor func testPreviousPerWordStoreUpgradesWithoutLosingKnowledge() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "knowledge.store")
        do {
            let original = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self,
                                              configurations: ModelConfiguration(url: url))
            original.mainContext.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: Date(timeIntervalSince1970: 10)))
            try original.mainContext.save()
        }
        let upgraded = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
                                         configurations: ModelConfiguration(url: url))
        let store = ReadingVocabularyStore()
        await store.start(context: upgraded.mainContext)
        XCTAssertTrue(store.ready, store.errorMessage ?? "")
        XCTAssertEqual(store.forms(for: "pl"), ["kot"])
        ReadingKnowledge.insert(try ReadingKnowledge.encode(["pies"]), language: "pl", context: upgraded.mainContext)
        try upgraded.mainContext.save()
        let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
                                         configurations: ModelConfiguration(url: url))
        XCTAssertEqual(try ReadingKnowledge.forms(context: reopened.mainContext)["pl"], ["kot", "pies"])
        XCTAssertEqual(try ReadingKnowledge.words(context: reopened.mainContext).first { $0.normalizedForm == "kot" }?.firstLearnedAt, Date(timeIntervalSince1970: 10))
    }

    @MainActor func testBatchKnowledgeEarlierRestoreDateAndFailedSave() async throws {
        let db = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        db.mainContext.insert(ReadVocabularyBatch(language: "pl", formsData: try JSONEncoder().encode(["kot"]), firstLearnedAt: Date(timeIntervalSince1970: 100)))
        try db.mainContext.save()
        let incoming = ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: Date(timeIntervalSince1970: 10))
        let file = try DictionaryTransferService.export(entries: [], includeContext: true, readingWords: [incoming])
        let document = try DictionaryTransferService.decode(file.data)
        let preview = DictionaryTransferService.preview(document: document, mode: .restore, existing: [], existingVocabulary: try ReadingKnowledge.words(context: db.mainContext))
        XCTAssertThrowsError(try DictionaryTransferService.apply(preview, context: db.mainContext, commitSave: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).first?.firstLearnedAt, Date(timeIntervalSince1970: 100))
        _ = try DictionaryTransferService.apply(preview, context: db.mainContext)
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).first?.firstLearnedAt, Date(timeIntervalSince1970: 10))
        let store = ReadingVocabularyStore(); await store.start(context: db.mainContext)
        XCTAssertEqual(store.forms(for: "pl"), ["kot"])
    }
}
