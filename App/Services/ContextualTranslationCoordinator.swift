import Foundation
import NaturalLanguage
import Observation
import SwiftData
import Translation

struct ContextSentence: Equatable, Sendable {
    let text: String
    let selection: NSRange
}

enum WordSelectionExpander {
    static func expandedRange(in text: String, selection: NSRange) -> NSRange {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= source.length,
              Range(selection, in: text) != nil else { return selection }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var expanded = selection
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = NSRange(range, in: text)
            if NSIntersectionRange(token, selection).length > 0 {
                expanded = NSUnionRange(expanded, token)
            }
            return true
        }
        return expanded
    }
}

enum ContextSentenceExtractor {
    static func sentence(text: String, selection: NSRange) -> ContextSentence? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= source.length else { return nil }

        var start = selection.location
        while start > 0, !isBoundary(source.character(at: start - 1)) { start -= 1 }
        var end = NSMaxRange(selection)
        while end < source.length, !isBoundary(source.character(at: end)) { end += 1 }
        if end < source.length, isSentencePunctuation(source.character(at: end)) { end += 1 }

        let rawRange = NSRange(location: start, length: end - start)
        let raw = source.substring(with: rawRange) as NSString
        let firstContent = raw.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        let leading = firstContent.location == NSNotFound ? raw.length : firstContent.location
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let adjusted = NSRange(location: selection.location - start - leading, length: selection.length)
        guard adjusted.location >= 0, NSMaxRange(adjusted) <= (trimmed as NSString).length else { return nil }
        return ContextSentence(text: trimmed, selection: adjusted)
    }

    static func sentence(for entry: DictionaryEntry) -> ContextSentence? {
        guard let text = entry.contextText,
              let location = entry.contextSelectionLocation,
              let length = entry.contextSelectionLength else { return nil }
        return sentence(text: text, selection: NSRange(location: location, length: length))
    }

    private static func isBoundary(_ character: unichar) -> Bool {
        character == 10 || character == 13 || isSentencePunctuation(character)
    }

    private static func isSentencePunctuation(_ character: unichar) -> Bool {
        character == 46 || character == 33 || character == 63
    }
}

struct BreakdownToken: Equatable, Sendable {
    let text: String
    let isGrammarWord: Bool
}

enum WordBreakdownBuilder {
    static func tokens(in sentence: String, selectedText: String, languageCode: String) -> [BreakdownToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
        let selected = Set(words(in: selectedText, languageCode: languageCode).map(normalized))
        let stopwords = stopwordsByLanguage[languageCode] ?? []
        var result: [BreakdownToken] = []
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            let word = String(sentence[range])
            let key = normalized(word)
            guard key.contains(where: { $0.isLetter }) else { return true }
            result.append(.init(text: word,
                                isGrammarWord: !selected.contains(key) && stopwords.contains(key)))
            return true
        }
        return result
    }

    private static func words(in text: String, languageCode: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]))
            return true
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let stopwordsByLanguage: [String: Set<String>] = [
        "pl": ["a", "aby", "ale", "bo", "by", "czy", "do", "i", "jak", "na", "nie", "o", "od", "oraz", "po", "się", "to", "u", "w", "za", "z", "że"],
        "en": ["a", "an", "and", "as", "at", "but", "by", "for", "if", "in", "of", "on", "or", "the", "to", "with"],
        "de": ["aber", "als", "am", "an", "auf", "das", "der", "die", "ein", "eine", "für", "im", "in", "mit", "oder", "und", "von", "zu"],
        "fr": ["à", "au", "aux", "de", "des", "du", "et", "la", "le", "les", "ou", "pour", "un", "une"],
        "es": ["a", "al", "de", "del", "el", "en", "la", "las", "los", "o", "para", "por", "un", "una", "y"]
    ]
}

enum ContextualTranslationStatus: Equatable {
    case idle
    case needsDownload
    case translatingContext
    case translatingWords
    case failed(String)
}

@MainActor @Observable
final class ContextualTranslationCoordinator {
    private enum Mode: Equatable { case context, words }
    private struct Request {
        let entryID: UUID
        let revision: Int
        let selectedText: String
        let sentence: ContextSentence
        let source: String
        let target: String
        let mode: Mode
        let tokens: [BreakdownToken]
    }

    private(set) var configuration: TranslationSession.Configuration?
    private(set) var status: ContextualTranslationStatus = .idle
    private var request: Request?
    private var modelContext: ModelContext?
    private var contextTask: Task<Void, Never>?

    func translateContext(for entry: DictionaryEntry, context: ModelContext,
                          service: any ContextAnalysisServing) {
        guard let sentence = ContextSentenceExtractor.sentence(for: entry) else {
            status = .failed("No surrounding sentence is available for this entry.")
            return
        }
        guard let contextText = entry.contextText,
              let location = entry.contextSelectionLocation,
              let length = entry.contextSelectionLength else {
            status = .failed(ContextAnalysisError.invalidContext.userMessage)
            return
        }
        contextTask?.cancel()
        modelContext = context
        entry.contextAnalysisRevision += 1
        try? context.save()
        let snapshot = Request(entryID: entry.id, revision: entry.contextAnalysisRevision,
                               selectedText: entry.text, sentence: sentence,
                               source: entry.sourceLanguageCode, target: entry.targetLanguageCode,
                               mode: .context, tokens: [])
        let analysisRequest: ContextAnalysisRequest
        do {
            analysisRequest = try ContextAnalysisRequestBuilder.build(.init(
                subject: .dictionaryEntry(entry.id), revision: snapshot.revision,
                expectedSelectedText: entry.text,
                context: SelectionContext(text: contextText,
                                          selection: NSRange(location: location, length: length)),
                sourceLanguage: entry.sourceLanguageCode,
                targetLanguage: entry.targetLanguageCode,
                promptVersion: OpenAIContextAnalysisProvider.promptVersion
            ))
        } catch let error as ContextAnalysisError {
            status = .failed(error.userMessage)
            return
        } catch {
            status = .failed(ContextAnalysisError.unknown.userMessage)
            return
        }
        request = snapshot
        status = .translatingContext
        contextTask = Task { [weak self] in
            do {
                let result = try await service.analyze(analysisRequest)
                try Task.checkCancellation()
                self?.completeContext(snapshot, selected: result.directTranslation,
                                      explanation: result.contextExplanation)
            } catch is CancellationError {
                self?.cancel(snapshot)
            } catch let error as ContextAnalysisError {
                self?.fail(snapshot, message: error.userMessage)
            } catch {
                self?.fail(snapshot, message: ContextAnalysisError.unknown.userMessage)
            }
        }
    }

    func translateWords(for entry: DictionaryEntry, context: ModelContext) {
        contextTask?.cancel()
        contextTask = nil
        guard let sentence = ContextSentenceExtractor.sentence(for: entry) else {
            status = .failed("No surrounding sentence is available for this entry.")
            return
        }
        let tokens = WordBreakdownBuilder.tokens(in: sentence.text, selectedText: entry.text,
                                                 languageCode: entry.sourceLanguageCode)
        guard !tokens.isEmpty else {
            status = .failed("No words were found in the surrounding sentence.")
            return
        }
        begin(entry: entry, sentence: sentence, mode: .words, tokens: tokens, context: context)
    }

    nonisolated func perform(session: TranslationSession) async {
        guard let request = await currentRequest() else { return }
        do {
            let source = Locale.Language(identifier: request.source)
            let target = Locale.Language(identifier: request.target)
            switch await LanguageAvailability().status(from: source, to: target) {
            case .unsupported:
                await fail(request, message: "This language pair is not supported.")
                return
            case .supported:
                await setStatus(.needsDownload, for: request)
                try await session.prepareTranslation()
            case .installed:
                break
            @unknown default:
                await fail(request, message: "Translation availability could not be determined.")
                return
            }

            switch request.mode {
            case .context:
                return
            case .words:
                await setStatus(.translatingWords, for: request)
                var unique: [String] = []
                for token in request.tokens where !unique.contains(token.text) { unique.append(token.text) }
                let batch = unique.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: batch)
                var translated: [String: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier, let index = Int(identifier),
                          unique.indices.contains(index) else { continue }
                    translated[unique[index]] = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let items = request.tokens.compactMap { token -> WordHelpItem? in
                    guard let value = translated[token.text], !value.isEmpty else { return nil }
                    return WordHelpItem(sourceText: token.text, translationText: value,
                                        isGrammarWord: token.isGrammarWord)
                }
                guard !items.isEmpty else { throw ContextualTranslationError.emptyResult }
                await completeWords(request, items: items)
            }
        } catch is CancellationError {
            await cancel(request)
        } catch {
            await fail(request, message: error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = status { status = .idle }
    }

    func cancelCurrentRequest() {
        contextTask?.cancel()
        contextTask = nil
        request = nil
        status = .idle
    }

    private func begin(entry: DictionaryEntry, sentence: ContextSentence, mode: Mode,
                       tokens: [BreakdownToken], context: ModelContext) {
        modelContext = context
        entry.contextAnalysisRevision += 1
        try? context.save()
        request = Request(entryID: entry.id, revision: entry.contextAnalysisRevision,
                          selectedText: entry.text, sentence: sentence,
                          source: entry.sourceLanguageCode, target: entry.targetLanguageCode,
                          mode: mode, tokens: tokens)
        configuration = QualityTranslationConfiguration.next(previous: configuration,
                                                             source: entry.sourceLanguageCode,
                                                             target: entry.targetLanguageCode)
    }

    private func currentRequest() -> Request? { request }

    private func setStatus(_ value: ContextualTranslationStatus, for request: Request) {
        guard self.request?.revision == request.revision else { return }
        status = value
    }

    private func completeContext(_ request: Request, selected: String, explanation: String) {
        guard let entry = currentEntry(for: request) else { return }
        entry.contextSelectedTranslationText = selected
        entry.contextTranslationText = explanation
        entry.contextAnalysisUpdatedAt = .now
        finish(request)
    }

    private func completeWords(_ request: Request, items: [WordHelpItem]) {
        guard let entry = currentEntry(for: request) else { return }
        var cachedDefinitions: [String: PolishDictionaryResult] = [:]
        for item in entry.wordHelpItems {
            if let result = item.polishDictionaryResult {
                cachedDefinitions[item.sourceText.lowercased()] = result
            }
        }
        entry.wordHelpItems = items.map { item in
            var item = item
            item.polishDictionaryResult = cachedDefinitions[item.sourceText.lowercased()]
            return item
        }
        entry.wordHelpUpdatedAt = .now
        finish(request)
    }

    private func fail(_ request: Request, message: String) {
        guard self.request?.revision == request.revision else { return }
        contextTask = nil
        status = .failed(message)
        self.request = nil
    }

    private func cancel(_ request: Request) {
        guard self.request?.revision == request.revision else { return }
        contextTask = nil
        status = .idle
        self.request = nil
    }

    private func finish(_ request: Request) {
        guard self.request?.revision == request.revision else { return }
        contextTask = nil
        try? modelContext?.save()
        status = .idle
        self.request = nil
    }

    private func currentEntry(for request: Request) -> DictionaryEntry? {
        guard let context = modelContext else { return nil }
        let id = request.entryID
        var descriptor = FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first,
              entry.contextAnalysisRevision == request.revision else { return nil }
        return entry
    }
}

enum QualityTranslationConfiguration {
    static func next(previous: TranslationSession.Configuration?, source: String,
                     target: String) -> TranslationSession.Configuration {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if var previous, previous.source == sourceLanguage, previous.target == targetLanguage {
            previous.invalidate()
            return previous
        }
        if #available(iOS 26.4, *) {
            return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage,
                                                    preferredStrategy: .highFidelity)
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }
}

private enum ContextualTranslationError: LocalizedError {
    case emptyResult
    var errorDescription: String? { "Translation returned no usable text." }
}
