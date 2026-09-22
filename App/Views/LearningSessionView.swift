import SwiftData
import SwiftUI

struct LearningSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query private var allEntries: [DictionaryEntry]
    @Query private var sourceItems: [LearningItem]
    @State private var selection: LearningRoundSelection = .ten
    @State private var round: LearningRoundState?
    @State private var revealed = false
    @State private var errorMessage: String?
    @State private var editingEntry: DictionaryEntry?
    @State private var detailEntry: DictionaryEntry?
    @State private var translationDraft = ""
    @State private var playback = PlaybackController()
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?

    private var eligibleEntries: [DictionaryEntry] { allEntries.filter(\.isLearningEligible) }
    private var current: DictionaryEntry? {
        guard let id = round?.currentID else { return nil }
        return allEntries.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let round, round.isComplete {
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
            .navigationTitle("Learn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { closeAndDismiss() }
                }
            }
            .alert("Could not save progress", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") {} } message: { Text(errorMessage ?? "") }
        }
        .sheet(item: $editingEntry) { entry in editingView(entry) }
        .sheet(item: $detailEntry) { entry in DictionaryEntryDetailView(entry: entry) }
        .onDisappear { closeAudio() }
    }

    private var setupView: some View {
        Form {
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
                LabeledContent("This round", value: "\(selection.count(available: eligibleEntries.count))")
                Text("A round uses a fixed set. Wrong answers return to the end until answered correctly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Start round", systemImage: "play.fill") { startRound() }
                    .buttonStyle(.borderedProminent)
                    .disabled(eligibleEntries.isEmpty)
                    .accessibilityIdentifier("learn.start")
                if eligibleEntries.isEmpty {
                    Text("Add or translate more dictionary entries to start practising.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func questionView(_ entry: DictionaryEntry, round: LearningRoundState) -> some View {
        ScrollView {
            VStack(spacing: 24) {
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

                Text(entry.translationText ?? "")
                    .font(.largeTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("learn.translation")
                CopyButton(value: entry.translationText ?? "", label: "Copy translation",
                           identifier: "learn.copy-translation")
                Button("Edit translation", systemImage: "pencil") {
                    closeAudio()
                    translationDraft = entry.translationText ?? ""
                    editingEntry = entry
                }
                .font(.caption)
                .accessibilityIdentifier("learn.edit")

                if revealed {
                    Divider()
                    Text(entry.text)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("learn.original")
                    CopyButton(value: entry.text, label: "Copy original",
                               identifier: "learn.copy-original")
                    phraseAudio(for: entry)
                    if let contextText = entry.contextText {
                        Text(highlightedContext(contextText, entry: entry))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("learn.source-context")
                        CopyButton(value: contextText, label: "Copy source context",
                                   identifier: "learn.copy-source-context")
                    }
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
    }

    private func completionView(_ round: LearningRoundState) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                Image(systemName: round.skippedIDs.isEmpty ? "checkmark.circle.fill" : "flag.checkered")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text(round.skippedIDs.isEmpty ? "Round complete" : "Round finished").font(.title)
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
        closeAudio()
        var seen = Set<UUID>()
        let snapshot = eligibleEntries.map(\.id).filter { seen.insert($0).inserted }.shuffled()
        let count = selection.count(available: snapshot.count)
        round = LearningRoundState(selection: selection,
                                   selectedIDs: Array(snapshot.prefix(count)))
        revealed = false
    }

    private func answer(_ entry: DictionaryEntry, presentationID: UUID, right: Bool) {
        guard revealed, var updatedRound = round else { return }
        closeAudio()
        guard entry.isLearningEligible else {
            skipCurrent(id: entry.id, presentationID: presentationID)
            return
        }
        do {
            let accepted = try LearningAnswerTransaction.apply(
                entry: entry, round: &updatedRound,
                expectedEntryID: entry.id, presentationID: presentationID,
                right: right, save: { try context.save() }
            )
            guard accepted else { return }
            round = updatedRound
            revealed = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func skipCurrent(id: UUID, presentationID: UUID) {
        guard var updated = round else { return }
        closeAudio()
        guard updated.skip(entryID: id, presentationID: presentationID) else { return }
        round = updated
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
        let value = translationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
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
