import SwiftUI
import SwiftData

struct LearningSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allEntries: [DictionaryEntry]
    @State private var round: [UUID] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var rightCount = 0
    @State private var wrongCount = 0
    @State private var errorMessage: String?

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
    }

    private func questionView(_ entry: DictionaryEntry) -> some View {
        VStack(spacing: 28) {
            Text("\(index + 1) of \(round.count)").font(.caption).foregroundStyle(.secondary)
            Text(entry.translationText ?? "").font(.largeTitle).multilineTextAlignment(.center)
                .accessibilityIdentifier("learn.translation")
            if revealed {
                Divider()
                Text(entry.text).font(.title2).multilineTextAlignment(.center)
                    .accessibilityIdentifier("learn.original")
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
            index += 1; revealed = false
        } catch {
            entry.learningLevel = old
            errorMessage = error.localizedDescription
        }
    }

    private func skipMissing() { if index < round.count { index += 1; revealed = false } }
}
