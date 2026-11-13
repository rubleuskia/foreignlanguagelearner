import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class BuiltinLibraryTests: XCTestCase {
    func testOldCatalogUsesBundledAuthorMetadataAndUnknownBooksStayUsable() throws {
        let data = Data(#"{"id":"lalka","title":"Lalka","language":"pl","bytes":42,"sha256":"abc"}"#.utf8)
        let book = try JSONDecoder().decode(LibraryBook.self, from: data)
        XCTAssertEqual(book.metadata.author, "Bolesław Prus")
        XCTAssertEqual(book.metadata.chapterCount, 39)
        XCTAssertEqual(book.metadata.sourceURL?.host, "culture.pl")
        XCTAssertEqual(LibraryBookMetadata.bundled.count, 9)
        for metadata in LibraryBookMetadata.bundled.values {
            XCTAssertNotNil(metadata.authorInfo?["ru"])
            XCTAssertNotNil(metadata.authorInfo?["en"])
            XCTAssertNotNil(metadata.sourceURL)
            XCTAssertTrue(BookCoverService.bundled.contains(metadata.coverName ?? ""))
        }
        let unknown = LibraryBook(id: "new-book", title: "New", language: "en", bytes: 1, sha256: "hash")
        XCTAssertNil(unknown.metadata.author)
        let enriched = try JSONDecoder().decode(LibraryBook.self, from: Data(#"{"id":"lalka","title":"Lalka","language":"pl","bytes":42,"sha256":"abc","author":"Updated author","chapterCount":40,"contentFingerprint":"new"}"#.utf8))
        XCTAssertEqual(enriched.metadata.author, "Updated author")
        XCTAssertEqual(enriched.metadata.chapterCount, 40)
        XCTAssertEqual(enriched.metadata.contentFingerprint, "new")
    }

    @MainActor func testIdentitySurvivesStoreReloadAndDeletionAllowsAnotherImport() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "library-identity-\(UUID()).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let id = UUID()
        do {
            let container = try ModelContainer(for: LearningItem.self, configurations: ModelConfiguration(url: url))
            let item = makeBook(id: id)
            XCTAssertNil(item.builtinLibraryID)
            item.builtinLibraryID = "lalka"
            container.mainContext.insert(item)
            try container.mainContext.save()
        }
        let container = try ModelContainer(for: LearningItem.self, configurations: ModelConfiguration(url: url))
        let items = try container.mainContext.fetch(FetchDescriptor<LearningItem>())
        XCTAssertEqual(BuiltinLibraryIdentity.existing(bookID: "lalka", items: items)?.id, id)
        container.mainContext.delete(try XCTUnwrap(items.first))
        try container.mainContext.save()
        XCTAssertNil(BuiltinLibraryIdentity.existing(bookID: "lalka", items: try container.mainContext.fetch(FetchDescriptor<LearningItem>())))
    }

    @MainActor func testRenamedLegacyImportIsRecognizedWithoutChangingProgress() async throws {
        let container = try ModelContainer(for: LearningItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let old = makeBook()
        old.title = "My renamed book"; old.lastPosition = 75; old.isBookCompleted = true
        let different = makeBook(text: "Another story")
        container.mainContext.insert(old); container.mainContext.insert(different)
        try container.mainContext.save()
        let fingerprint = try BuiltinLibraryIdentity.fingerprint(text: "A\u{00a0}small\n story", trackIDs: [])
        let book = LibraryBook(id: "example", title: "Original title", language: "en", bytes: 1, sha256: "hash", contentFingerprint: fingerprint)
        XCTAssertEqual(BuiltinLibraryIdentity.existing(bookID: book.id, fingerprint: fingerprint, items: [different, old])?.id, old.id)
        try await BuiltinLibraryIdentity.reconcile(books: [book], items: [old, different], context: container.mainContext)
        XCTAssertEqual(old.builtinLibraryID, "example")
        XCTAssertNil(different.builtinLibraryID)
        XCTAssertEqual(old.lastPosition, 75)
        XCTAssertTrue(old.isBookCompleted)
        XCTAssertEqual(old.title, "My renamed book")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<LearningItem>()), 2)
        XCTAssertNotEqual(fingerprint, try BuiltinLibraryIdentity.fingerprint(text: "A small story", trackIDs: ["different-edition"]))
    }

    @MainActor func testRepeatedImportCommitReturnsOriginalAndKeepsOneRecord() throws {
        let container = try ModelContainer(for: LearningItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let original = makeBook()
        let saved = try BuiltinLibraryIdentity.commit(original, bookID: "example", context: container.mainContext)
        saved.lastPosition = 50; saved.title = "Renamed"; saved.isBookCompleted = true
        try container.mainContext.save()
        let duplicate = makeBook(text: "Updated archive text")
        let reused = try BuiltinLibraryIdentity.commit(duplicate, bookID: "example", context: container.mainContext)
        XCTAssertEqual(reused.id, original.id)
        XCTAssertEqual(reused.lastPosition, 50)
        XCTAssertEqual(reused.title, "Renamed")
        XCTAssertTrue(reused.isBookCompleted)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<LearningItem>()), 1)
        XCTAssertNil(duplicate.modelContext)

        // A pre-ID import is linked by content rather than inserting its renamed copy.
        original.builtinLibraryID = nil
        try container.mainContext.save()
        let legacyCopy = makeBook()
        XCTAssertEqual(try BuiltinLibraryIdentity.commit(legacyCopy, bookID: "example", context: container.mainContext).id, original.id)
        XCTAssertEqual(original.builtinLibraryID, "example")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<LearningItem>()), 1)
    }

    @MainActor private func makeBook(id: UUID = UUID(), text: String = "A small story") -> LearningItem {
        LearningItem(id: id, title: "Book", mediaKind: "text", mediaFilename: "", transcriptFilename: "book.txt", duration: 0,
                     segments: [.init(text: text)])
    }
}
