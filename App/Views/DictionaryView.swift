import SwiftUI
import SwiftData
import Translation
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
    @Query private var sourceItems: [LearningItem]
    @Bindable var entry: DictionaryEntry
    @State private var playback = PlaybackController()
    @State private var editing = false
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var confirmingReplacement = false
    @State private var contextual = ContextualTranslationCoordinator()
    @State private var dictionaryLookup = PolishDictionaryLookupCoordinator()
    @State private var showGrammarWords = false
    @State private var hasAutoStarted = false
    @State private var senseDraft = ""
    @State private var noteDraft = ""
    let autoStartContext: Bool

    init(entry: DictionaryEntry, autoStartContext: Bool = false) {
        self.entry = entry
        self.autoStartContext = autoStartContext
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Original") { Text(entry.text).textSelection(.enabled) }
                Section("Audio") {
                    if let item = sourceItem, let start = entry.audioStart, let end = entry.audioEnd, end > start {
                        Button {
                            playAudio(item: item, start: start, end: end)
                        } label: {
                            Label(playback.isPlaying ? "Pause phrase" : "Play phrase",
                                  systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        }
                        .accessibilityIdentifier("dictionary.play-audio")
                        Text("\(formatTime(start))–\(formatTime(end)) · \(item.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Audio is unavailable for this phrase", systemImage: "speaker.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                if let contextText = entry.contextText {
                    Section("Source context") {
                        Text(highlightedContext(contextText))
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
                if ContextSentenceExtractor.sentence(for: entry) != nil {
                    Section("Meaning in context") {
                        if let candidate = entry.contextSelectedTranslationText {
                            LabeledContent("Selected text", value: candidate)
                            if candidate != entry.translationText {
                                Button("Use as Saved Translation", systemImage: "checkmark.circle") {
                                    useContextTranslation(candidate)
                                }
                            }
                        }
                        if let sentence = entry.contextTranslationText {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sentence translation").font(.caption).foregroundStyle(.secondary)
                                Text(sentence).textSelection(.enabled)
                            }
                        }
                        contextProgress
                        Button(entry.contextTranslationText == nil ? "Translate in Context" : "Refresh Context Translation",
                               systemImage: "character.book.closed") {
                            contextual.translateContext(for: entry, context: context)
                        }
                        .accessibilityIdentifier("dictionary.context-translate")
                        Text("The selected expression and its sentence are translated separately so you can compare the likely meaning. Existing manual or imported translations are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Word-by-word help") {
                        if !entry.wordHelpItems.isEmpty {
                            ForEach(Array(visibleWordHelp.enumerated()), id: \.offset) { _, item in
                                wordHelpRow(item)
                            }
                            if hiddenGrammarWordCount > 0 {
                                Toggle("Show \(hiddenGrammarWordCount) grammar words", isOn: $showGrammarWords)
                            }
                        }
                        contextProgress(wordsOnly: true)
                        Button(entry.wordHelpItems.isEmpty ? "Generate Word-by-word Help" : "Refresh Word-by-word Help",
                               systemImage: "list.bullet.rectangle") {
                            contextual.translateWords(for: entry, context: context)
                        }
                        .accessibilityIdentifier("dictionary.word-help")
                        Text("Generated only when requested. These are individual word translations; the sentence translation remains the guide to meaning in context.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Your interpretation") {
                        TextField("Preferred meaning", text: $senseDraft)
                        TextField("Personal note", text: $noteDraft, axis: .vertical).lineLimit(2...5)
                        Button("Save Meaning and Note") { saveInterpretation() }
                            .disabled(senseDraft == (entry.selectedSenseText ?? "") && noteDraft == (entry.userNote ?? ""))
                    }
                }
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
                    if entry.translationStatus == .translating {
                        Label("Translating now — this may take a moment.", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
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
            .translationTask(contextual.configuration, action: contextual.perform(session:))
            .task {
                senseDraft = entry.selectedSenseText ?? ""
                noteDraft = entry.userNote ?? ""
                if autoStartContext, !hasAutoStarted {
                    hasAutoStarted = true
                    contextual.translateContext(for: entry, context: context)
                }
            }
            .onDisappear {
                playback.close()
                dictionaryLookup.cancelAll()
                if !entry.hasTranslation, entry.translationStatus == .pending {
                    coordinator.enqueue(entry, context: context)
                }
            }
            .confirmationDialog("Replace saved translation?", isPresented: $confirmingReplacement) {
                Button("Translate Again", role: .destructive) { forceTranslation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current translation will be replaced with a new automatic translation.")
            }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
            .translationTask(coordinator.configuration, action: coordinator.perform(session:))
            .alert("Context translation failed", isPresented: Binding(
                get: { if case .failed = contextual.status { true } else { false } },
                set: { if !$0 { contextual.clearError() } }
            )) {
                Button("OK") { contextual.clearError() }
            } message: {
                if case .failed(let message) = contextual.status { Text(message) }
            }
        }.presentationDetents([.medium, .large])
    }

    private var sourceItem: LearningItem? {
        sourceItems.first { $0.id == (entry.localSourceItemID ?? entry.sourceItemID) }
    }

    private func playAudio(item: LearningItem, start: Double, end: Double) {
        let url = MediaImportService.directory(for: item.id).appending(path: item.mediaFilename)
        if playback.isPlaying {
            playback.toggle()
        } else {
            playback.close()
            playback.open(url: url, position: start, range: start...end)
            playback.toggle()
        }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder private var contextProgress: some View {
        switch contextual.status {
        case .needsDownload:
            Label("Language download required", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .translatingContext:
            HStack { ProgressView(); Text("Translating selection and sentence…") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func contextProgress(wordsOnly: Bool) -> some View {
        if wordsOnly, contextual.status == .translatingWords {
            HStack { ProgressView(); Text("Translating sentence words…") }
        }
    }

    private var visibleWordHelp: [WordHelpItem] {
        showGrammarWords ? entry.wordHelpItems : entry.wordHelpItems.filter { !$0.isGrammarWord }
    }

    private var hiddenGrammarWordCount: Int {
        entry.wordHelpItems.count(where: \WordHelpItem.isGrammarWord)
    }

    @ViewBuilder private func wordHelpRow(_ item: WordHelpItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(item.sourceText, value: item.translationText)
            if entry.sourceLanguageCode == "pl" {
                if let result = item.polishDictionaryResult {
                    DisclosureGroup("Polish definition · \(result.headword)") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let form = result.resolvedFromForm {
                                Text("\(form) → dictionary form: \(result.headword)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let partOfSpeech = result.partOfSpeech {
                                Text(partOfSpeech).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(result.meanings.enumerated()), id: \.element.id) { index, meaning in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(meaning.definition)")
                                    if !meaning.usageLabels.isEmpty {
                                        Text(meaning.usageLabels.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(meaning.examples, id: \.self) { example in
                                        Text(example).italic().foregroundStyle(.secondary)
                                    }
                                }
                            }
                            HStack {
                                if let sourceURL = URL(string: result.sourceURL) {
                                    Link("Source: Polish Wiktionary", destination: sourceURL)
                                }
                                Spacer()
                                switch dictionaryLookup.state(for: item.sourceText) {
                                case .loading:
                                    ProgressView()
                                default:
                                    Button("Refresh", systemImage: "arrow.clockwise") {
                                        dictionaryLookup.lookup(item.sourceText, lemma: result.headword,
                                                                for: entry, context: context)
                                    }
                                }
                            }.font(.caption)
                            if case .failed(let message) = dictionaryLookup.state(for: item.sourceText) {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }.padding(.top, 6)
                    }
                } else {
                    switch dictionaryLookup.state(for: item.sourceText) {
                    case .idle:
                        Button("Look up Polish definition", systemImage: "book.closed") {
                            dictionaryLookup.lookup(item.sourceText, for: entry, context: context)
                        }
                        .accessibilityIdentifier("dictionary.polish-lookup.\(item.sourceText)")
                    case .loading:
                        HStack { ProgressView(); Text("Looking up Polish definition…") }
                            .foregroundStyle(.secondary)
                    case .choosingLemma(let lemmas):
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Choose the dictionary form for “\(item.sourceText)”:")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(lemmas, id: \.self) { lemma in
                                Button(lemma, systemImage: "book.closed") {
                                    dictionaryLookup.lookup(item.sourceText, lemma: lemma,
                                                            for: entry, context: context)
                                }
                            }
                        }
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message).font(.caption).foregroundStyle(.red)
                            Button("Try Again", systemImage: "arrow.clockwise") {
                                dictionaryLookup.lookup(item.sourceText, for: entry, context: context)
                            }
                        }
                    }
                }
            }
        }
    }

    private func highlightedContext(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let location = entry.contextSelectionLocation,
              let length = entry.contextSelectionLength,
              let stringRange = Range(NSRange(location: location, length: length), in: text),
              let range = Range(stringRange, in: result) else { return result }
        result[range].backgroundColor = .yellow.opacity(0.35)
        result[range].font = .body.bold()
        return result
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

    private func useContextTranslation(_ value: String) {
        coordinator.cancel(entry.id)
        entry.translationRevision += 1
        entry.translationText = value
        entry.translationOrigin = .manual
        entry.translationUpdatedAt = .now
        entry.translationStatus = .ready
        do { try context.save() } catch { context.rollback(); errorMessage = error.localizedDescription }
    }

    private func saveInterpretation() {
        entry.selectedSenseText = senseDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        entry.userNote = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        do { try context.save() } catch { context.rollback(); errorMessage = error.localizedDescription }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
