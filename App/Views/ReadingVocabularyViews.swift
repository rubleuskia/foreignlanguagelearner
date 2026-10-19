import SwiftUI
import SwiftData

struct ReadingCompletionButton: View {
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    let item: LearningItem
    let scope: ReadingScope
    @State private var proposal: ReadingCompletionProposal?
    @State private var working = false
    @State private var error: String?

    private var completed: Bool { ReadingVocabularyStore.completed(item, scope: scope) }
    private var isBook: Bool { scope == .book }

    var body: some View {
        Button(completed ? (isBook ? "Book read" : "Read") : (isBook ? "Mark whole book read" : "Mark chapter read"),
               systemImage: completed ? "checkmark.circle.fill" : "circle") {
            working = true
            Task {
                defer { working = false }
                do { proposal = try await vocabulary.prepare(item: item, scope: scope) }
                catch { self.error = error.localizedDescription }
            }
        }
        .disabled(completed || working || !vocabulary.ready)
        .accessibilityIdentifier(isBook ? "reader.complete-book" : "reader.complete-chapter")
        .alert(isBook ? "Mark whole book read?" : "Mark chapter read?",
               isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } })) {
            Button("Cancel", role: .cancel) { proposal = nil }
            Button("Mark read") {
                guard let value = proposal else { return }
                proposal = nil; working = true
                Task {
                    defer { working = false }
                    do { try await vocabulary.complete(value, context: context) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .accessibilityIdentifier("reader.confirm-completion")
        } message: {
            if let proposal {
                Text(proposal.hasText
                     ? "\(proposal.added) new unique words will become studied. \(isBook ? "All chapters will be marked read; full text and available subtitles are included. " : "")This cannot be undone. The source language will be locked."
                     : "This chapter has no subtitles. Its words will be counted when you mark the whole book read. This cannot be undone. The source language will be locked.")
            }
        }
        .alert("Could not mark read", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct ReadingVocabularyStatus: View {
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    var body: some View {
        if !vocabulary.ready {
            if let error = vocabulary.errorMessage {
                VStack { Text(error).foregroundStyle(.red); Button("Retry vocabulary update") { Task { await vocabulary.start(context: context) } } }
            } else { ProgressView("Updating reading vocabulary…") }
        }
    }
}

struct VocabularyStatisticsView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    let words: Set<String>?
    let language: String
    var error: String? = nil
    @State private var stats: VocabularyStatistics?
    @State private var totalStudied = 0

    private func update() {
        stats = vocabulary.ready ? words.map { vocabulary.statistics($0, language: language) } : nil
        totalStudied = vocabulary.forms(for: language).count
    }

    var body: some View {
        Group {
            if let error { Text(error).foregroundStyle(.secondary) }
            else if vocabulary.ready, let stats, words != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unique words: \(stats.total) · New: \(stats.new) · Studied: \(stats.known)")
                        .accessibilityIdentifier("vocabulary.statistics")
                    Text("Studied from read texts (\(language)): \(totalStudied)")
                        .accessibilityIdentifier("vocabulary.total")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else { ProgressView("Counting words…").font(.caption) }
        }
        .onAppear { update() }
        .onChange(of: words) { _, _ in update() }
        .onChange(of: language) { _, _ in update() }
        .onChange(of: vocabulary.revision) { _, _ in update() }
        .onChange(of: vocabulary.ready) { _, _ in update() }
    }
}

/// Tokenization is tied to document text, not playback ticks or vocabulary revisions.
struct VocabularyTranscriptView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let document: TranscriptDocument
    let language: String
    let activeSegment: Int?
    @Binding var following: Bool
    let followGeneration: Int
    let onSelectionBegan: () -> Void
    let handleSelection: (TranscriptSelectionAction, String, NSRange, Int?, SelectionContext?) -> Void
    @State private var textIndex: VocabularyTextIndex?
    @State private var indexedText: String?
    @State private var error: String?
    @State private var enabled = true

    var body: some View {
        VStack(spacing: 4) {
            ReadingVocabularyStatus()
            HStack(alignment: .top) {
                VocabularyStatisticsView(words: indexedText == document.text ? textIndex?.uniqueForms : nil, language: language, error: error)
                Spacer()
                Toggle("New words", isOn: $enabled).fixedSize()
                    .font(.caption).accessibilityIdentifier("reader.new-words")
            }.padding(.horizontal)
            TranscriptTextView(document: document, activeSegment: activeSegment, following: $following,
                               followGeneration: followGeneration, onSelectionBegan: onSelectionBegan,
                               wordStyleRevision: vocabulary.revision,
                               differentiateWithoutColor: differentiateWithoutColor,
                               vocabularyIndex: indexedText == document.text && enabled && vocabulary.ready ? textIndex : nil,
                               knownForms: vocabulary.forms(for: language), wordStyleLanguage: language, handleSelection: handleSelection)
        }
        .task(id: document.text) {
            let text = document.text
            error = nil
            let task = Task.detached(priority: .userInitiated) { try VocabularyTextIndex.load(text: text) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                textIndex = result; indexedText = text
            } catch is CancellationError { }
            catch { self.error = "Could not count words: \(error.localizedDescription)" }
        }
    }
}

struct BookVocabularyBadge: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.modelContext) private var context
    let item: LearningItem

    var body: some View {
        Group {
            if let error = vocabulary.bookErrors[item.id] {
                Button("Could not count words · Retry") {
                    Task { await vocabulary.rebuildLibrary((try? context.fetch(FetchDescriptor<LearningItem>())) ?? []) }
                }
                .buttonStyle(.borderless)
                .accessibilityHint(error)
            } else if let summary = vocabulary.bookSummaries[item.id] {
                HStack(spacing: 4) {
                    Text(item.isBookCompleted ? "Words: \(summary.total)" : "New words: \(summary.new)")
                    if vocabulary.summariesUpdating { Text("· Updating…") }
                }
                .accessibilityLabel(item.isBookCompleted ? "Unique word forms: \(summary.total)" : "New unique word forms: \(summary.new)")
            } else {
                Text("Counting words…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.vocabulary.\(item.id)")
    }
}
