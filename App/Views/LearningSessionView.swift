import SwiftData
import SwiftUI

struct LearningSessionView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sourceLanguage: String
    var quickStart = false
    init(sourceLanguage: String = UserDefaults.standard.string(forKey: SourceLanguage.activeKey) ?? "pl", quickStart: Bool = false) {
        _sourceLanguage = State(initialValue: SourceLanguage.canonical(sourceLanguage))
        self.quickStart = quickStart
    }
    @State private var didQuickStart = false
    @State private var initialLevels: [UUID: Int] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.contextAnalysisService) private var contextAnalysisService
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query private var storedEntries: [DictionaryEntry]
    private var allEntries: [DictionaryEntry] {
        SourceLanguage.entries(storedEntries, language: sourceLanguage)
    }
    @Query private var sourceItems: [LearningItem]
    @State private var contextual = ContextualTranslationCoordinator()
    @State private var ignoreCooldown = false
    @State private var selection: LearningRoundSelection = .ten
    @State private var round: LearningRoundState?
    @State private var previewRound: LearningPreviewState?
    @State private var recoveryMessage: String?
    @State private var savedRound: LearningRoundState?
    @State private var confirmingClose = false
    @State private var revealed = false
    @State private var pendingUndo: LearningAnswerUndo?
    @State private var errorMessage: String?
    @State private var editingEntry: DictionaryEntry?
    @State private var detailEntry: DictionaryEntry?
    @State private var translationDraft = ""
    @State private var playback = PlaybackController()
    @State private var audioMode: PhraseAudioMode = .selection
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?

    private var eligibleEntries: [DictionaryEntry] { allEntries.filter { $0.isLearningEligible && (ignoreCooldown || LearningCooldown.isReady($0)) } }
    private var roundPool: [DictionaryEntry] {
        LearningRoundPool.entries(from: allEntries, limit: selection.count(available: eligibleEntries.count), ignoreCooldown: ignoreCooldown)
    }
    private var current: DictionaryEntry? {
        guard let id = previewRound?.currentID ?? round?.currentID else { return nil }
        return allEntries.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let previewRound {
                    if let current, current.isLearningEligible {
                        questionView(current, round: nil, preview: previewRound)
                    } else if let missingID = previewRound.currentID {
                        ProgressView().task(id: previewRound.currentPresentationID) {
                            skipPreview(id: missingID, presentationID: previewRound.currentPresentationID)
                        }
                    }
                } else if let round, round.isComplete || round.selectedIDs.isEmpty {
                    completionView(round)
                } else if let round {
                    if let current, current.isLearningEligible {
                        questionView(current, round: round)
                    } else if let missingID = round.currentID {
                        ProgressView().task(id: round.currentPresentationID) {
                            skipCurrent(id: missingID, presentationID: round.currentPresentationID)
                        }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in setupView }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pendingUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undoAnswer)
                        .nativePrimaryAction()
                        .accessibilityIdentifier("learn.undo")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                        .task(id: pendingUndo.id) {
                            do {
                                try await Task.sleep(for: .seconds(max(0, pendingUndo.expiresAt.timeIntervalSinceNow)))
                                if self.pendingUndo?.id == pendingUndo.id { self.pendingUndo = nil }
                            } catch { }
                        }
                }
            }
            .background(NativeDesign.page)
            .navigationTitle("\(AppLanguage.text(previewRound == nil ? "Learn" : "Preview")) · \(SourceLanguage.name(for: sourceLanguage))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if round?.canResume == true { confirmingClose = true }
                        else { closeAndDismiss() }
                    }
                }
            }
            .alert("Could not save progress", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") {} } message: { Text(AppLanguage.text(errorMessage ?? "")) }
        }
        .task {
            savedRound = LearningRoundCheckpoint.load(language: sourceLanguage, entries: storedEntries)
            recoveryMessage = UserDefaults.standard.string(forKey: LearningRoundCheckpoint.recoveryKey)
            UserDefaults.standard.removeObject(forKey: LearningRoundCheckpoint.recoveryKey)
            do { try LearningCooldown.backfill(allEntries, save: { try context.save() }) }
            catch { errorMessage = error.localizedDescription }
            if quickStart && !didQuickStart {
                didQuickStart = true
                if !eligibleEntries.isEmpty { startRound() }
            }
        }
        .interactiveDismissDisabled()
        .alert("Close training?", isPresented: $confirmingClose) {
            Button("Save and close") { closeAndDismiss() }
            Button("Keep learning", role: .cancel) {}
        } message: {
            Text("Your answers and word levels are saved. You can continue this round later.")
        }
        .sheet(item: $editingEntry) { entry in editingView(entry) }
        .sheet(item: $detailEntry) { entry in DictionaryEntryDetailView(entry: entry) }
        .onChange(of: previewRound?.currentPresentationID ?? round?.currentPresentationID) { _, _ in contextual.cancelCurrentRequest() }
        .onDisappear {
            pendingUndo = nil
            closeAudio()
            contextual.cancelCurrentRequest()
        }
    }

    private var setupView: some View {
        Form {
            LabeledContent("Source language", value: SourceLanguage.name(for: sourceLanguage))
            if let recoveryMessage { Text(AppLanguage.text(recoveryMessage)).foregroundStyle(.secondary) }
            if let savedRound {
                Section("Unfinished round") {
                    Text(AppLanguage.format("Completed %d of %d", savedRound.rightAttemptCount, savedRound.totalSelectedCount))
                    Button("Continue learning") {
                        selection = savedRound.selection
                        round = savedRound
                        self.savedRound = nil
                        revealed = false
                    }
                    .accessibilityIdentifier("learn.resume")
                    Text("Starting a new round replaces the saved round. Previously earned levels are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Round size") {
                Picker("Phrases", selection: $selection) {
                    ForEach(LearningRoundSelection.allCases) { option in
                        Text(AppLanguage.text(option.title)).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("Phrase cooldown") {
                Toggle(isOn: $ignoreCooldown) {
                    Text("Ignore words cooldown")
                }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("learn.ignore-cooldown")
                Text("Cooldown intervals can be changed in Practice settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Available") {
                LabeledContent("Eligible phrases", value: "\(eligibleEntries.count)")
                LabeledContent("This round", value: "\(selection.count(available: roundPool.count))")
                if let level = roundPool.first?.learningLevel {
                    LabeledContent("Current level", value: "\(level)")
                }
                DisclosureGroup("How practice works") {
                    Text("Preview phrases first. Practice starts at the lowest available level; wrong answers return to the queue. After Check, swipe left for Right or right for Wrong. Undo is available for 3 seconds.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(action: startRound) {
                    Label("Start round", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .nativePrimaryAction()
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(eligibleEntries.isEmpty)
                .accessibilityIdentifier("learn.start")
            } footer: {
                if eligibleEntries.isEmpty {
                    Text("No phrases are ready. Wait for cooldown, enable Ignore words cooldown, or add translated entries.")
                }
            }
        }
    }

    private func questionView(_ entry: DictionaryEntry, round: LearningRoundState?,
                              preview: LearningPreviewState? = nil) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                if let preview {
                    VStack(spacing: 4) {
                        Text(AppLanguage.format("Preview %d of %d", preview.reviewedCount + 1, preview.selectedIDs.count))
                            .font(.headline)
                            .accessibilityIdentifier("learn.preview-progress")
                        Text("Choose which phrases to practise before learning starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let round {
                    VStack(spacing: 4) {
                        Text(AppLanguage.format("Completed %d of %d", round.rightAttemptCount, round.totalSelectedCount))
                            .font(.headline)
                            .accessibilityIdentifier("learn.completed")
                        Text(AppLanguage.format("Wrong attempts: %d", round.wrongAttemptCount))
                            .font(.caption).foregroundStyle(.secondary)
                        if !round.skippedIDs.isEmpty {
                            Text(AppLanguage.format("Skipped: %d", round.skippedIDs.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 16) {
                    Text(entry.translationText ?? "")
                        .font(.largeTitle)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("learn.translation")
                    Button {
                        closeAudio()
                        translationDraft = entry.translationText ?? ""
                        editingEntry = entry
                    } label: {
                        Image(systemName: "pencil")
                            .font(.title2.weight(.medium))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit translation")
                    .accessibilityIdentifier("learn.edit")
                }

                if revealed || (preview != nil && entry.learningLevel == 1) {
                    Divider()
                    HStack(alignment: .center, spacing: 16) {
                        Text(entry.text)
                            .font(.title2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("learn.original")
                        CopyButton(value: entry.text, label: "Copy original",
                                   identifier: "learn.copy-original")
                    }
                    phraseAudio(for: entry)
                    if let contextText = entry.contextText {
                        Text(highlightedContext(contextText, entry: entry))
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("learn.source-context")
                    }
                    contextTranslation(for: entry)
                    if let round {
                        HStack(spacing: 20) {
                            Button("Wrong", systemImage: "xmark.circle") {
                                answer(entry, presentationID: round.currentPresentationID, right: false)
                            }
                            .nativeSecondaryAction().tint(.red)
                            .accessibilityIdentifier("learn.wrong")
                            Button("Right", systemImage: "checkmark.circle") {
                                answer(entry, presentationID: round.currentPresentationID, right: true)
                            }
                            .nativePrimaryAction()
                            .accessibilityIdentifier("learn.right")
                        }
                    }
                } else {
                    Button { revealed = true } label: {
                        Text("Check").frame(maxWidth: .infinity)
                    }
                        .nativePrimaryAction()
                        .accessibilityIdentifier("learn.check")
                }
                if let preview, dynamicTypeSize.isAccessibilitySize,
                   revealed || entry.learningLevel == 1 {
                    previewActions(entry, preview: preview)
                }
            }
            .frame(maxWidth: 620)
            .padding(24)
            .background(NativeDesign.surface, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(NativeDesign.page)
        .modifier(LearningSwipeModifier(enabled: preview == nil && revealed && round != nil) { right in
            guard let round else { return }
            answer(entry, presentationID: round.currentPresentationID, right: right)
        })
        .id(preview?.currentPresentationID ?? round?.currentPresentationID)
        .safeAreaInset(edge: .bottom) {
            if let preview, !dynamicTypeSize.isAccessibilitySize,
               revealed || entry.learningLevel == 1 {
                previewActions(entry, preview: preview)
            }
        }
    }

    private func previewActions(_ entry: DictionaryEntry, preview: LearningPreviewState) -> some View {
        VStack(spacing: 10) {
            Button { previewAction(entry, preview: preview, action: .startLearning) } label: {
                Text("Start learning").frame(maxWidth: .infinity)
            }
                .nativePrimaryAction()
                .accessibilityIdentifier("learn.preview-learn")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button { previewAction(entry, preview: preview, action: .moveToNextLevel) } label: {
                    Text("Move to next level").frame(maxWidth: .infinity)
                }
                .nativeSecondaryAction()
                .accessibilityIdentifier("learn.preview-next-level")
                Button { previewAction(entry, preview: preview, action: .markAsKnown) } label: {
                    Text("Mark as known").frame(maxWidth: .infinity)
                }
                .nativeSecondaryAction()
                .accessibilityIdentifier("learn.preview-known")
            }
            Button("Skip") { previewAction(entry, preview: preview, action: .skip) }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityIdentifier("learn.preview-skip")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .nativeFloatingSurface()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func contextTranslation(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meaning in context").font(.headline)
            if let explanation = entry.contextTranslationText, !explanation.isEmpty {
                Text("Word explanations").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("learn.context-words")
                ContextWordExplanationView(explanation: explanation, selectedText: entry.text,
                    context: entry.contextText.flatMap { text in
                        guard let location = entry.contextSelectionLocation,
                              let length = entry.contextSelectionLength else { return nil }
                        return SelectionContext(text: text, selection: NSRange(location: location, length: length))
                    }, sourceLanguage: entry.sourceLanguageCode, targetLanguage: entry.targetLanguageCode)
            }
            if let candidate = entry.contextSelectedTranslationText, !candidate.isEmpty {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Overall translation").font(.caption).foregroundStyle(.secondary)
                        Text(candidate)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("learn.context-translation")
                    }
                    Spacer()
                    if candidate != entry.translationText {
                        Button("Use this as translation") {
                            saveTranslation(entry, value: candidate)
                        }
                        .nativeSecondaryAction()
                        .accessibilityIdentifier("learn.use-context-translation")
                    }
                }
            }
            if contextual.status == .translatingContext {
                HStack { ProgressView(); Text("Generating context translation…") }
            } else {
                if case .failed(let message) = contextual.status {
                    Text(AppLanguage.text(message)).foregroundStyle(.red)
                }
                if entry.contextTranslationText == nil || entry.contextSelectedTranslationText == nil
                    || contextual.status != .idle {
                    Button("Generate context translation", systemImage: "character.book.closed") {
                        contextual.translateContext(for: entry, context: context,
                                                    service: contextAnalysisService,
                                                    allowPhraseFallback: true)
                    }
                    .accessibilityIdentifier("learn.generate-context")
                    if ContextSentenceExtractor.sentence(for: entry) == nil {
                        Text("No source context is saved. The analysis will use the phrase itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(NativeDesign.surface, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
    }

    private func completionView(_ round: LearningRoundState) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                Image(systemName: round.skippedIDs.isEmpty ? "checkmark.circle.fill" : "flag.checkered")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text(AppLanguage.text(round.selectedIDs.isEmpty ? "Preview complete" : (round.skippedIDs.isEmpty ? "Round complete" : "Round finished"))).font(.title)
                if round.selectedIDs.isEmpty {
                    Text("No phrases selected for learning. Your level changes have been saved.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 5) {
                    LabeledContent("Selected size", value: round.selection.title)
                    LabeledContent("Phrases selected", value: "\(round.totalSelectedCount)")
                    LabeledContent("Completed", value: "\(round.rightAttemptCount)")
                    LabeledContent("Wrong attempts", value: "\(round.wrongAttemptCount)")
                    if !round.skippedIDs.isEmpty {
                        LabeledContent("Skipped", value: "\(round.skippedIDs.count)")
                    }
                }
                .frame(maxWidth: 500)

                HStack {
                    Button("Repeat") { startRound() }
                        .nativeSecondaryAction()
                        .disabled(eligibleEntries.isEmpty)
                    Button("Change round size") {
                        closeAudio()
                        pendingUndo = nil
                        self.round = nil
                        revealed = false
                    }
                    .nativeSecondaryAction()
                }

                Divider().padding(.vertical, 4)
                Text("Round results").font(.title2.bold())
                let levels = round.initialLevels ?? [:]
                let resultIDs = Set(round.selectedIDs).union(levels.keys)
                let learnt = allEntries.filter { resultIDs.contains($0.id) }
                if learnt.isEmpty {
                    Text("No phrases in this round").foregroundStyle(.secondary)
                } else {
                    ForEach(learnt) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                closeAudio()
                                detailEntry = entry
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                if let previous = levels[entry.id] {
                                    Text("\(previous) → \(entry.learningLevel)")
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(previous == entry.learningLevel ? Color.secondary : entry.learningLevel > previous ? Color.green : Color.orange)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                        .accessibilityLabel(AppLanguage.format("Level %d to %d", previous, entry.learningLevel))
                                        .accessibilityIdentifier("learn.completion.level-transition")
                                }
                                Text(entry.text)
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("learn.completion.original")
                                Text(entry.translationText ?? "")
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("learn.completion.translation")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            HStack {
                                CopyButton(value: entry.text, label: "Copy original",
                                           identifier: "learn.completion.copy-original")
                                CopyButton(value: entry.translationText ?? "",
                                           label: "Copy translation",
                                           identifier: "learn.completion.copy-translation")
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NativeDesign.surface, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
                    }
                }
                Button("Finish") { closeAndDismiss() }.nativePrimaryAction()
            }
            .padding()
        }
    }

    private func phraseAudio(for entry: DictionaryEntry) -> some View {
        let mode: PhraseAudioMode = entry.phraseAudioStart == nil ? .selection : audioMode
        let source = PhraseAudioSourceResolver.resolve(entry: entry, items: sourceItems, mode: mode)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let source {
                    PhraseAudioEditButton(entry: entry, items: sourceItems, source: source,
                                          stopPlayback: { playback.pause() }, mode: mode)
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("learn.edit-audio")
                }
            }
            HStack(alignment: .center, spacing: 12) {
                if let source {
                    Button { toggleAudio(source) } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(playback.isPlaying ? source.pauseLabel : source.playLabel)
                    .accessibilityIdentifier("learn.play-audio")
                }
                if entry.phraseAudioStart != nil {
                    Menu {
                        Picker("Audio fragment", selection: $audioMode) {
                            ForEach(PhraseAudioMode.allCases) { mode in Text(AppLanguage.text(mode.title)).tag(mode) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(AppLanguage.text(audioMode.title)).multilineTextAlignment(.leading)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.medium))
                    .accessibilityLabel("Audio fragment")
                    .accessibilityValue(audioMode.title)
                    .accessibilityIdentifier("learn.audio-mode")
                    .onChange(of: audioMode) { _, _ in closeAudio() }
                } else if source != nil {
                    Text("Phrase audio").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if source != nil { PlaybackRateMenu(playback: playback, compact: true) }
            }
            if source == nil {
                Label("Audio unavailable on this device", systemImage: "speaker.slash")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learn.audio-panel")
    }

    private func editingView(_ entry: DictionaryEntry) -> some View {
        NavigationStack {
            Form {
                Section("Original") { Text(entry.text) }
                Section("Russian translation") {
                    TextEditor(text: $translationDraft).frame(minHeight: 120)
                }
            }
            .navigationTitle("Edit translation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingEntry = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTranslation(entry) }
                        .disabled(translationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func startRound() {
        LearningRoundCheckpoint.save(nil, language: sourceLanguage)
        savedRound = nil
        closeAudio()
        pendingUndo = nil
        let pool = roundPool
        initialLevels = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.learningLevel) })
        let snapshot = pool.map(\.id)
        round = nil
        updatePreview(LearningPreviewState(selection: selection,
                                           selectedIDs: snapshot, sourceLanguage: sourceLanguage))
        revealed = false
    }

    private func previewAction(_ entry: DictionaryEntry, preview: LearningPreviewState,
                               action: LearningPreviewAction) {
        guard var updated = previewRound else { return }
        closeAudio()
        do {
            guard try LearningPreviewTransaction.apply(entry: entry, preview: &updated,
                presentationID: preview.currentPresentationID, action: action,
                save: { try context.save() }) else { return }
            updatePreview(updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func skipPreview(id: UUID, presentationID: UUID) {
        guard var updated = previewRound else { return }
        closeAudio()
        guard updated.advance(entryID: id, presentationID: presentationID, learn: false) else { return }
        updatePreview(updated)
    }

    private func updatePreview(_ updated: LearningPreviewState) {
        contextual.cancelCurrentRequest()
        revealed = false
        if updated.isComplete {
            round = LearningRoundState(selection: updated.selection, selectedIDs: updated.learningIDs, sourceLanguage: sourceLanguage)
            round?.initialLevels = initialLevels
            previewRound = nil
        } else {
            previewRound = updated
        }
    }

    private func answer(_ entry: DictionaryEntry, presentationID: UUID, right: Bool) {
        guard previewRound == nil, revealed, var updatedRound = round else { return }
        closeAudio()
        guard entry.isLearningEligible else {
            skipCurrent(id: entry.id, presentationID: presentationID)
            return
        }
        let previousRound = updatedRound
        let previousLevel = entry.learningLevel
        let previousDate = entry.levelChangedAt
        do {
            let accepted = try LearningAnswerTransaction.apply(
                entry: entry, round: &updatedRound,
                expectedEntryID: entry.id, presentationID: presentationID,
                right: right, save: { try context.save() }
            )
            guard accepted else { return }
            pendingUndo = LearningAnswerUndo(entryID: entry.id, previousLevel: previousLevel,
                savedLevel: entry.learningLevel, previousRound: previousRound,
                answeredRound: updatedRound, expiresAt: .now.addingTimeInterval(3),
                previousLevelChangedAt: previousDate, savedLevelChangedAt: entry.levelChangedAt)
            round = updatedRound
            LearningRoundCheckpoint.save(updatedRound)
            revealed = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undoAnswer() {
        guard let undo = pendingUndo, var restored = round,
              let entry = allEntries.first(where: { $0.id == undo.entryID }) else {
            pendingUndo = nil
            return
        }
        do {
            guard try undo.restore(entry: entry, round: &restored,
                                   save: { try context.save() }) else {
                pendingUndo = nil
                return
            }
            closeAudio()
            contextual.cancelCurrentRequest()
            round = restored
            LearningRoundCheckpoint.save(restored)
            revealed = true
            pendingUndo = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func skipCurrent(id: UUID, presentationID: UUID) {
        guard var updated = round else { return }
        closeAudio()
        guard updated.skip(entryID: id, presentationID: presentationID) else { return }
        pendingUndo = nil
        round = updated
        LearningRoundCheckpoint.save(updated)
        revealed = false
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

    private func closeAudio() {
        playback.close()
        openedAudioIdentity = nil
    }

    private func closeAndDismiss() {
        closeAudio()
        dismiss()
    }

    private func highlightedContext(_ text: String, entry: DictionaryEntry) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .secondary
        guard let location = entry.contextSelectionLocation,
              let length = entry.contextSelectionLength,
              let stringRange = Range(NSRange(location: location, length: length), in: text),
              let range = Range(stringRange, in: result) else { return result }
        result[range].backgroundColor = .yellow.opacity(0.35)
        result[range].foregroundColor = .primary
        result[range].font = .body.bold()
        return result
    }

    private func saveTranslation(_ entry: DictionaryEntry) {
        saveTranslation(entry, value: translationDraft)
    }

    private func saveTranslation(_ entry: DictionaryEntry, value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let previousText = entry.translationText
        let previousOrigin = entry.translationOrigin
        let previousRevision = entry.translationRevision
        let previousUpdatedAt = entry.translationUpdatedAt
        let previousStatus = entry.translationStatus
        translationCoordinator.cancel(entry.id)
        entry.translationText = value
        entry.translationOrigin = .manual
        entry.translationRevision += 1
        entry.translationUpdatedAt = .now
        entry.translationStatus = .ready
        do {
            try context.save()
            editingEntry = nil
        } catch {
            entry.translationText = previousText
            entry.translationOrigin = previousOrigin
            entry.translationRevision = previousRevision
            entry.translationUpdatedAt = previousUpdatedAt
            entry.translationStatus = previousStatus
            errorMessage = error.localizedDescription
        }
    }
}
