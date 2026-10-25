import Foundation
import Observation
import SwiftData

enum SelectionTranslationStatus: Equatable {
    case idle
    case preparing
    case translating
    case ready
    case failed(String)
}

@MainActor @Observable
final class SelectionTranslationCoordinator {
    struct RequestSnapshot: Sendable {
        let token: UUID
        let previewID: UUID
        let request: ContextAnalysisRequest
    }

    let preview: SelectionTranslationPreview
    private(set) var status: SelectionTranslationStatus = .idle
    private(set) var selectedTranslation: String?
    private(set) var contextExplanation: String?
    private(set) var sourceSentence: String?
    private(set) var contextUnavailable = false
    private(set) var activeToken: UUID?
    private var request: RequestSnapshot?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var saveContext: ModelContext?
    private(set) var savedEntryID: UUID?
    var errorMessage: String?
    var isSaving: Bool { saveContext != nil }

    func saveToDictionary(context: ModelContext, service: any ContextAnalysisServing) {
        guard savedEntryID == nil, saveContext == nil else { return }
        saveContext = context
        if status == .ready { persistResult() }
        else if request == nil { begin(service: service) }
    }

    private func persistResult() {
        guard let context = saveContext, let selectedTranslation, let contextExplanation else { return }
        saveContext = nil
        let itemID = preview.sourceItemID
        do {
            let descriptor = FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == itemID })
            guard let item = try context.fetch(descriptor).first else {
                reportFailure(ContextAnalysisError.invalidContext.userMessage, code: .invalidContext)
                return
            }
            let entry = DictionaryEntry(text: preview.selectedText, item: item,
                                        segmentIndex: preview.segmentIndex, context: preview.context,
                                        audioStart: preview.audioRange?.lowerBound,
                                        audioEnd: preview.audioRange?.upperBound,
                                        sourceTrackID: preview.sourceTrackID)
            entry.phraseAudioStart = preview.phraseAudioRange?.lowerBound
            entry.phraseAudioEnd = preview.phraseAudioRange?.upperBound
            entry.sourceLanguageCode = preview.sourceLanguageCode
            entry.targetLanguageCode = preview.targetLanguageCode
            entry.translationText = selectedTranslation
            entry.translationOrigin = .openAI
            entry.translationStatus = .ready
            entry.translationUpdatedAt = .now
            entry.contextSelectedTranslationText = selectedTranslation
            entry.contextTranslationText = contextExplanation
            entry.contextAnalysisUpdatedAt = .now
            context.insert(entry)
            do {
                try context.save()
                savedEntryID = entry.id
            } catch {
                context.delete(entry)
                throw error
            }
        } catch {
            // Keep the successful result so saving can be retried without another model request.
            errorMessage = ContextAnalysisError.persistence.userMessage
            Task { await DiagnosticLog.shared.record(.init(event: "dictionary_save_failed", error: .persistence)) }
        }
    }

    private func reportFailure(_ message: String, code: ContextAnalysisError = .invalidOutput) {
        saveContext = nil
        status = .failed(message)
        errorMessage = message
        Task { await DiagnosticLog.shared.record(.init(event: "selection_translation_failed", error: code)) }
    }

    init(preview: SelectionTranslationPreview) {
        self.preview = preview
    }

    func start(service: any ContextAnalysisServing) {
        guard request == nil, status == .idle else { return }
        begin(service: service)
    }

    func retry(service: any ContextAnalysisServing) {
        invalidateRequest(resetStatus: true)
        selectedTranslation = nil
        contextExplanation = nil
        begin(service: service)
    }

    func dismiss() {
        saveContext = nil
        errorMessage = nil
        invalidateRequest(resetStatus: status != .ready)
    }

    func currentRequest() -> RequestSnapshot? { request }

    func acceptResult(token: UUID, previewID: UUID, result: ContextualPhraseResult) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        let direct = result.directTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = result.contextExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsBreakdown = !ContextAnalysisWords.wordsToExplain(
            in: preview.selectedText, language: preview.sourceLanguageCode
        ).isEmpty
        guard !direct.isEmpty, !needsBreakdown || !explanation.isEmpty else {
            fail(token: token, previewID: previewID,
                 message: ContextAnalysisError.invalidOutput.userMessage)
            return
        }
        selectedTranslation = direct
        contextExplanation = explanation
        status = .ready
        task = nil
        activeToken = nil
        request = nil
        persistResult()
    }

    func fail(token: UUID, previewID: UUID, message: String, code: ContextAnalysisError = .invalidOutput) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        task = nil
        activeToken = nil
        request = nil
        reportFailure(message, code: code)
    }

    private func begin(service: any ContextAnalysisServing) {
        errorMessage = nil
        guard let context = preview.context else {
            contextUnavailable = true
            reportFailure(ContextAnalysisError.invalidContext.userMessage, code: .invalidContext)
            return
        }
        let sentence = ContextSentenceExtractor.sentence(text: context.text,
                                                         selection: context.selection)
        sourceSentence = sentence?.text
        contextUnavailable = false
        revision += 1
        let analysisRequest: ContextAnalysisRequest
        do {
            analysisRequest = try ContextAnalysisRequestBuilder.build(.init(
                subject: .preview(preview.id), revision: revision,
                expectedSelectedText: preview.selectedText, context: context,
                sourceLanguage: preview.sourceLanguageCode,
                targetLanguage: preview.targetLanguageCode,
                promptVersion: OpenAIContextAnalysisProvider.promptVersion
            ))
        } catch let error as ContextAnalysisError {
            reportFailure(error.userMessage, code: error)
            return
        } catch {
            reportFailure(ContextAnalysisError.unknown.userMessage, code: .unknown)
            return
        }
        let snapshot = RequestSnapshot(token: analysisRequest.requestID,
                                       previewID: preview.id, request: analysisRequest)
        activeToken = snapshot.token
        request = snapshot
        status = .translating
        task = Task { [weak self] in
            do {
                let result = try await service.analyze(analysisRequest)
                try Task.checkCancellation()
                self?.acceptResult(token: snapshot.token, previewID: snapshot.previewID,
                                   result: result)
            } catch is CancellationError {
                self?.cancel(token: snapshot.token, previewID: snapshot.previewID)
            } catch ContextAnalysisError.cancelled {
                self?.cancel(token: snapshot.token, previewID: snapshot.previewID)
            } catch let error as ContextAnalysisError {
                self?.fail(token: snapshot.token, previewID: snapshot.previewID,
                           message: error.userMessage, code: error)
            } catch {
                self?.fail(token: snapshot.token, previewID: snapshot.previewID,
                           message: ContextAnalysisError.unknown.userMessage, code: .unknown)
            }
        }
    }

    private func cancel(token: UUID, previewID: UUID) {
        guard request?.token == token, request?.previewID == previewID else { return }
        task = nil
        activeToken = nil
        request = nil
        saveContext = nil
        status = .idle
    }

    private func invalidateRequest(resetStatus: Bool) {
        task?.cancel()
        task = nil
        activeToken = nil
        request = nil
        if resetStatus { status = .idle }
    }
}

/// Retain the last selection in this reader, including context and audio identity.
/// Reopening its popup reuses a successful result; another selection never inherits it.
@MainActor
final class SelectionTranslationCache {
    private var last: SelectionTranslationCoordinator?

    func coordinator(for preview: SelectionTranslationPreview) -> SelectionTranslationCoordinator {
        if let last {
            let previous = last.preview
            if previous.selectedText == preview.selectedText,
               previous.context == preview.context,
               previous.sourceItemID == preview.sourceItemID,
               previous.sourceLanguageCode == preview.sourceLanguageCode,
               previous.targetLanguageCode == preview.targetLanguageCode,
               previous.sourceTrackID == preview.sourceTrackID,
               previous.audioRange == preview.audioRange,
               previous.segmentIndex == preview.segmentIndex {
                return last
            }
            last.dismiss()
        }
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        last = coordinator
        return coordinator
    }
}
