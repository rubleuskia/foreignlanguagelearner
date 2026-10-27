import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryBackupMenu: View {
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @State private var exporting = false
    @State private var exportFile: DictionaryJSONFile?
    @State private var importing = false
    @State private var legacyMode: DictionaryImportMode = .restore
    @State private var libraryPreview: LibraryBackupPreview?
    @State private var dictionaryPreview: DictionaryImportPreview?
    @State private var errorMessage: String?

    var body: some View {
        Menu("Backup Library", systemImage: "arrow.up.arrow.down") {
            Button("Backup Library", systemImage: "square.and.arrow.up") { export() }
                .accessibilityIdentifier("library.backup.export")
            Button("Import Library", systemImage: "square.and.arrow.down") {
                legacyMode = .restore; importing = true
            }
            .accessibilityIdentifier("library.backup.import")
            Menu("Import Dictionary JSON") {
                ForEach(DictionaryImportMode.allCases) { mode in
                    Button(AppLanguage.text(mode.rawValue)) { legacyMode = mode; importing = true }
                }
            }
        }
        .accessibilityIdentifier("library.backup")
        .disabled(!vocabulary.ready)
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                      defaultFilename: "library-backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).json") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportFile = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in readImport(result) }
        .sheet(item: $libraryPreview) { LibraryBackupPreviewView(preview: $0) }
        .sheet(item: $dictionaryPreview) { DictionaryImportPreviewView(preview: $0) }
        .alert("Library backup", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(AppLanguage.text(errorMessage ?? "")) }
    }

    private func export() {
        do {
            guard vocabulary.ready else { throw ReadingVocabularyError.notReady }
            exportFile = try LibraryBackupService.export(context: context)
            exporting = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func readImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard vocabulary.ready else { throw ReadingVocabularyError.notReady }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= LibraryBackupService.maximumBytes else {
                throw LibraryBackupError.invalid("Library backup exceeds 128 MiB.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if header?["format"] as? String == LibraryBackupService.format {
                libraryPreview = try LibraryBackupService.preview(LibraryBackupService.decode(data), context: context)
            } else {
                let document = try DictionaryTransferService.decode(data)
                dictionaryPreview = DictionaryTransferService.preview(document: document, mode: legacyMode,
                    existing: try context.fetch(FetchDescriptor<DictionaryEntry>()),
                    existingVocabulary: try ReadingKnowledge.words(context: context))
            }
        } catch CocoaError.userCancelled { }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct LibraryBackupPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(DictionaryTranslationCoordinator.self) private var coordinator
    @State var preview: LibraryBackupPreview
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Restore library") {
                    LabeledContent("Backup date", value: preview.document.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Matched books", value: "\(preview.matches.count) / \(preview.document.books.count)")
                    LabeledContent("Dictionary entries", value: "\(preview.dictionary.entries.count)")
                    LabeledContent("Studied reading words", value: "\(preview.dictionary.readingVocabulary?.words.count ?? 0)")
                    LabeledContent("Saved word explanations", value: "\(preview.document.wordExplanations.count)")
                    if preview.document.round != nil { Text("Includes unfinished training.") }
                    Text("Restores book and chapter progress, playback positions, dictionary details, learning levels, settings and prompts. Matching saved states are replaced; unrelated books and dictionary entries are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Book files") {
                    Text("Import the same books on this phone first, then import this backup. Books are matched by their text and audio layout, even if their title changed.")
                    Text("Book text, audio, subtitles and alignments are not included. The API key stays in Keychain; enter it separately on a new phone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !preview.issues.isEmpty {
                    Section("Resolve before restoring") {
                        ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .nativeForm()
            .navigationTitle("Import Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { restore() }
                        .disabled(!preview.canRestore || !vocabulary.ready)
                        .accessibilityIdentifier("library.backup.restore")
                }
            }
            .alert("Restore failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(AppLanguage.text(errorMessage ?? "")) }
        }
    }

    private func restore() {
        do {
            guard vocabulary.ready else { throw ReadingVocabularyError.notReady }
            let fresh = try LibraryBackupService.preview(preview.document, context: context)
            guard fresh.canRestore, fresh.matches == preview.matches else {
                preview = fresh
                throw LibraryBackupError.invalid("Library changed. Review the updated matches before restoring.")
            }
            // Invalidates queued Apple translation results before restoring their saved state.
            for entry in preview.dictionary.entries { coordinator.cancel(entry.id) }
            let pending = try LibraryBackupService.restore(preview, context: context)
            try vocabulary.reload(context: context)
            pending.forEach { coordinator.enqueue($0, context: context) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
