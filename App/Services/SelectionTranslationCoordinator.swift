import Foundation
import Observation

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
        invalidateRequest(resetStatus: true)
    }

    func currentRequest() -> RequestSnapshot? { request }

    func acceptResult(token: UUID, previewID: UUID, result: ContextualPhraseResult) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        let direct = result.directTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = result.contextExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !direct.isEmpty, !explanation.isEmpty else {
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
    }

    func fail(token: UUID, previewID: UUID, message: String) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        task = nil
        activeToken = nil
        request = nil
        status = .failed(message)
    }

    private func begin(service: any ContextAnalysisServing) {
        guard let context = preview.context else {
            contextUnavailable = true
            status = .failed(ContextAnalysisError.invalidContext.userMessage)
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
            status = .failed(error.userMessage)
            return
        } catch {
            status = .failed(ContextAnalysisError.unknown.userMessage)
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
            } catch let error as ContextAnalysisError {
                self?.fail(token: snapshot.token, previewID: snapshot.previewID,
                           message: error.userMessage)
            } catch {
                self?.fail(token: snapshot.token, previewID: snapshot.previewID,
                           message: ContextAnalysisError.unknown.userMessage)
            }
        }
    }

    private func cancel(token: UUID, previewID: UUID) {
        guard request?.token == token, request?.previewID == previewID else { return }
        task = nil
        activeToken = nil
        request = nil
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
