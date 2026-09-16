import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DictionaryView: View {
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query(sort: \DictionaryEntry.createdAt, order: .reverse) private var entries: [DictionaryEntry]
    @State private var selectedEntry: DictionaryEntry?
    @State private var showingLearn = false
    @State private var exporting = false
    @State private var exportFile: DictionaryJSONFile?
    @State private var includeContext = true
    @State private var importing = false
    @State private var importMode: DictionaryImportMode = .merge
    @State private var importPreview: DictionaryImportPreview?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No saved phrases", systemImage: "text.book.closed", description: Text("Select text in a transcript and choose Add to Dictionary."))
            } else {
                List {
                    ForEach(entries) { entry in
                        Button { selectedEntry = entry } label: { DictionaryRow(entry: entry) }
                            .buttonStyle(.plain)
                    }.onDelete(perform: deleteEntries)
                }
            }
        }
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Learn", systemImage: "brain.head.profile") { showingLearn = true }
                    .disabled(!entries.contains(where: \.isLearningEligible))
                    .accessibilityIdentifier("dictionary.learn")
                Menu("Transfer", systemImage: "arrow.up.arrow.down") {
                    Toggle("Include source context", isOn: $includeContext)
                    Button("Export Dictionary", systemImage: "square.and.arrow.up") { prepareExport() }
                    Menu("Import Dictionary") {
                        Button(DictionaryImportMode.merge.rawValue) { importMode = .merge; importing = true }
                        Button(DictionaryImportMode.translations.rawValue) { importMode = .translations; importing = true }
                    }
                }
            }
        }
        .sheet(item: $selectedEntry) { DictionaryEntryDetailView(entry: $0) }
        .sheet(isPresented: $showingLearn) { LearningSessionView() }
        .sheet(item: $importPreview) { DictionaryImportPreviewView(preview: $0) }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                      defaultFilename: "dictionary-\(Self.dayStamp).json") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportFile = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in handleImport(result) }
        .alert("Dictionary error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func deleteEntries(_ offsets: IndexSet) {
        do {
            for index in offsets { translationCoordinator.cancel(entries[index].id); context.delete(entries[index]) }
            try context.save()
        } catch { context.rollback(); errorMessage = error.localizedDescription }
    }

    private func prepareExport() {
        do { exportFile = try DictionaryTransferService.export(entries: entries, includeContext: includeContext); exporting = true }
        catch { errorMessage = error.localizedDescription }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let document = try DictionaryTransferService.decode(Data(contentsOf: url, options: .mappedIfSafe))
            importPreview = DictionaryTransferService.preview(document: document, mode: importMode, existing: entries)
        } catch { errorMessage = error.localizedDescription }
    }

    private static var dayStamp: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: .now)
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text).foregroundStyle(.primary)
                Text(entry.sourceTitle).font(.caption).foregroundStyle(.secondary)
                Label(statusText, systemImage: statusIcon).font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
            Text("\(entry.learningLevel) · \(LearningLevel.title(entry.learningLevel))")
                .font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
        }.contentShape(Rectangle())
    }
    private var statusText: String {
        switch entry.translationStatus {
        case .pending: "Translation queued"
        case .translating: "Translating…"
        case .needsDownload: "Language download needed"
        case .ready: "Translation available"
        case .failed: "Translation failed"
        case .unsupported: "Automatic translation unavailable"
        }
    }
    private var statusIcon: String {
        switch entry.translationStatus { case .ready: "checkmark.circle.fill"; case .failed, .unsupported: "exclamationmark.triangle"; case .needsDownload: "arrow.down.circle"; case .translating: "ellipsis.circle"; case .pending: "clock" }
    }
    private var statusColor: Color { entry.translationStatus == .ready ? .green : entry.translationStatus == .failed ? .red : .secondary }
}

struct DictionaryEntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var coordinator
    @Bindable var entry: DictionaryEntry
    @State private var editing = false
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var confirmingReplacement = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Original") { Text(entry.text).textSelection(.enabled) }
                if let contextText = entry.contextText {
                    Section("Source context") {
                        Text(contextText)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dictionary.source-context")
                    }
                }
                Section("Russian translation") {
                    if editing { TextEditor(text: $draft).frame(minHeight: 100) }
                    else if let translation = entry.translationText { Text(translation).textSelection(.enabled) }
                    else { Text("Translation is not available yet.").foregroundStyle(.secondary) }
                }
                Section("Progress") { LabeledContent("Level", value: "\(entry.learningLevel) · \(LearningLevel.title(entry.learningLevel))") }
                Section("Source") {
                    Text(entry.sourceTitle)
                    LabeledContent("Languages", value: "\(SourceLanguage.name(for: entry.sourceLanguageCode)) → Russian")
                }
                Section("Automatic translation") {
                    Button(entry.hasTranslation ? "Translate Again" : "Force Translation",
                           systemImage: "character.book.closed") {
                        if entry.hasTranslation { confirmingReplacement = true }
                        else { forceTranslation() }
                    }
                    if entry.translationStatus == .failed || entry.translationStatus == .needsDownload {
                        Button("Retry Translation", systemImage: "arrow.clockwise") { coordinator.retry(entry, context: context) }
                    }
                }
            }
            .navigationTitle("Dictionary entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(editing ? "Cancel" : "Close") { if editing { editing = false } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    if editing { Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    else { Button("Edit") { draft = entry.translationText ?? ""; editing = true } }
                }
            }
            .interactiveDismissDisabled(editing)
            .confirmationDialog("Replace saved translation?", isPresented: $confirmingReplacement) {
                Button("Translate Again", role: .destructive) { forceTranslation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current translation will be replaced with a new automatic translation.")
            }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
        }.presentationDetents([.medium, .large])
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        coordinator.cancel(entry.id)
        entry.translationRevision += 1
        entry.translationText = value
        entry.translationOrigin = .manual
        entry.translationUpdatedAt = .now
        entry.translationStatus = .ready
        do { try context.save(); editing = false } catch { context.rollback(); errorMessage = error.localizedDescription }
    }

    private func forceTranslation() {
        do { try coordinator.force(entry, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct DictionaryImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var coordinator
    let preview: DictionaryImportPreview
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") { Text(preview.mode.rawValue) }
                Section("Changes") {
                    LabeledContent("New entries", value: "\(preview.additions)")
                    LabeledContent("Translation updates", value: "\(preview.translationChanges)")
                    LabeledContent("Conflicts kept local", value: "\(preview.conflicts)")
                    LabeledContent("Unchanged", value: "\(preview.unchanged)")
                    LabeledContent("Skipped", value: "\(preview.skipped)")
                }
                if preview.conflicts > 0 { Text("Conflicting local translations and entry identities will be kept unchanged.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Import Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() } }
            }
            .alert("Import failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
        }
    }
    private func apply() {
        do {
            let pending = try DictionaryTransferService.apply(preview, context: context)
            pending.forEach { coordinator.enqueue($0, context: context) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
