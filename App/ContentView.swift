import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
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
                for entry in try context.fetch(FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.sourceItemID == itemID })) { context.delete(entry) }
                context.delete(item)
            }
            try context.save()
        } catch { context.rollback(); errorMessage = error.localizedDescription }
    }
}

struct DictionaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictionaryEntry.createdAt, order: .reverse) private var entries: [DictionaryEntry]
    @State private var errorMessage: String?
    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No saved phrases", systemImage: "text.book.closed", description: Text("Select text in a transcript and choose Add to Dictionary."))
            } else {
                List {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).textSelection(.enabled)
                            Text(entry.sourceTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }.onDelete { offsets in
                        for index in offsets { context.delete(entries[index]) }
                        do { try context.save() } catch { context.rollback(); errorMessage = error.localizedDescription }
                    }
                }
            }
        }.navigationTitle("Dictionary")
            .alert("Could not delete phrase", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }
}
