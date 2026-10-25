import SwiftUI
import SwiftData
import Translation

struct ContentView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query(sort: \LearningItem.createdAt, order: .reverse) private var items: [LearningItem]
    @State private var featuredReader: LearningItem?
    @State private var showingImport = false
    @State private var showingBookImport = false
    @State private var errorMessage: String?

    var body: some View {
        TabView {
            library
                .tabItem { Label("Library", systemImage: "books.vertical") }
            NavigationStack { DictionaryView() }
                .tabItem { Label("Dictionary", systemImage: "book.closed") }
            NavigationStack { PracticeHomeView() }
                .tabItem { Label("Practice", systemImage: "rectangle.on.rectangle") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.blue)
        .task {
            do {
                let entries = try context.fetch(FetchDescriptor<DictionaryEntry>())
                try LearningCooldown.backfill(entries, save: { try context.save() })
            } catch { errorMessage = error.localizedDescription }
            seedLearningUXFixtureIfNeeded()
            #if DEBUG
            do { try ReadingVocabularyUIFixture.seed(context: context) }
            catch { errorMessage = error.localizedDescription }
            #endif
            await translationCoordinator.recover(context: context)
            do {
                try LibraryRecoveryService.recover(context: context)
                await vocabulary.start(context: context)
            }
            catch { errorMessage = error.localizedDescription }
        }
        .task(id: vocabularyIndexIdentity) {
            await vocabulary.refreshLibrary(items)
        }
        .translationTask(translationCoordinator.configuration,
                         action: translationCoordinator.perform(session:))
        .alert("Could not delete item", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var library: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Your library is empty", systemImage: "books.vertical")
                    } description: {
                        Text("Add audio and a transcript, or bring an entire audiobook.")
                    } actions: {
                        Button("Add audio or video", systemImage: "plus") { showingImport = true }
                            .nativePrimaryAction()
                            .accessibilityIdentifier("library.upload")
                        Button("Import audiobook", systemImage: "book.closed") { showingBookImport = true }
                            .nativeSecondaryAction()
                    }
                } else {
                    List {
                        if let recent = items.first(where: { !$0.isBookCompleted && ($0.lastPosition > 0 || $0.lastTrackID != nil) }) {
                            Section("Continue reading") {
                                VStack(alignment: .leading, spacing: 16) {
                                    NavigationLink { reader(for: recent) } label: {
                                        HStack(spacing: 16) {
                                            NativeBookCover(item: recent, large: true)
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(recent.title).font(.title2.weight(.semibold))
                                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                                BookVocabularyBadge(item: recent)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    ProgressView(value: recent.readingProgress)
                                        .accessibilityLabel("Reading progress")
                                    Text("Read: \(recent.readingProgress.formatted(.percent.precision(.fractionLength(0))))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button { featuredReader = recent } label: {
                                        Label("Continue reading", systemImage: "play.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .nativePrimaryAction()
                                    .accessibilityIdentifier("library.continue")
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        Section("All materials") {
                            ForEach(items) { item in
                                NavigationLink { reader(for: item) } label: {
                                    HStack(spacing: 14) {
                                        NativeBookCover(item: item)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.title).font(.headline).foregroundStyle(.primary)
                                            BookVocabularyBadge(item: item)
                                            Text("Read: \(item.readingProgress.formatted(.percent.precision(.fractionLength(0))))")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(summary(for: item)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                            .onDelete(perform: deleteItems)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(NativeDesign.page)
            .safeAreaInset(edge: .top) { ReadingVocabularyStatus() }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        ContextualTranslationSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("library.settings")

                    Menu("Add material", systemImage: "plus") {
                        Button("Single audio or video") { showingImport = true }
                        Button("Audiobook ZIP") { showingBookImport = true }
                            .accessibilityIdentifier("library.upload-book")
                    }
                    .accessibilityIdentifier("library.add-menu")
                }
            }
            .navigationDestination(item: $featuredReader) { reader(for: $0) }
            .sheet(isPresented: $showingImport) { ImportItemView() }
            .sheet(isPresented: $showingBookImport) { BookImportView() }
        }
    }

    @ViewBuilder private func reader(for item: LearningItem) -> some View {
        if item.tracks.isEmpty { ReaderView(item: item) }
        else { BookReaderView(item: item) }
    }

    private var vocabularyIndexIdentity: String {
        "\(vocabulary.ready):\(vocabulary.revision):" + items.map(ReadingVocabularyStore.catalogKey).joined(separator: ";")
    }

    private func deleteItems(at offsets: IndexSet) {
        var fileTransactions: [LibraryDeleteTransaction] = []
        do {
            for index in offsets {
                let item = items[index]
                let itemID = item.id
                fileTransactions.append(try LibraryFileTransactionService.beginDelete(itemID: itemID))
                for entry in try context.fetch(FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.localSourceItemID == itemID })) {
                    translationCoordinator.cancel(entry.id)
                    context.delete(entry)
                }
                context.delete(item)
            }
            try context.save()
            fileTransactions.forEach { LibraryFileTransactionService.complete($0) }
        } catch {
            context.rollback()
            fileTransactions.forEach { LibraryFileTransactionService.rollback($0) }
            errorMessage = error.localizedDescription
        }
    }

    private func summary(for item: LearningItem) -> String {
        guard !item.tracks.isEmpty else {
            return item.parts.isEmpty
                ? "\(Int(item.duration / 60)) min · \(item.segments.count) transcript segments"
                : "\(item.parts.count) parts · \(item.segments.count) transcript segments"
        }
        let state: String
        switch BookSynchronizationState.resolve(item.tracks) {
        case .synced: state = "Synced"
        case .reviewRequired: state = "Review required"
        case .partlySynced(let review): state = review ? "Partly synced · review" : "Partly synced"
        case .untimed: state = "Untimed"
        }
        return "\(item.tracks.count) tracks · \(Int(item.duration / 60)) min · \(state)"
    }

    private func seedLearningUXFixtureIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--learning-ux-fixture"),
              (try? context.fetchCount(FetchDescriptor<DictionaryEntry>())) == 0 else { return }
        let item = LearningItem(id: UUID(), title: "UI test story", mediaKind: "audio",
                                mediaFilename: "missing.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let practice = DictionaryEntry(
            text: "dzień dobry", item: item, segmentIndex: 0,
            context: SelectionContext(text: "Powiedział dzień dobry.",
                                      selection: NSRange(location: 11, length: 11)),
            audioStart: 1, audioEnd: 2
        )
        practice.translationText = "добрый день"
        if ProcessInfo.processInfo.arguments.contains("--learning-context-fixture") {
            practice.contextTranslationText = "dzień — dzień — день\n\ndobry — dobry — добрый"
            practice.contextSelectedTranslationText = "здравствуйте"
        }
        practice.translationOrigin = .manual
        practice.translationStatus = .ready
        let learnt = DictionaryEntry(text: "do widzenia", item: item, segmentIndex: nil)
        learnt.translationText = "до свидания"
        learnt.translationOrigin = .manual
        learnt.translationStatus = .ready
        learnt.learningLevel = 4
        learnt.createdAt = Date(timeIntervalSince1970: 1)
        context.insert(item)
        context.insert(practice)
        context.insert(learnt)
        try? context.save()
    }
}
