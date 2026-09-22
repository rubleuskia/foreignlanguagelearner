import Foundation
import Observation
import Translation

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
        let sourceLanguageCode: String
        let targetLanguageCode: String
        let phrase: String
        let sentence: String?
        let phraseRequestID: String
        let sentenceRequestID: String?
    }

    let preview: SelectionTranslationPreview
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var status: SelectionTranslationStatus = .idle
    private(set) var selectedTranslation: String?
    private(set) var sentenceTranslation: String?
    private(set) var sourceSentence: String?
    private(set) var contextUnavailable = false
    private(set) var activeToken: UUID?
    private var request: RequestSnapshot?

    init(preview: SelectionTranslationPreview) {
        self.preview = preview
    }

    func start() {
        guard request == nil, status == .idle else { return }
        begin()
    }

    func retry() {
        invalidateRequest(resetStatus: true)
        selectedTranslation = nil
        sentenceTranslation = nil
        begin()
    }

    func dismiss() {
        invalidateRequest(resetStatus: true)
    }

    nonisolated func perform(session: TranslationSession) async {
        guard let request = await currentRequest() else { return }
        do {
            let source = Locale.Language(identifier: request.sourceLanguageCode)
            let target = Locale.Language(identifier: request.targetLanguageCode)
            switch await LanguageAvailability().status(from: source, to: target) {
            case .unsupported:
                await fail(token: request.token, previewID: request.previewID,
                           message: "This language pair is not supported.")
                return
            case .supported:
                await setStatus(.preparing, token: request.token, previewID: request.previewID)
                try await session.prepareTranslation()
            case .installed:
                break
            @unknown default:
                await fail(token: request.token, previewID: request.previewID,
                           message: "Translation availability could not be determined.")
                return
            }
            await setStatus(.translating, token: request.token, previewID: request.previewID)
            var batch = [TranslationSession.Request(
                sourceText: request.phrase, clientIdentifier: request.phraseRequestID
            )]
            if let sentence = request.sentence, let identifier = request.sentenceRequestID {
                batch.append(.init(sourceText: sentence, clientIdentifier: identifier))
            }
            let responses = try await session.translations(from: batch)
            let values = Dictionary(uniqueKeysWithValues: responses.compactMap { response in
                response.clientIdentifier.map { ($0, response.targetText) }
            })
            await acceptTranslations(token: request.token, previewID: request.previewID, values: values)
        } catch is CancellationError {
            await cancel(token: request.token, previewID: request.previewID)
        } catch {
            await fail(token: request.token, previewID: request.previewID,
                       message: error.localizedDescription)
        }
    }

    func currentRequest() -> RequestSnapshot? { request }

    func acceptTranslations(token: UUID, previewID: UUID, values: [String: String]) {
        guard let request, request.token == token, request.previewID == previewID,
              preview.id == previewID else { return }
        guard let phrase = clean(values[request.phraseRequestID]) else {
            fail(token: token, previewID: previewID,
                 message: "Translation returned no usable phrase translation.")
            return
        }
        if let sentenceID = request.sentenceRequestID {
            guard let sentence = clean(values[sentenceID]) else {
                fail(token: token, previewID: previewID,
                     message: "Translation returned no usable sentence translation.")
                return
            }
            sentenceTranslation = sentence
        }
        selectedTranslation = phrase
        status = .ready
        activeToken = nil
        self.request = nil
    }

    func fail(token: UUID, previewID: UUID, message: String) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        activeToken = nil
        request = nil
        status = .failed(message)
    }

    private func begin() {
        let sentence = preview.context.flatMap {
            ContextSentenceExtractor.sentence(text: $0.text, selection: $0.selection)
        }
        sourceSentence = sentence?.text
        contextUnavailable = sentence == nil
        let token = UUID()
        let phraseID = "selection-\(UUID().uuidString)"
        let sentenceID = sentence.map { _ in "sentence-\(UUID().uuidString)" }
        activeToken = token
        request = RequestSnapshot(token: token, previewID: preview.id,
                                  sourceLanguageCode: preview.sourceLanguageCode,
                                  targetLanguageCode: preview.targetLanguageCode,
                                  phrase: preview.selectedText, sentence: sentence?.text,
                                  phraseRequestID: phraseID, sentenceRequestID: sentenceID)
        status = .preparing
        configuration = QualityTranslationConfiguration.next(
            previous: configuration, source: preview.sourceLanguageCode,
            target: preview.targetLanguageCode
        )
    }

    private func setStatus(_ value: SelectionTranslationStatus, token: UUID, previewID: UUID) {
        guard request?.token == token, request?.previewID == previewID,
              preview.id == previewID else { return }
        status = value
    }

    private func cancel(token: UUID, previewID: UUID) {
        guard request?.token == token, request?.previewID == previewID else { return }
        invalidateRequest(resetStatus: true)
    }

    private func invalidateRequest(resetStatus: Bool) {
        activeToken = nil
        request = nil
        if resetStatus { status = .idle }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
