import SwiftUI
import SwiftData

struct CatalogView: View {
    static let shelves: [(String, String)] = [("ready", "Ready to download"), ("novels", "Novels"),
        ("crime", "Crime"), ("adventure", "Adventure"), ("fairy-tales", "Fairy tales"),
        ("short-stories", "Short stories"), ("poetry", "Poetry"), ("drama", "Drama"), ("essays", "Essays"), ("other", "Other works")]
    @State private var model = CatalogModel.shared
    @State private var search = ""
    @State private var genre: String?
    private var filtered: [CatalogBook] {
        model.books.filter { book in
            let matches = search.isEmpty || "\(book.title) \(book.author)".localizedStandardContains(search)
            return matches && (genre == nil || book.shelves.contains(genre!)) && (!search.isEmpty || book.parentID == nil)
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if model.loading { ProgressView("Loading catalog…") }
                if let error = model.error { Text(error).foregroundStyle(.red); Button("Retry") { Task { await model.reload() } } }
                if let error = model.legacyError { Text(error).font(.caption).foregroundStyle(.secondary) }
                if !model.pending.isEmpty {
                    NavigationLink { CatalogRequestsView() } label: { Label("Import requests", systemImage: "arrow.down.circle") }
                }
                ScrollView(.horizontal) {
                    HStack {
                        chip("All genres", id: nil)
                        ForEach(Self.shelves, id: \.0) { shelf in chip(shelf.1, id: shelf.0) }
                    }
                }.scrollIndicators(.hidden)
                if !search.isEmpty {
                    CatalogGrid(books: filtered)
                } else {
                    ForEach(Self.shelves, id: \.0) { shelf in
                        let books = filtered.filter { $0.shelves.contains(shelf.0) }
                        if !books.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                NavigationLink { CatalogGenreView(title: shelf.1, books: books) } label: {
                                    HStack { Text(AppLanguage.text(shelf.1)).font(.title2.bold()); Spacer(); Image(systemName: "chevron.right").font(.body) }
                                }.buttonStyle(.plain)
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 16) {
                                        ForEach(Array(books.prefix(20))) { book in
                                            NavigationLink(value: book) { CatalogCard(book: book).frame(width: 148) }.buttonStyle(.plain)
                                        }
                                    }
                                }.scrollIndicators(.hidden)
                            }
                        }
                    }
                }
                if !model.loading && filtered.isEmpty {
                    ContentUnavailableView("No books found", systemImage: "books.vertical",
                        description: Text("Check your operator sign-in or try another search."))
                }
            }.padding()
        }
        .background(BookLibraryDesign.background).preferredColorScheme(.dark)
        .navigationTitle("Catalog")
        .searchable(text: $search, prompt: "Search by title or author")
        .navigationDestination(for: CatalogBook.self) { CatalogDetailView(book: $0) }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }.disabled(model.loading) }
        .refreshable { await model.reload() }
        .task { if model.books.isEmpty { await model.reload() } }
    }
    private func chip(_ title: String, id: String?) -> some View {
        Button(AppLanguage.text(title)) { genre = id }
            .buttonStyle(.bordered).tint(genre == id ? .blue : .gray)
    }
}

struct CatalogCard: View {
    let book: CatalogBook
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = book.coverURL, url.scheme == "https", url.host == "wolnelektury.pl" {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                } else { BookCoverImage(bundledName: book.prepared?.metadata.coverName ?? "cover-books") }
            }.frame(height: 188).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            Text(book.title).font(.headline).lineLimit(2)
            Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if !book.duration.isEmpty { Text(book.duration).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private var placeholder: some View { Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "book.closed")) }
}

struct CatalogGrid: View {
    let books: [CatalogBook]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(books) { book in NavigationLink(value: book) { CatalogCard(book: book) }.buttonStyle(.plain) }
        }
    }
}

private struct CatalogGenreView: View {
    let title: String
    let books: [CatalogBook]
    var body: some View { ScrollView { CatalogGrid(books: books).padding() }.navigationTitle(AppLanguage.text(title)).background(BookLibraryDesign.background) }
}

struct CatalogDetailView: View {
    let book: CatalogBook
    @Environment(\.modelContext) private var context
    @Query private var items: [LearningItem]
    @State private var model = CatalogModel.shared
    @State private var detail: CatalogBook?
    @State private var starting = false
    private var existing: LearningItem? { BuiltinLibraryIdentity.existing(bookID: book.id, items: items) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CatalogCard(book: book).frame(width: 210).frame(maxWidth: .infinity)
                if let parent = book.parentTitle { Text(AppLanguage.format("Part of: %@", parent)).foregroundStyle(.secondary) }
                Text(book.genres.joined(separator: " · ")).foregroundStyle(.secondary)
                Text(AppLanguage.format("%d chapters", book.chapterCount))
                if let existing {
                    NavigationLink { BookDetailView(item: existing) } label: { Label("Open book", systemImage: "book") }
                    if let pending = model.pending[book.id], pending.job.status == "succeeded_with_review" {
                        Text("Listen to the result and review uncertain word timings.").font(.footnote)
                    }
                } else if model.downloading.contains(book.id) {
                    ProgressView("Downloading and verifying…")
                } else if let pending = model.pending[book.id] {
                    Text(pending.job.statusText)
                    ProgressView(value: Double(pending.job.progress), total: 100)
                    if let code = pending.job.error_code, !code.isEmpty { Text(CloudAlignmentService.message(for: code)).foregroundStyle(.red) }
                    if pending.job.succeeded {
                        if pending.job.status == "succeeded_with_review" { Text("Listen to the result and review uncertain word timings.").font(.footnote) }
                        Button("Download and import book") { Task { await model.download(book, context: context) } }.buttonStyle(.borderedProminent)
                    } else if pending.job.terminal { startButton }
                } else if book.prepared != nil {
                    Button("Add to library") { Task { await model.download(book, context: context) } }.buttonStyle(.borderedProminent)
                } else { startButton }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if book.prepared == nil {
                    Link("Source: Wolne Lektury", destination: book.sourceURL)
                    Link("License and attribution", destination: URL(string: "https://wolnelektury.pl/info/zasady-wykorzystania/")!)
                }
                if let excerpt = detail?.excerpt, !excerpt.isEmpty {
                    Text("Excerpt").font(.headline)
                    Text(excerpt).font(.body).foregroundStyle(.secondary)
                }
                if let chapters = detail?.chapters {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, name in Text("\(index + 1). \(name)").font(.subheadline) }
                }
                let children = model.books.filter { $0.parentID == book.id }
                if !children.isEmpty {
                    Text("Works in this collection").font(.title2.bold())
                    ForEach(children) { child in NavigationLink(value: child) { Text(child.title) } }
                }
            }.padding()
        }
        .background(BookLibraryDesign.background).navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .task { if book.prepared == nil { detail = try? await CloudAlignmentService().catalogDetail(book.id) } }
    }
    private var startButton: some View {
        Button("Add to library") { starting = true; Task { await model.start(book); starting = false } }
            .buttonStyle(.borderedProminent).disabled(starting)
    }
}

private struct CatalogRequestsView: View {
    @State private var model = CatalogModel.shared
    var body: some View {
        List(Array(model.pending.values).sorted { $0.book.title < $1.book.title }, id: \.book.id) { value in
            NavigationLink(value: value.book) {
                VStack(alignment: .leading) { Text(value.book.title); Text(value.job.statusText).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Import requests")
    }
}

struct CatalogSourceInfoView: View {
    struct Info: Decodable, Sendable {
        struct Narration: Decodable, Sendable { let artist: String; let director: String }
        let provider: String
        let url: URL
        let originalNotices: String?
        let narration: [Narration]
    }
    let item: LearningItem
    @State private var info: Info?
    var body: some View {
        if let info {
            DisclosureGroup("Source and license") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(info.provider).font(.headline)
                    if info.url.scheme == "https", info.url.host == "wolnelektury.pl" { Link("Source: Wolne Lektury", destination: info.url) }
                    Text(Set(info.narration.map(\.artist).filter { !$0.isEmpty }).sorted().joined(separator: ", "))
                    Text(Set(info.narration.map(\.director).filter { !$0.isEmpty }).sorted().joined(separator: ", "))
                    if let notices = info.originalNotices { Text(notices).font(.caption).textSelection(.enabled) }
                    Link("License and attribution", destination: URL(string: "https://wolnelektury.pl/info/zasady-wykorzystania/")!)
                }.font(.subheadline)
            }
            .task(id: item.resourceRevision) { await load() }
        } else { Color.clear.frame(height: 0).task(id: item.resourceRevision) { await load() } }
    }
    private func load() async {
        let url = MediaImportService.directory(for: item.id).appending(path: "provenance.json")
        info = await Task.detached(priority: .utility) {
            guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 2_000_000,
                  let data = try? Data(contentsOf: url) else { return nil as Info? }
            return try? JSONDecoder().decode(Info.self, from: data)
        }.value
    }
}
