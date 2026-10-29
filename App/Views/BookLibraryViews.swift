import SwiftData
import SwiftUI

/// Image-led book surfaces share native blue actions and independent green reading progress.
enum BookLibraryDesign {
    static let background = Color.black
    static let surface = Color(white: 0.09)
    static let progress = Color.green

    static func time(_ value: Double) -> String {
        guard value.isFinite, value > 0, value < Double(Int.max) else { return "0:00" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor private enum BookCoverImageCache {
    static let images: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>()
        value.totalCostLimit = 32 * 1_024 * 1_024
        return value
    }()
    static func bundled(_ name: String) -> UIImage? {
        if let cached = images.object(forKey: name as NSString) { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "jpg"), let image = UIImage(contentsOfFile: path) else { return nil }
        store(image, key: name)
        return image
    }
    static func store(_ image: UIImage, key: String) {
        images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
}

struct BookCoverImage: View {
    var filename = ""
    var bundledName = "cover-books"
    var itemID: UUID? = nil
    var stagedURL: URL? = nil
    var data: Data? = nil
    @State private var image: UIImage?

    private var url: URL? {
        stagedURL ?? (itemID.flatMap { filename.isEmpty ? nil : MediaImportService.directory(for: $0).appending(path: filename) })
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image { Image(uiImage: image).resizable() }
                else if let fallback = BookCoverImageCache.bundled(bundledName) {
                    Image(uiImage: fallback).resizable()
                } else { Color(white: 0.16).overlay { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) } }
            }
            .scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .task(id: "\(url?.path ?? ""):\(data?.hashValue ?? 0)") {
            let sourceURL = url, sourceData = data
            let key = "\(sourceURL?.path ?? ""):\(sourceData?.hashValue ?? 0)"
            if let cached = BookCoverImageCache.images.object(forKey: key as NSString) { image = cached; return }
            let decoded = await Task.detached(priority: .utility) {
                if let sourceData { return try? BookCoverService.jpeg(sourceData) }
                if let sourceURL { return try? BookCoverService.load(sourceURL) }
                return nil as Data?
            }.value
            guard !Task.isCancelled else { return }
            image = decoded.flatMap(UIImage.init(data:))
            if let image { BookCoverImageCache.store(image, key: key) }
        }
        .accessibilityHidden(true)
    }
}

struct BookProgressBar: View {
    var value: Double
    var color: Color = BookLibraryDesign.progress
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.22))
                Capsule().fill(color).frame(width: proxy.size.width * (value.isFinite ? min(1, max(0, value)) : 0))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct BookResumeLabel: View {
    let item: LearningItem
    var body: some View {
        if let track = item.tracks.first(where: { $0.id == item.lastTrackID }) ?? item.tracks.first {
            Text("\(track.title) · \(BookLibraryDesign.time(track.lastPosition))")
        } else if !item.parts.isEmpty {
            Text(AppLanguage.format("Chapter %d · %@", item.partIndex(containing: item.lastPosition) + 1,
                                    BookLibraryDesign.time(item.lastPosition)))
        } else if item.hasAudio { Text(BookLibraryDesign.time(item.lastPosition)) }
        else { Text("Saved reading position") }
    }
}

struct BookLibraryShelf: View {
    let items: [LearningItem]
    let recent: LearningItem?
    let resume: (LearningItem) -> Void
    let delete: (IndexSet) -> Void
    @Query private var entries: [DictionaryEntry]

    var body: some View {
        // The search field lives below this boundary, so typing does not regroup the dictionary.
        let phraseCounts = Dictionary(grouping: entries, by: \.sourceItemID).mapValues(\.count)
        BookLibraryShelfContent(items: items, recent: recent, resume: resume, delete: delete, phraseCounts: phraseCounts)
    }
}

private struct BookLibraryShelfContent: View {
    let items: [LearningItem]
    let recent: LearningItem?
    let resume: (LearningItem) -> Void
    let delete: (IndexSet) -> Void
    let phraseCounts: [UUID: Int]
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var search = ""
    @State private var filter = 0
    @State private var sortByTitle = false
    @State private var selectedBook: LearningItem?

    private var filtered: [LearningItem] {
        let values = items.filter { item in
            guard search.isEmpty || item.title.localizedStandardContains(search) else { return false }
            let completed = item.isBookCompleted || item.readingProgress >= 1
            let started = item.hasReadingCompletion || item.lastPosition > 0 || item.readingCharacterOffset > 0
                || item.lastPlayedAt != nil || item.tracks.contains { $0.lastPosition > 0 }
            return filter == 0 || (filter == 1 ? started && !completed : completed)
        }
        return sortByTitle ? values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : values
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search library", text: $search).accessibilityIdentifier("library.search")
                }
                .padding(12).background(BookLibraryDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    ForEach(Array(["All books", "In progress", "Read"].enumerated()), id: \.offset) { index, title in
                        Button { filter = index } label: {
                            Text(AppLanguage.text(title)).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 11)
                        }
                        .foregroundStyle(.white)
                        .background(filter == index ? Color.blue : BookLibraryDesign.surface, in: RoundedRectangle(cornerRadius: 10))
                        .buttonStyle(.plain).accessibilityAddTraits(filter == index ? .isSelected : [])
                    }
                }.accessibilityIdentifier("library.filter")
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)

            if search.isEmpty, filter != 2, let recent {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        layout {
                            Button { selectedBook = recent } label: {
                                cover(recent).frame(width: 96, height: 132).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(recent.title)
                            VStack(alignment: .leading, spacing: 10) {
                                Button { selectedBook = recent } label: {
                                    Text(recent.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                                }.buttonStyle(.plain)
                                metadata(recent)
                                progress(recent)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { resume(recent) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill").accessibilityHidden(true)
                                Text("Continue").lineLimit(1).minimumScaleFactor(0.5)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 12))
                        .accessibilityIdentifier("library.continue")
                        BookResumeLabel(item: recent).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }.padding(.vertical, 8)
                } header: { Text("Continue reading").font(.title2.bold()).foregroundStyle(.white).textCase(nil) }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }

            Section {
                ForEach(filtered) { item in
                    HStack(alignment: .top, spacing: 8) {
                        NavigationLink { BookDetailView(item: item) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                cover(item).frame(width: 76, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.title).font(.headline).foregroundStyle(.white)
                                    metadata(item)
                                    progress(item)
                                    HStack(spacing: 10) {
                                        if item.hasText { BookVocabularyBadge(item: item).foregroundStyle(.blue) }
                                        Text(AppLanguage.format("Phrases: %d", phraseCounts[item.id, default: 0])).foregroundStyle(.teal)
                                    }.font(.caption2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 8)
                        }.accessibilityIdentifier("library.book.\(item.id)")
                        BookResourceMenu(item: item).buttonStyle(.borderless)
                    }
                }.onDelete { offsets in
                    let ids = Set(offsets.map { filtered[$0].id })
                    delete(IndexSet(items.indices.filter { ids.contains(items[$0].id) }))
                }
                if filtered.isEmpty { Text("No matching books").foregroundStyle(.secondary) }
            } header: {
                HStack {
                    Text("All books").font(.title2.bold()).foregroundStyle(.white)
                    Spacer()
                    Menu {
                        Button("Recent") { sortByTitle = false }
                        Button("Title") { sortByTitle = true }
                    } label: { Label(AppLanguage.text(sortByTitle ? "Title" : "Recent"), systemImage: "chevron.down").font(.caption) }
                }.textCase(nil)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(BookLibraryDesign.background)
        .navigationDestination(item: $selectedBook) { BookDetailView(item: $0) }
    }

    private func cover(_ item: LearningItem) -> some View {
        BookCoverImage(filename: item.coverFilename, bundledName: item.bundledCoverName, itemID: item.id)
    }
    private func metadata(_ item: LearningItem) -> some View {
        let parts = [SourceLanguage.name(for: item.sourceLanguageCode)]
            + (item.tracks.isEmpty ? [] : [AppLanguage.format("%d chapters", item.tracks.count)])
            + (item.hasAudio ? [BookLibraryDesign.time(item.duration)] : [])
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }
    private func progress(_ item: LearningItem) -> some View {
        HStack(spacing: 10) {
            BookProgressBar(value: item.readingProgress)
            Text(item.readingProgress, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading progress").accessibilityValue(item.readingProgress.formatted(.percent))
    }
}

struct BookStatisticBar: View {
    let title: String
    let count: Int
    let total: Int
    let color: Color
    var body: some View {
        VStack(spacing: 7) {
            HStack { Text(AppLanguage.text(title)); Spacer(); Text(count, format: .number).monospacedDigit() }
            BookProgressBar(value: total > 0 ? Double(count) / Double(total) : 0, color: color)
        }.font(.subheadline).accessibilityElement(children: .combine)
    }
}

struct BookWordStatistics: View {
    let item: LearningItem
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Query private var entries: [DictionaryEntry]
    @State private var readWords: Int?
    @State private var readError = false
    @State private var retry = 0
    private var phrases: Int { entries.filter { $0.sourceItemID == item.id }.count }
    private var phraseTotal: Int {
        entries.filter { SourceLanguage.canonical($0.sourceLanguageCode) == SourceLanguage.canonical(item.sourceLanguageCode) }.count
    }
    private var summary: BookVocabularySummary? { vocabulary.bookSummaries[item.id] }
    private var identity: String {
        "\(item.resourceRevision):\(vocabulary.revision):\(item.isBookCompleted):" + item.tracks.map { "\($0.id):\($0.isCompleted)" }.joined() + item.parts.map { "\($0.id):\($0.isCompleted)" }.joined() + ":\(retry)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary, !vocabulary.summariesUpdating {
                if let readWords {
                    HStack {
                        Text(AppLanguage.format("Read words: %d", readWords))
                        Spacer()
                        Text(AppLanguage.format("Unread words: %d", max(0, summary.total - readWords)))
                    }.font(.caption).foregroundStyle(.secondary)
                } else if readError { Button("Retry word count") { retry += 1 } }
                else { ProgressView("Counting words…") }
                BookStatisticBar(title: "New words", count: summary.new, total: summary.total, color: .blue)
                // Phrase bars show this book’s share of saved phrases in the same language.
                BookStatisticBar(title: "Saved phrases", count: phrases, total: phraseTotal, color: .teal)
                    .accessibilityHint("Share of saved phrases in this language")
                BookStatisticBar(title: "Studied words", count: summary.total - summary.new, total: summary.total, color: .white)
                Text(AppLanguage.format("%d unique words", summary.total)).font(.caption).foregroundStyle(.secondary)
            } else if vocabulary.bookErrors[item.id] != nil {
                BookVocabularyBadge(item: item)
            } else if item.hasText { ProgressView("Counting words…") }
            else {
                Text("Word statistics require book text.").font(.caption).foregroundStyle(.secondary)
                BookStatisticBar(title: "Saved phrases", count: phrases, total: phraseTotal, color: .teal)
                    .accessibilityHint("Share of saved phrases in this language")
            }
        }
        .task(id: identity) {
            readWords = nil; readError = false
            do {
                let scopes: [ReadingScope] = item.isBookCompleted ? [.book] :
                    item.tracks.filter(\.isCompleted).map { .track($0.id) } + item.parts.filter(\.isCompleted).map { .part($0.id) }
                let sources = try scopes.flatMap { try ReadingCompletionService.sources(item: item, scope: $0) }
                let result = try await vocabulary.index.analyze(sources, language: VocabularyTokenizer.groupLanguage(item.sourceLanguageCode))
                try Task.checkCancellation()
                readWords = result.words.count
            } catch is CancellationError { }
            catch { readError = true }
        }
    }
}

struct BookDetailView: View {
    let item: LearningItem
    @Environment(\.modelContext) private var context
    @State private var reading = false
    @State private var unreadFirst = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    BookCoverImage(filename: item.coverFilename, bundledName: item.bundledCoverName, itemID: item.id)
                        .frame(height: 260)
                    LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                    Text(item.title).font(.largeTitle.bold()).padding(20)
                }.frame(height: 260)
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(SourceLanguage.name(for: item.sourceLanguageCode))
                        if !item.tracks.isEmpty { Text(AppLanguage.format("%d chapters", item.tracks.count)) }
                        if item.hasAudio { Label(BookLibraryDesign.time(item.duration), systemImage: "headphones") }
                    }.font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        HStack { Text("Reading progress"); Spacer(); Text(item.readingProgress, format: .percent.precision(.fractionLength(0))) }.font(.subheadline)
                        BookProgressBar(value: item.readingProgress)
                    }
                    BookWordStatistics(item: item)
                    VStack(spacing: 10) {
                        Button { reading = true } label: { Label("Continue", systemImage: "play.fill").lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 12))
                            .accessibilityIdentifier("book.continue")
                        BookResumeLabel(item: item).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    if !item.tracks.isEmpty || !item.parts.isEmpty {
                        HStack {
                            Text("Chapters").font(.title2.bold())
                            Spacer()
                            Menu {
                                Button("Original order") { unreadFirst = false }
                                Button("Unread first") { unreadFirst = true }
                            } label: { Label(AppLanguage.text(unreadFirst ? "Unread first" : "Original order"), systemImage: "chevron.down").font(.caption) }
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(chapters) { chapter in
                                Button { open(chapter) } label: { chapterRow(chapter) }
                                    .buttonStyle(.plain).accessibilityIdentifier("book.chapter.\(chapter.id)")
                                Divider().overlay(Color(white: 0.15))
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .background(BookLibraryDesign.background)
        .preferredColorScheme(.dark).tint(.blue)
        .navigationTitle("About book").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { BookResourceMenu(item: item) } }
        .navigationDestination(isPresented: $reading) {
            if item.tracks.isEmpty { ReaderView(item: item).id(item.resourceRevision) }
            else { BookReaderView(item: item).id(item.resourceRevision) }
        }
        .alert("Book", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var chapters: [BookChapterPresentation] {
        let values = BookChapterPresentation.chapters(item)
        return unreadFirst ? values.filter { !$0.completed } + values.filter(\.completed) : values
    }

    private func chapterRow(_ chapter: BookChapterPresentation) -> some View {
        HStack(spacing: 14) {
            BookCoverImage(filename: item.coverFilename, bundledName: item.bundledCoverName, itemID: item.id)
                .frame(width: 66, height: 78).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(chapter.title).font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(AppLanguage.text(chapter.completed ? "Read" : chapter.position > 0 ? "In progress" : "Not started"))
                    Spacer()
                    Text("\(BookLibraryDesign.time(chapter.completed ? chapter.duration : chapter.position)) / \(BookLibraryDesign.time(chapter.duration))").monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
                BookProgressBar(value: chapter.progress)
            }
            Image(systemName: chapter.completed ? "checkmark" : "chevron.right")
                .foregroundStyle(chapter.completed ? .green : .secondary).font(.caption)
        }
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(chapter.current ? Color.blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func open(_ chapter: BookChapterPresentation) {
        let previousTrack = item.lastTrackID, previousPosition = item.lastPosition
        if item.tracks.contains(where: { $0.id == chapter.id }) {
            item.lastTrackID = chapter.id
            if let timeline = try? BookTimeline(tracks: item.tracks.map { ($0.id, $0.duration) }) {
                item.lastPosition = (try? timeline.globalTime(trackID: chapter.id, localTime: chapter.position)) ?? previousPosition
            }
        } else if let part = item.parts.first(where: { $0.id.uuidString == chapter.id }) {
            item.lastPosition = min(max(part.start, part.lastPosition), max(part.start, part.end - 0.001))
        }
        do { try context.save(); reading = true }
        catch { item.lastTrackID = previousTrack; item.lastPosition = previousPosition; self.error = error.localizedDescription }
    }
}

struct BookChapterPresentation: Identifiable {
    let id: String
    let title: String
    let duration: Double
    let position: Double
    let completed: Bool
    let current: Bool
    var progress: Double { completed ? 1 : duration > 0 ? min(1, max(0, position / duration)) : 0 }

    @MainActor static func chapters(_ item: LearningItem) -> [Self] {
        if !item.tracks.isEmpty {
            return item.tracks.map {
                .init(id: $0.id, title: $0.title, duration: $0.duration, position: $0.lastPosition,
                      completed: $0.isCompleted, current: $0.id == item.lastTrackID)
            }
        }
        return item.parts.enumerated().map { index, part in
            .init(id: part.id.uuidString, title: AppLanguage.format("Chapter %d", index + 1), duration: part.end - part.start,
                  position: max(0, part.lastPosition - part.start), completed: part.isCompleted,
                  current: index == item.partIndex(containing: item.lastPosition))
        }
    }
}
