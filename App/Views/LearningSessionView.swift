import SwiftData
import SwiftUI

struct LearningSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.contextAnalysisService) private var contextAnalysisService
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query private var allEntries: [DictionaryEntry]
    @Query private var sourceItems: [LearningItem]
    @State private var contextual = ContextualTranslationCoordinator()
    @State private var selection: LearningRoundSelection = .ten
    @State private var round: LearningRoundState?
    @State private var previewRound: LearningPreviewState?
    @State private var savedRound = LearningRoundCheckpoint.load()
    @State private var confirmingClose = false
    @State private var revealed = false
    @State private var pendingUndo: LearningAnswerUndo?
    @State private var errorMessage: String?
    @State private var editingEntry: DictionaryEntry?
    @State private var detailEntry: DictionaryEntry?
    @State private var translationDraft = ""
    @State private var playback = PlaybackController()
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?

    private var eligibleEntries: [DictionaryEntry] { allEntries.filter(\.isLearningEligible) }
    private var roundPool: [DictionaryEntry] { LearningRoundPool.entries(from: allEntries) }
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
                    setupView
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pendingUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undoAnswer)
                        .buttonStyle(.borderedProminent)
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
            .navigationTitle(previewRound == nil ? "Learn" : "Preview")
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
            )) { Button("OK") {} } message: { Text(errorMessage ?? "") }
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
            if let savedRound {
                Section("Unfinished round") {
                    Text("Completed \(savedRound.rightAttemptCount) of \(savedRound.totalSelectedCount)")
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
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Available") {
                LabeledContent("Eligible phrases", value: "\(eligibleEntries.count)")
                LabeledContent("This round", value: "\(selection.count(available: roundPool.count))")
                if let level = roundPool.first?.learningLevel {
                    LabeledContent("Current level", value: "\(level)")
                }
                Text("Practise all phrases at the lowest available level before moving to the next. Preview each phrase first and choose whether to learn it, advance its level, mark it as known or skip it without changes. During learning, wrong answers return to the end until answered correctly. After Check, swipe left for Right or right for Wrong. Undo is available for 3 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(action: startRound) {
                    Label("Start round", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(eligibleEntries.isEmpty)
                .accessibilityIdentifier("learn.start")
            } footer: {
                if eligibleEntries.isEmpty {
                    Text("Add or translate more dictionary entries to start practising.")
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
                        Text("Preview \(preview.reviewedCount + 1) of \(preview.selectedIDs.count)")
                            .font(.headline)
                            .accessibilityIdentifier("learn.preview-progress")
                        Text("Choose which phrases to practise before learning starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let round {
                    VStack(spacing: 4) {
                        Text("Completed \(round.rightAttemptCount) of \(round.totalSelectedCount)")
                            .font(.headline)
                            .accessibilityIdentifier("learn.completed")
                        Text("Wrong attempts: \(round.wrongAttemptCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !round.skippedIDs.isEmpty {
                            Text("Skipped: \(round.skippedIDs.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Text(entry.translationText ?? "")
                    .font(.largeTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("learn.translation")
                HStack {
                    CopyButton(value: entry.translationText ?? "", label: "Copy translation",
                               identifier: "learn.copy-translation")
                    Button("Edit translation", systemImage: "pencil") {
                        closeAudio()
                        translationDraft = entry.translationText ?? ""
                        editingEntry = entry
                    }
                    .font(.caption)
                    .accessibilityIdentifier("learn.edit")
                }

                if revealed || (preview != nil && entry.learningLevel == 1) {
                    Divider()
                    Text(entry.text)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("learn.original")
                    HStack {
                        CopyButton(value: entry.text, label: "Copy original",
                                   identifier: "learn.copy-original")
                        phraseAudio(for: entry)
                    }
                    if let contextText = entry.contextText {
                        Text(highlightedContext(contextText, entry: entry))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("learn.source-context")
                        CopyButton(value: contextText, label: "Copy source context",
                                   identifier: "learn.copy-source-context")
                    }
                    contextTranslation(for: entry)
                    if let round {
                        HStack(spacing: 20) {
                            Button("Wrong", systemImage: "xmark.circle") {
                                answer(entry, presentationID: round.currentPresentationID, right: false)
                            }
                            .buttonStyle(.bordered).tint(.red)
                            .accessibilityIdentifier("learn.wrong")
                            Button("Right", systemImage: "checkmark.circle") {
                                answer(entry, presentationID: round.currentPresentationID, right: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("learn.right")
                        }
                    }
                } else {
                    Button("Check") { revealed = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("learn.check")
                }
            }
            .frame(maxWidth: 700)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .modifier(LearningSwipeModifier(enabled: preview == nil && revealed && round != nil) { right in
            guard let round else { return }
            answer(entry, presentationID: round.currentPresentationID, right: right)
        })
        .id(preview?.currentPresentationID ?? round?.currentPresentationID)
        .safeAreaInset(edge: .bottom) {
            if let preview, revealed || entry.learningLevel == 1 {
                VStack(spacing: 8) {
                    Button("Start learning") { previewAction(entry, preview: preview, action: .startLearning) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("learn.preview-learn")
                    Button("Move to next level") { previewAction(entry, preview: preview, action: .moveToNextLevel) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("learn.preview-next-level")
                    Button("Mark as known") { previewAction(entry, preview: preview, action: .markAsKnown) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("learn.preview-known")
                    Button("Skip") { previewAction(entry, preview: preview, action: .skip) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("learn.preview-skip")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
            }
        }
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
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("learn.use-context-translation")
                    }
                }
            }
            if contextual.status == .translatingContext {
                HStack { ProgressView(); Text("Generating context translation…") }
            } else {
                if case .failed(let message) = contextual.status {
                    Text(message).foregroundStyle(.red)
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func completionView(_ round: LearningRoundState) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                Image(systemName: round.skippedIDs.isEmpty ? "checkmark.circle.fill" : "flag.checkered")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text(round.selectedIDs.isEmpty ? "Preview complete" : (round.skippedIDs.isEmpty ? "Round complete" : "Round finished")).font(.title)
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
                        .buttonStyle(.borderedProminent)
                        .disabled(eligibleEntries.isEmpty)
                    Button("Change round size") {
                        closeAudio()
                        pendingUndo = nil
                        self.round = nil
                        revealed = false
                    }
                    .buttonStyle(.bordered)
                }

                Divider().padding(.vertical, 4)
                Text("All learnt phrases").font(.title2.bold())
                let learnt = LearningCompletion.learntEntries(from: allEntries)
                if learnt.isEmpty {
                    Text("No phrases at level 4 yet").foregroundStyle(.secondary)
                } else {
                    ForEach(learnt) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                closeAudio()
                                detailEntry = entry
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
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
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button("Finish") { closeAndDismiss() }.buttonStyle(.bordered)
            }
            .padding()
        }
    }

    @ViewBuilder private func phraseAudio(for entry: DictionaryEntry) -> some View {
        if let source = PhraseAudioSourceResolver.resolve(entry: entry, items: sourceItems) {
            HStack {
                Button {
                    toggleAudio(source)
                } label: {
                    Label(playback.isPlaying ? "Pause phrase" : "Play phrase",
                          systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                }
                .accessibilityIdentifier("learn.play-audio")
                PlaybackRateMenu(playback: playback)
            }
        } else {
            Label("Audio unavailable on this device", systemImage: "speaker.slash")
                .foregroundStyle(.secondary)
        }
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
        LearningRoundCheckpoint.save(nil)
        savedRound = nil
        closeAudio()
        pendingUndo = nil
        let snapshot = roundPool.map(\.id).shuffled()
        let count = selection.count(available: snapshot.count)
        round = nil
        updatePreview(LearningPreviewState(selection: selection,
                                           selectedIDs: Array(snapshot.prefix(count))))
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
            round = LearningRoundState(selection: updated.selection, selectedIDs: updated.learningIDs)
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
        do {
            let accepted = try LearningAnswerTransaction.apply(
                entry: entry, round: &updatedRound,
                expectedEntryID: entry.id, presentationID: presentationID,
                right: right, save: { try context.save() }
            )
            guard accepted else { return }
            pendingUndo = LearningAnswerUndo(entryID: entry.id, previousLevel: previousLevel,
                savedLevel: entry.learningLevel, previousRound: previousRound,
                answeredRound: updatedRound, expiresAt: .now.addingTimeInterval(3))
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
