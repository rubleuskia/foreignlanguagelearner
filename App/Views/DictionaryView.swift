import SwiftUI
import SwiftData
import Translation

struct DictionaryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query(sort: \DictionaryEntry.createdAt, order: .reverse) private var entries: [DictionaryEntry]
    @AppStorage(LearningRoundCheckpoint.key) private var savedRoundData = Data()
    @State private var selectedLevel: Int?
    @State private var readyOnly = false
    @State private var selectedEntry: DictionaryEntry?
    @State private var learningLaunch: LearningLaunch?

    private enum LearningLaunch: String, Identifiable {
        case setup, quickStart
        var id: Self { self }
    }
    @State private var errorMessage: String?

    private var learningEntries: [DictionaryEntry] {
        entries.filter { entry in
            if readyOnly && !entry.isReadyForReview { return false }
            if let selectedLevel { return entry.learningLevel == selectedLevel }
            return entry.learningLevel != 4
        }
    }
    private var learntEntries: [DictionaryEntry] { entries.filter { $0.learningLevel == 4 } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            List {
                OnboardingTip(step: .dictionary, allowed: !entries.isEmpty && selectedEntry == nil && learningLaunch == nil)
                ReadingVocabularyStatus()
                if !savedRoundData.isEmpty, LearningRoundCheckpoint.load() != nil {
                    Section {
                        Button("Continue unfinished training", systemImage: "play.circle") { learningLaunch = .setup }
                            .accessibilityIdentifier("dictionary.resume")
                    }
                }
                if entries.contains(where: \.isReadyForReview) {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(entries.count(where: \.isReadyForReview)) ready to repeat")
                                .font(.title3.weight(.semibold))
                            Text("A short round from your saved expressions.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button { learningLaunch = .quickStart } label: {
                                Label("Quick start", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .nativePrimaryAction()
                            .accessibilityIdentifier("dictionary.quick-start")
                        }
                        .padding(.vertical, 8)
                    }
                }
                Section("Learning progress") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                             count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                        ForEach(1...4, id: \.self) { level in
                            Button { selectedLevel = level } label: {
                                VStack(spacing: 6) {
                                    Text(LearningLevel.title(level)).font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(level == 1 || level == 4
                                         ? "\(entries.count(where: { $0.learningLevel == level }))"
                                         : "\(entries.count(where: { $0.learningLevel == level })) (\(entries.count(where: { $0.learningLevel == level && $0.isReadyForReview })))")
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(.primary)
                                        .accessibilityIdentifier("dictionary.stats.level.\(level)")
                                }
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .padding(6)
                                .background(selectedLevel == level ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedLevel == level ? [.isSelected] : [])
                            .accessibilityIdentifier("dictionary.filter.level.\(level)")
                        }
                    }
                    .padding(.vertical, 4)
                    Toggle("Ready to repeat", isOn: $readyOnly)
                        .accessibilityIdentifier("dictionary.filter.ready")
                    if selectedLevel != nil || readyOnly {
                        Button("Reset filter") { selectedLevel = nil; readyOnly = false }
                            .accessibilityIdentifier("dictionary.filter.reset")
                    }
                }
                if entries.isEmpty {
                    ContentUnavailableView("No saved phrases", systemImage: "text.book.closed", description: Text("Open a book in Library, touch and hold a word, then choose Add to Dictionary. Text without audio works too."))
                        .listRowBackground(Color.clear)
                } else {
                    if !learningEntries.isEmpty || selectedLevel != nil || readyOnly {
                        Section(selectedLevel.map { "In progress · Level \($0)" } ?? "In progress") {
                            if learningEntries.isEmpty { Text(readyOnly ? "No phrases ready to repeat" : "No phrases at this level").foregroundStyle(.secondary) }
                            ForEach(learningEntries) { entry in
                                entryButton(entry)
                            }
                            .onDelete { deleteEntries($0, from: learningEntries) }
                        }
                    }
                    if selectedLevel == nil && !readyOnly {
                        Section("Learnt phrases") {
                            if learntEntries.isEmpty {
                                Text("No learnt phrases yet").foregroundStyle(.secondary)
                            } else {
                                ForEach(learntEntries) { entry in
                                    entryButton(entry)
                                }
                                .onDelete { deleteEntries($0, from: learntEntries) }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NativeDesign.page)
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Learn", systemImage: "brain.head.profile") { learningLaunch = .setup }
                    .disabled(!entries.contains(where: \.isLearningEligible))
                    .accessibilityIdentifier("dictionary.learn")
            }
        }
        .sheet(item: $selectedEntry) { DictionaryEntryDetailView(entry: $0) }
        .sheet(item: $learningLaunch) { launch in
            LearningSessionView(quickStart: launch == .quickStart)
        }
        .alert("Dictionary error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func entryButton(_ entry: DictionaryEntry) -> some View {
        Button { selectedEntry = entry } label: { DictionaryRow(entry: entry) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dictionary.entry.\(entry.text)")
    }

    private func deleteEntries(_ offsets: IndexSet, from sectionEntries: [DictionaryEntry]) {
        do {
            for index in offsets {
                let entry = sectionEntries[index]
                translationCoordinator.cancel(entry.id)
                context.delete(entry)
            }
            try context.save()
        } catch { context.rollback(); errorMessage = error.localizedDescription }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text).foregroundStyle(.primary)
                if let translation = entry.translationText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !translation.isEmpty {
                    Text(translation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("dictionary.row-translation")
                }
                PhraseCooldownLabel(entry: entry)
                Text(entry.sourceTitle).font(.caption).foregroundStyle(.secondary)
                if entry.translationStatus != .ready {
                    Label(statusText, systemImage: statusIcon).font(.caption).foregroundStyle(statusColor)
                }
            }
            Spacer()
            LearningLevelBadge(level: entry.learningLevel)
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
    @Environment(\.contextAnalysisService) private var contextAnalysisService
    @Environment(DictionaryTranslationCoordinator.self) private var coordinator
    @Query private var sourceItems: [LearningItem]
    @Bindable var entry: DictionaryEntry
    @State private var playback = PlaybackController()
    @State private var editing = false
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var confirmingReplacement = false
    @State private var contextual = ContextualTranslationCoordinator()
    @State private var hasAutoStarted = false
    @State private var senseDraft = ""
    @State private var noteDraft = ""
    @State private var audioMode: PhraseAudioMode = .selection
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?
    let autoStartContext: Bool

    init(entry: DictionaryEntry, autoStartContext: Bool = false) {
        self.entry = entry
        self.autoStartContext = autoStartContext
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source phrase") {
                    if entry.phraseAudioStart != nil {
                        Picker("Audio", selection: $audioMode) {
                            ForEach(PhraseAudioMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: audioMode) { _, _ in playback.close(); openedAudioIdentity = nil }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.text)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("dictionary.original")
                        if let source = audioSource {
                            Button { toggleAudio(source) } label: {
                                Label(playback.isPlaying ? source.pauseLabel : source.playLabel,
                                      systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .font(.title2)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("dictionary.play-audio")
                            .modifier(PhraseAudioEditing(entry: entry, items: sourceItems, source: source, stopPlayback: { playback.pause() }, mode: entry.phraseAudioStart == nil ? .selection : audioMode))
                        }
                        CopyButton(value: entry.text, label: "Copy original",
                                   identifier: "dictionary.copy-original")
                    }
                    if let source = audioSource {
                        Text("\(formatTime(source.identity.range.lowerBound))–\(formatTime(source.identity.range.upperBound)) · \(source.itemTitle)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Audio unavailable on this device", systemImage: "speaker.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Russian translation") {
                    if editing {
                        TextEditor(text: $draft).frame(minHeight: 100)
                    } else if let translation = entry.translationText {
                        HStack(alignment: .top, spacing: 12) {
                            Text(translation).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("dictionary.detail-translation")
                            CopyButton(value: translation, label: "Copy translation",
                                       identifier: "dictionary.copy-translation")
                        }
                    } else {
                        Text("Translation is not available yet.").foregroundStyle(.secondary)
                    }
                }
                if ContextSentenceExtractor.sentence(for: entry) != nil {
                    Section("Meaning in context") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let explanation = entry.contextTranslationText?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !explanation.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Word explanations").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("dictionary.context-words")
                                    ContextWordExplanationView(explanation: explanation, selectedText: entry.text,
                                        context: entry.contextText.flatMap { text in
                                            guard let location = entry.contextSelectionLocation,
                                                  let length = entry.contextSelectionLength else { return nil }
                                            return SelectionContext(text: text, selection: NSRange(location: location, length: length))
                                        }, sourceLanguage: entry.sourceLanguageCode, targetLanguage: entry.targetLanguageCode)
                                }
                                if entry.contextSelectedTranslationText != nil { Divider() }
                            }
                            if let candidate = entry.contextSelectedTranslationText {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Overall translation").font(.caption).foregroundStyle(.secondary)
                                    Text(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityIdentifier("dictionary.context-overall")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let candidate = entry.contextSelectedTranslationText, candidate != entry.translationText {
                            Button("Use as Saved Translation", systemImage: "checkmark.circle") {
                                useContextTranslation(candidate)
                            }
                        }
                        contextProgress
                        Button(entry.contextTranslationText == nil ? "Translate in Context" : "Refresh Context Translation",
                               systemImage: "character.book.closed") {
                            contextual.translateContext(for: entry, context: context,
                                                        service: contextAnalysisService)
                        }
                        .accessibilityIdentifier("dictionary.context-translate")
                        Text("Content words are explained in context; common function words are omitted from the breakdown. The overall translation includes the complete phrase. Existing manual or imported translations are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                }
                if let contextText = entry.contextText {
                    Section("Source context") {
                        CopyableContentRow(value: contextText, label: "Copy source context",
                                           identifier: "dictionary.copy-source-context") {
                            Text(highlightedContext(contextText))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("dictionary.source-context")
                        }
                    }
                }
                Section("Progress") {
                    Picker("Level", selection: Binding(
                        get: { entry.learningLevel },
                        set: { saveLevel($0) }
                    )) {
                        ForEach(1...4, id: \.self) { level in
                            Text("\(level) · \(LearningLevel.title(level))").tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("dictionary.level-picker")
                    PhraseCooldownLabel(entry: entry)
                }
                if ContextSentenceExtractor.sentence(for: entry) != nil {
                    Section("Your interpretation") {
                        TextField("Preferred meaning", text: $senseDraft)
                        TextField("Personal note", text: $noteDraft, axis: .vertical).lineLimit(2...5)
                        if let value = entry.selectedSenseText, !value.isEmpty {
                            CopyButton(value: value, label: "Copy preferred meaning",
                                       identifier: "dictionary.copy-meaning")
                        }
                        if let value = entry.userNote, !value.isEmpty {
                            CopyButton(value: value, label: "Copy personal note",
                                       identifier: "dictionary.copy-note")
                        }
                        Button("Save Meaning and Note") { saveInterpretation() }
                            .disabled(senseDraft == (entry.selectedSenseText ?? "") && noteDraft == (entry.userNote ?? ""))
                    }
                }
                Section("Source") {
                    Text(entry.sourceTitle)
                    LabeledContent("Languages", value: "\(SourceLanguage.name(for: entry.sourceLanguageCode)) → Russian")
                }
                Section { ExportLogsButton() }
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
            .nativeForm()
            .navigationTitle("Dictionary entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(editing ? "Cancel" : "Close") { if editing { editing = false } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    if editing { Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    else {
                        Button("Edit") {
                            playback.close()
                            openedAudioIdentity = nil
                            draft = entry.translationText ?? ""
                            editing = true
                        }
                    }
                }
            }
            .interactiveDismissDisabled(editing)
            .task {
                senseDraft = entry.selectedSenseText ?? ""
                noteDraft = entry.userNote ?? ""
                if autoStartContext, !hasAutoStarted {
                    hasAutoStarted = true
                    contextual.translateContext(for: entry, context: context,
                                                service: contextAnalysisService)
                }
            }
            .onDisappear {
                playback.close()
                openedAudioIdentity = nil
                contextual.cancelCurrentRequest()
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

    private var audioSource: PhraseAudioSource? {
        PhraseAudioSourceResolver.resolve(entry: entry, items: sourceItems, mode: entry.phraseAudioStart == nil ? .selection : audioMode)
    }

    private func toggleAudio(_ source: PhraseAudioSource) {
        if openedAudioIdentity == source.identity {
            playback.toggle()
        } else {
            playback.open(url: source.identity.url, position: source.identity.range.lowerBound,
                          range: source.identity.range)
            openedAudioIdentity = source.identity
            playback.play()
        }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder private var contextProgress: some View {
        switch contextual.status {
        case .translatingContext:
            HStack { ProgressView(); Text("Translating selection and sentence…") }
        default:
            EmptyView()
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

    private func saveLevel(_ level: Int) {
        guard (1...4).contains(level), level != entry.learningLevel else { return }
        let previousLevel = entry.learningLevel
        let previousDate = entry.levelChangedAt
        entry.learningLevel = level
        entry.levelChangedAt = .now
        do { try context.save() }
        catch {
            entry.learningLevel = previousLevel
            entry.levelChangedAt = previousDate
            errorMessage = error.localizedDescription
        }
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

struct DictionaryImportPreviewView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var coordinator
    @State var preview: DictionaryImportPreview
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Text(preview.mode.rawValue)
                    if preview.mode == .restore {
                        Text("Restores saved details and learning progress for matching entries. Other entries stay in the dictionary.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Audio files are not included. Saved audio links work only while the original source book is available on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    if preview.document.schemaVersion == 1 {
                        Text("This older backup does not contain word explanations, personal notes or audio links.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Changes") {
                    LabeledContent("New entries", value: "\(preview.additions)")
                    LabeledContent("Translation updates", value: "\(preview.translationChanges)")
                    if preview.mode == .restore {
                        LabeledContent("Entries to restore", value: "\(preview.restorations)")
                    }
                    LabeledContent("Conflicts kept local", value: "\(preview.conflicts)")
                    LabeledContent("Unchanged", value: "\(preview.unchanged)")
                    LabeledContent("Skipped", value: "\(preview.skipped)")
                }
                if let words = preview.document.readingVocabulary?.words {
                    Section("Words from read texts") {
                        if preview.mode == .translations { Text("\(words.count) reading words will be skipped. This mode updates translations only.") }
                        else {
                            LabeledContent("New studied words", value: "\(preview.vocabularyAdditions)")
                            LabeledContent("Already studied", value: "\(preview.vocabularyDuplicates)")
                            Text("Reading vocabulary is merged. No local studied words are removed. Books and chapter marks are not restored.").font(.caption)
                        }
                    }
                }
                if preview.conflicts > 0 { Text("Conflicting local translations and entry identities will be kept unchanged.").foregroundStyle(.secondary) }
            }
            .nativeForm()
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
            guard vocabulary.ready else { throw ReadingVocabularyError.notReady }
            let current = DictionaryTransferService.preview(document: preview.document, mode: preview.mode,
                existing: try context.fetch(FetchDescriptor<DictionaryEntry>()),
                existingVocabulary: try ReadingKnowledge.words(context: context))
            if current.vocabularySnapshot != preview.vocabularySnapshot {
                preview = current
                throw ReadingVocabularyError.changed
            }
            let pending = try DictionaryTransferService.apply(preview, context: context)
            if preview.mode == .restore {
                for entry in preview.document.entries { coordinator.cancel(entry.id) }
            }
            try vocabulary.reload(context: context)
            pending.forEach { coordinator.enqueue($0, context: context) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct LearningLevelBadge: View {
    let level: Int
    private var color: Color {
        switch level {
        case 1: .orange
        case 2: .blue
        case 3: .purple
        default: .green
        }
    }
    var body: some View {
        Text("\(level) · \(LearningLevel.title(level))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityLabel("Level \(level), \(LearningLevel.title(level))")
    }
}

/// A snapshot calculated during rendering; deliberately has no timer or TimelineView.
private struct PhraseCooldownLabel: View {
    let entry: DictionaryEntry

    var body: some View {
        if entry.learningLevel < 4 {
            if let remaining = LearningCooldown.remainingTime(entry) {
                Label(remaining > 0
                      ? "Repeat in \(LearningCooldown.remainingDescription(seconds: remaining))"
                      : "Ready to repeat",
                      systemImage: remaining > 0 ? "clock" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictionary.cooldown")
            } else {
                Label("Cooldown pending", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
