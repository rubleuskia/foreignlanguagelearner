import SwiftUI
import SwiftData
import Translation

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query(sort: \LearningItem.createdAt, order: .reverse) private var items: [LearningItem]
    @State private var showingImport = false
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
                            ReaderView(item: item)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(item.parts.isEmpty ? "\(Int(item.duration / 60)) min · \(item.segments.count) transcript segments" : "\(item.parts.count) parts · \(item.segments.count) transcript segments")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: item.mediaKind == "video" ? "video" : "waveform") }
                        }
                        }.onDelete(perform: deleteItems)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { NavigationLink("Dictionary") { DictionaryView() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Upload item", systemImage: "plus") { showingImport = true }.accessibilityIdentifier("library.upload")
                }
            }
            .sheet(isPresented: $showingImport) { ImportItemView() }
            .task {
                seedLearningUXFixtureIfNeeded()
                translationCoordinator.recover(context: context)
            }
            .translationTask(translationCoordinator.configuration,
                             action: translationCoordinator.perform(session:))
            .alert("Could not delete item", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        do {
            for index in offsets {
                let item = items[index]
                let itemID = item.id
                let directory = MediaImportService.directory(for: item.id)
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                for entry in try context.fetch(FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.localSourceItemID == itemID })) {
                    translationCoordinator.cancel(entry.id)
                    context.delete(entry)
                }
                context.delete(item)
            }
            try context.save()
        } catch { context.rollback(); errorMessage = error.localizedDescription }
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
                                      selection: NSRange(location: 10, length: 11)),
            audioStart: 1, audioEnd: 2
        )
        practice.translationText = "добрый день"
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
