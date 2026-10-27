import Foundation
import NaturalLanguage
import Observation
import SwiftData

struct ContextSentence: Equatable, Sendable {
    let text: String
    let selection: NSRange
}

enum WordSelectionExpander {
    static func expandedRange(in text: String, selection: NSRange, language: String? = nil) -> NSRange {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= source.length,
              Range(selection, in: text) != nil else { return selection }

        let tokenizer = NLTokenizer(unit: .word)
        if let language, !language.isEmpty { tokenizer.setLanguage(NLLanguage(rawValue: SourceLanguage.canonical(language))) }
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

enum ContextualTranslationStatus: Equatable {
    case idle
    case translatingContext
    case failed(String)
}

@MainActor @Observable
final class ContextualTranslationCoordinator {
    private struct Request {
        let entryID: UUID
        let revision: Int
    }

    private(set) var status: ContextualTranslationStatus = .idle
    private var request: Request?
    private var modelContext: ModelContext?
    private var contextTask: Task<Void, Never>?

    func translateContext(for entry: DictionaryEntry, context: ModelContext,
                          service: any ContextAnalysisServing, allowPhraseFallback: Bool = false) {
        let savedSentence = ContextSentenceExtractor.sentence(for: entry)
        guard let sentence = savedSentence ?? (allowPhraseFallback
            ? ContextSentence(text: entry.text, selection: NSRange(location: 0, length: (entry.text as NSString).length))
            : nil) else {
            status = .failed("No surrounding sentence is available for this entry.")
            return
        }
        let contextText = savedSentence == nil ? entry.text : (entry.contextText ?? sentence.text)
        let location = savedSentence == nil ? 0 : (entry.contextSelectionLocation ?? 0)
        let length = savedSentence == nil ? (entry.text as NSString).length : (entry.contextSelectionLength ?? 0)
        contextTask?.cancel()
        modelContext = context
        entry.contextAnalysisRevision += 1
        try? context.save()
        let snapshot = Request(entryID: entry.id, revision: entry.contextAnalysisRevision)
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

    func clearError() {
        if case .failed = status { status = .idle }
    }

    func cancelCurrentRequest() {
        contextTask?.cancel()
        contextTask = nil
        request = nil
        status = .idle
    }

    private func completeContext(_ request: Request, selected: String, explanation: String) {
        guard let entry = currentEntry(for: request) else { return }
        let needsBreakdown = !ContextAnalysisWords.wordsToExplain(
            in: entry.text, language: entry.sourceLanguageCode
        ).isEmpty
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !needsBreakdown || !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(request, message: ContextAnalysisError.invalidOutput.userMessage)
            return
        }
        let previous = (entry.contextSelectedTranslationText, entry.contextTranslationText,
                        entry.contextAnalysisUpdatedAt)
        entry.contextSelectedTranslationText = selected
        entry.contextTranslationText = explanation
        entry.contextAnalysisUpdatedAt = .now
        do {
            try modelContext?.save()
            contextTask = nil
            status = .idle
            self.request = nil
        } catch {
            entry.contextSelectedTranslationText = previous.0
            entry.contextTranslationText = previous.1
            entry.contextAnalysisUpdatedAt = previous.2
            fail(request, message: ContextAnalysisError.persistence.userMessage)
            Task { await DiagnosticLog.shared.record(.init(event: "dictionary_save_failed", error: .persistence)) }
        }
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
