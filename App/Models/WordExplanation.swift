import Foundation

struct WordExplanation: Codable, Equatable, Sendable {
    struct Example: Codable, Equatable, Sendable {
        let phrase: String
        let translation: String
    }
    let definition: String
    let meaningInContext: String
    let examples: [Example]

    func validated() throws -> Self {
        func valid(_ text: String, limit: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= limit
        }
        guard valid(definition, limit: 1_200), valid(meaningInContext, limit: 700),
              (1...2).contains(examples.count), examples.allSatisfy({
                  valid($0.phrase, limit: 300) && valid($0.translation, limit: 400)
              }) else { throw ContextAnalysisError.invalidOutput }
        return self
    }
}

struct WordExplanationInput: Codable, Hashable, Sendable {
    let sourceWord: String
    let lemma: String
    let context: String
    let selectionLocationUTF16: Int
    let selectionLengthUTF16: Int
    let sourceLanguage: String
    let targetLanguage: String
}

struct ContextWordRow: Identifiable, Equatable, Sendable {
    let id: Int
    let sourceWord: String
    let lemma: String
    let meaning: String
    let input: WordExplanationInput
}

enum ContextWordRows {
    /// Decode the existing persisted breakdown conservatively. Legacy/free-form results stay readable.
    static func build(explanation: String, selectedText: String, context: SelectionContext?,
                      sourceLanguage: String, targetLanguage: String) -> [ContextWordRow]? {
        guard let phrase = try? ContextAnalysisRequestBuilder.build(.init(
            subject: .preview(UUID()), revision: 0, expectedSelectedText: selectedText,
            context: context ?? SelectionContext(text: selectedText,
                selection: NSRange(location: 0, length: selectedText.utf16.count)),
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
            promptVersion: OpenAIWordExplanationProvider.promptVersion
        )), let phraseRange = Range(NSRange(location: phrase.selectionLocationUTF16,
                                            length: phrase.selectionLengthUTF16), in: phrase.contextFragment)
        else { return nil }
        let words = phrase.contextFragment[phraseRange].split(whereSeparator: \.isWhitespace).filter {
            !ContextAnalysisWords.wordsToExplain(in: String($0), language: sourceLanguage).isEmpty
        }
        let lines = explanation.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard words.count == lines.count, !words.isEmpty else { return nil }
        var rows: [ContextWordRow] = []
        for (index, pair) in zip(words, lines).enumerated() {
            let parts = pair.1.components(separatedBy: " — ")
            guard parts.count >= 3, parts[0] == String(pair.0), !parts[1].isEmpty else { return nil }
            let meaning = parts.dropFirst(2).joined(separator: " — ")
            guard !meaning.isEmpty else { return nil }
            let range = NSRange(pair.0.startIndex..<pair.0.endIndex, in: phrase.contextFragment)
            rows.append(.init(id: index, sourceWord: parts[0], lemma: parts[1], meaning: meaning,
                input: .init(sourceWord: parts[0], lemma: parts[1], context: phrase.contextFragment,
                             selectionLocationUTF16: range.location, selectionLengthUTF16: range.length,
                             sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)))
        }
        return rows
    }
}
