import SwiftUI
import SwiftData
import Translation

struct ContentView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query(sort: \LearningItem.createdAt, order: .reverse) private var items: [LearningItem]
    @State private var showingImport = false
    @State private var showingBookImport = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("Your library is empty", systemImage: "headphones", description: Text("Upload audio and a transcript to start learning."))
                } else {
                    List {
                        ForEach(items) { item in
                        NavigationLink {
                            if item.tracks.isEmpty { ReaderView(item: item) }
                            else { BookReaderView(item: item) }
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    BookVocabularyBadge(item: item)
                                    Text("Read: \(item.readingProgress.formatted(.percent.precision(.fractionLength(0))))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(summary(for: item))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: item.mediaKind == "video" ? "video" : "waveform") }
                        }
                        }.onDelete(perform: deleteItems)
                    }
                }
            }
            .safeAreaInset(edge: .top) { ReadingVocabularyStatus() }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { NavigationLink("Dictionary") { DictionaryView() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        ContextualTranslationSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("library.settings")

                    Menu("More import options", systemImage: "ellipsis.circle") {
                        Button("Single audio or video") { showingImport = true }
                        Button("Audiobook ZIP") { showingBookImport = true }
                            .accessibilityIdentifier("library.upload-book")
                    } primaryAction: { showingImport = true }
                    .accessibilityIdentifier("library.upload")
                }
            }
            .sheet(isPresented: $showingImport) { ImportItemView() }
            .sheet(isPresented: $showingBookImport) { BookImportView() }
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
