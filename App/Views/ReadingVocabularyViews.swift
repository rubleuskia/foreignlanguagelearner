import SwiftUI
import SwiftData

/// Keep confirmation state on the menu itself: transient menu rows cannot
/// present an alert reliably after the system dismisses the menu.
struct ReadingActionsMenu: View {
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    let item: LearningItem
    let chapterScope: ReadingScope?
    @State private var proposal: ReadingCompletionProposal?
    @State private var selectedScope: ReadingScope = .book
    @State private var working = false
    @State private var error: String?

    private var isBook: Bool { selectedScope == .book }

    var body: some View {
        Menu("Complete", systemImage: "checkmark.circle") {
            if let chapterScope { completionAction(chapterScope) }
            completionAction(.book)
        }
        .accessibilityIdentifier("reader.actions")
        .alert(isBook ? "Mark whole book read?" : "Mark chapter read?",
               isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } }),
               presenting: proposal) { value in
            Button("Cancel", role: .cancel) { proposal = nil }
            Button("Mark read") {
                proposal = nil; working = true
                Task {
                    defer { working = false }
                    do { try await vocabulary.complete(value, context: context) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .accessibilityIdentifier("reader.confirm-completion")
        } message: { proposal in
            Text(proposal.hasText
                 ? AppLanguage.format("%d new unique words will become studied. %@This cannot be undone. The source language will be locked.",
                                      proposal.added, isBook ? AppLanguage.text("All chapters will be marked read; full text and available subtitles are included. ") : "")
                 : AppLanguage.text("No text is attached to this selection. Completion will be saved without adding studied words. Adding text later will not mark the new text read. This cannot be undone. The source language will be locked."))
        }
        .alert("Could not mark read", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(AppLanguage.text(error ?? "")) }
    }

    private func completionAction(_ scope: ReadingScope) -> some View {
        let completed = ReadingVocabularyStore.completed(item, scope: scope)
        let book = scope == .book
        return Button(AppLanguage.text(completed ? (book ? "Book read" : "Read") : (book ? "Mark whole book read" : "Mark chapter read")),
                      systemImage: completed ? "checkmark.circle.fill" : "circle") {
            selectedScope = scope
            working = true
            Task {
                defer { working = false }
                do { proposal = try await vocabulary.prepare(item: item, scope: scope) }
                catch { self.error = error.localizedDescription }
            }
        }
        .disabled(completed || working || !vocabulary.ready)
        .accessibilityIdentifier(book ? "reader.complete-book" : "reader.complete-chapter")
    }
}

struct ReadingVocabularyStatus: View {
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    var body: some View {
        if !vocabulary.ready {
            if let error = vocabulary.errorMessage {
                VStack { Text(AppLanguage.text(error)).foregroundStyle(.red); Button("Retry vocabulary update") { Task { await vocabulary.start(context: context) } } }
            } else { ProgressView("Updating reading vocabulary…") }
        }
    }
}

struct VocabularyStatisticsView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    let words: Set<String>?
    let language: String
    var error: String? = nil
    var showsBars = false
    @State private var stats: VocabularyStatistics?
    @State private var totalStudied = 0

    private func update() {
        stats = vocabulary.ready ? words.map { vocabulary.statistics($0, language: language) } : nil
        totalStudied = vocabulary.forms(for: language).count
    }

    var body: some View {
        Group {
            if let error { Text(AppLanguage.text(error)).foregroundStyle(.secondary) }
            else if vocabulary.ready, let stats, words != nil {
                if showsBars {
                    VStack(alignment: .leading, spacing: 16) {
                        BookStatisticBar(title: "New words", count: stats.new, total: stats.total, color: .blue)
                        BookStatisticBar(title: "Saved phrases", count: 0, total: 0, color: .teal)
                        BookStatisticBar(title: "Studied words", count: stats.known, total: stats.total, color: .white)
                        Text(AppLanguage.format("%d unique words", stats.total)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("vocabulary.statistics")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLanguage.format("Unique words: %d · New: %d · Studied: %d", stats.total, stats.new, stats.known))
                            .accessibilityIdentifier("vocabulary.statistics")
                        Text(AppLanguage.format("Studied from read texts (%@): %d", language, totalStudied))
                            .accessibilityIdentifier("vocabulary.total")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
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
    @AppStorage("reader.font-scale") private var fontScale = 1.0
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let document: TranscriptDocument
    let language: String
    let activeSegment: Int?
    @Binding var following: Bool
    let followGeneration: Int
    let onSelectionBegan: () -> Void
    var onFollowAudio: (() -> Void)? = nil
    var initialReadingOffset: Int? = nil
    var onReadingOffsetChanged: ((Int) -> Void)? = nil
    let handleSelection: (TranscriptSelectionAction, String, NSRange, Int?, SelectionContext?) -> Void
    @State private var textIndex: VocabularyTextIndex?
    @State private var indexedText: String?
    @State private var error: String?
    @AppStorage("reader.highlight-new-words") private var enabled = true

    var body: some View {
        VStack(spacing: 0) {
            ReadingVocabularyStatus()
            BookPagedTranscriptView(reader: TranscriptTextView(document: document, activeSegment: activeSegment, following: $following,
                               followGeneration: followGeneration, onSelectionBegan: onSelectionBegan,
                               fontScale: fontScale,
                               wordStyleRevision: vocabulary.revision,
                               differentiateWithoutColor: differentiateWithoutColor,
                               vocabularyIndex: indexedText == document.text && enabled && vocabulary.ready ? textIndex : nil,
                               knownForms: vocabulary.forms(for: language), wordStyleLanguage: language,
                               initialReadingOffset: initialReadingOffset, onReadingOffsetChanged: onReadingOffsetChanged,
                               handleSelection: handleSelection), onFollowAudio: onFollowAudio)
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
                    Text(item.isBookCompleted
                         ? AppLanguage.format("Words: %d", summary.total)
                         : AppLanguage.format("New words: %d", summary.new))
                    if vocabulary.summariesUpdating { Text("· Updating…") }
                }
                .accessibilityLabel(item.isBookCompleted
                    ? AppLanguage.format("Unique word forms: %d", summary.total)
                    : AppLanguage.format("New unique word forms: %d", summary.new))
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
