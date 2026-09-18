import SwiftUI
import SwiftData

struct LearningSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DictionaryTranslationCoordinator.self) private var translationCoordinator
    @Query private var allEntries: [DictionaryEntry]
    @State private var round: [UUID] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var rightCount = 0
    @State private var wrongCount = 0
    @State private var errorMessage: String?
    @State private var editingEntry: DictionaryEntry?
    @State private var translationDraft = ""

    private var current: DictionaryEntry? {
        guard round.indices.contains(index) else { return nil }
        return allEntries.first { $0.id == round[index] }
    }
    private var complete: Bool { !round.isEmpty && index >= round.count }

    var body: some View {
        NavigationStack {
            Group {
                if round.isEmpty { ContentUnavailableView("No entries to practise", systemImage: "checkmark.circle", description: Text("Add or translate more dictionary entries.")) }
                else if complete { completionView }
                else if let current { questionView(current) }
                else { ProgressView().task { skipMissing() } }
            }
            .padding()
            .navigationTitle("Learn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Could not save progress", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .onAppear { if round.isEmpty { startRound() } }
        .sheet(item: $editingEntry) { entry in
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
    }

    private func questionView(_ entry: DictionaryEntry) -> some View {
        VStack(spacing: 28) {
            Text("\(index + 1) of \(round.count)").font(.caption).foregroundStyle(.secondary)
            Text(entry.translationText ?? "").font(.largeTitle).multilineTextAlignment(.center)
                .accessibilityIdentifier("learn.translation")
            Button("Edit translation", systemImage: "pencil") {
                translationDraft = entry.translationText ?? ""
                editingEntry = entry
            }
            .font(.caption)
            .accessibilityIdentifier("learn.edit")
            if revealed {
                Divider()
                Text(entry.text).font(.title2).multilineTextAlignment(.center)
                    .accessibilityIdentifier("learn.original")
                if let contextText = entry.contextText {
                    Text(highlightedContext(contextText, entry: entry))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("learn.source-context")
                }
                HStack(spacing: 20) {
                    Button("Wrong", systemImage: "xmark.circle") { answer(entry, right: false) }
                        .buttonStyle(.bordered).tint(.red).accessibilityIdentifier("learn.wrong")
                    Button("Right", systemImage: "checkmark.circle") { answer(entry, right: true) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("learn.right")
                }
            } else {
                Button("Check") { revealed = true }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("learn.check")
            }
            Spacer()
        }
    }

    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text("Round complete").font(.title)
            Text("\(rightCount) right · \(wrongCount) wrong").foregroundStyle(.secondary)
            Button("Repeat") { startRound() }.buttonStyle(.borderedProminent)
                .disabled(!allEntries.contains(where: \.isLearningEligible))
            Button("Finish") { dismiss() }.buttonStyle(.bordered)
        }
    }

    private func startRound() {
        round = Array(allEntries.filter(\.isLearningEligible).shuffled().prefix(10).map(\.id))
        index = 0; revealed = false; rightCount = 0; wrongCount = 0
    }

    private func answer(_ entry: DictionaryEntry, right: Bool) {
        let old = entry.learningLevel
        entry.learningLevel = LearningLevel.adjusted(old, correct: right)
        do {
            try context.save()
            if right { rightCount += 1 } else { wrongCount += 1 }
            index = LearningQueue.advance(&round, from: index, correct: right)
            revealed = false
        } catch {
            entry.learningLevel = old
            errorMessage = error.localizedDescription
        }
    }

    private func skipMissing() {
        if index < round.count { index += 1; revealed = false }
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
