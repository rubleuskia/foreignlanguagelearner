#if DEBUG
import Foundation

@MainActor enum CatalogNavigationUIFixture {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting") &&
        ProcessInfo.processInfo.arguments.contains("--catalog-navigation-fixture")
    }
    static let books = ["Antek", "Lalka"].map { title in
        CatalogBook(id: title.lowercased(), title: title, language: "pl", author: "Bolesław Prus",
            genres: ["Nowela"], shelves: ["novels"], coverURL: nil, duration: "1:02:07", chapterCount: 1,
            parentID: nil, parentTitle: nil, sourceURL: URL(string: "https://wolnelektury.pl/")!,
            sourceVersion: "fixture", excerpt: "Fixture excerpt", chapters: ["Chapter 1"])
    }
    static var snapshot: CatalogSnapshot {
        CatalogSnapshot(catalog: books, catalogDate: Date(), readyDate: Date())
    }
    static var requests: [String: CatalogModel.Pending] {
        Dictionary(uniqueKeysWithValues: books.map { book in
            (book.id, CatalogModel.Pending(book: book, job: job(book, review: true)))
        })
    }
    private static func job(_ book: CatalogBook, review: Bool) -> CloudAlignmentJob {
        .init(job_id: book.id, title: book.title, language: book.language,
              status: review ? "succeeded_with_review" : "succeeded", progress: 100, error_code: nil)
    }
    static func update(_ pending: inout [String: CatalogModel.Pending]) {
        for id in Array(pending.keys) {
            guard let value = pending[id] else { continue }
            pending[id] = .init(book: value.book, job: job(value.book, review: value.job.status == "succeeded"))
        }
    }
}
#endif
