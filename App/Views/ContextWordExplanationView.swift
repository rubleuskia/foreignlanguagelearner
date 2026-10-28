import SwiftUI

/// The same inline disclosure is used by selection previews, dictionary details and learning.
struct ContextWordExplanationView: View {
    let explanation: String
    let selectedText: String
    let context: SelectionContext?
    let sourceLanguage: String
    let targetLanguage: String
    @State private var expandedWord: Int?
    @State private var preparedInput: Input?
    @State private var rows: [ContextWordRow]?

    private struct Input: Equatable, Sendable {
        let explanation: String
        let selectedText: String
        let context: SelectionContext?
        let sourceLanguage: String
        let targetLanguage: String
    }
    private var input: Input {
        .init(explanation: explanation, selectedText: selectedText, context: context,
              sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    var body: some View {
        Group {
            if preparedInput != input {
                ProgressView()
            } else if let rows {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.vertical, 6) }
                        ContextWordDisclosure(row: row, isExpanded: Binding(
                            get: { expandedWord == row.id },
                            set: { expandedWord = $0 ? row.id : nil }
                        ))
                        .id(row.input)
                    }
                    Text("Tap a word to explore its meaning.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                }
            } else {
                Text(explanation).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: input) {
            let snapshot = input
            let worker = Task.detached(priority: .userInitiated) {
                ContextWordRows.build(explanation: snapshot.explanation, selectedText: snapshot.selectedText,
                    context: snapshot.context, sourceLanguage: snapshot.sourceLanguage,
                    targetLanguage: snapshot.targetLanguage)
            }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            rows = value
            expandedWord = nil
            preparedInput = snapshot
        }
    }
}

private struct ContextWordDisclosure: View {
    @Environment(\.wordExplanationService) private var service
    let row: ContextWordRow
    @Binding var isExpanded: Bool
    @State private var result: WordExplanation?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(row.lemma) — \(row.meaning)")
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.sourceWord), \(row.lemma), \(row.meaning)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide a detailed explanation and example sentences")
            .accessibilityIdentifier("word-explanation.toggle.\(row.id)")
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if row.sourceWord != row.lemma {
                        Text("\(row.sourceWord) → \(row.lemma)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let result {
                        block("Простыми словами", text: result.definition)
                        block("Здесь", text: result.meaningInContext)
                        Text("Примеры предложений").font(.subheadline.weight(.semibold))
                        ForEach(result.examples.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.examples[index].phrase)
                                Text(result.examples[index].translation)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                        }
                    } else if let error {
                        Text(AppLanguage.text(error)).font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry", systemImage: "arrow.clockwise") { retry += 1 }
                            .buttonStyle(.borderless)
                    } else {
                        HStack { ProgressView(); Text("Explaining word…").font(.subheadline) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("word-explanation.details.\(row.id)")
                .task(id: retry) { await load() }
            }
        }
    }

    private func block(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func load() async {
        guard result == nil else { return }
        error = nil
        do {
            let value = try await service.explain(row.input)
            try Task.checkCancellation()
            result = value
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? ContextAnalysisError ?? .unknown).userMessage
        }
    }
}
