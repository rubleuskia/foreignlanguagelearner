import SwiftUI

protocol ContextAnalysisServing: Sendable {
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult
}

actor ContextAnalysisService: ContextAnalysisServing {
    private struct Job {
        let request: ContextAnalysisRequest
        let apiKey: String
        let model: OpenAITranslationModel
        let prompt: String
        let continuation: CheckedContinuation<ContextualPhraseResult, Error>
    }

    private struct ActiveJob {
        let job: Job
        let task: Task<Void, Never>
    }

    private var active: ActiveJob?
    private var pending: Job?

    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        guard ContextAnalysisSettings.isCloudAnalysisEnabled() else {
            throw ContextAnalysisError.missingConfiguration
        }
        guard let apiKey = try OpenAIAPIKeyStore.load(), !apiKey.isEmpty else {
            throw ContextAnalysisError.missingConfiguration
        }
        let model = ContextAnalysisSettings.selectedModel()
        let prompt = ContextAnalysisSettings.prompt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Job(request: request, apiKey: apiKey, model: model, prompt: prompt,
                            continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.requestID) }
        }
    }

    private func enqueue(_ job: Job) {
        guard active != nil else {
            start(job)
            return
        }
        guard pending == nil else {
            job.continuation.resume(throwing: ContextAnalysisError.busy)
            return
        }
        pending = job
    }

    private func start(_ job: Job) {
        let provider = OpenAIContextAnalysisProvider(
            apiKey: job.apiKey, model: job.model, prompt: job.prompt
        )
        let task = Task {
            let result: Result<ContextualPhraseResult, Error>
            do {
                result = .success(try await provider.analyze(job.request))
            } catch {
                result = .failure(error)
            }
            complete(requestID: job.request.requestID, result: result)
        }
        active = ActiveJob(job: job, task: task)
    }

    private func complete(requestID: UUID, result: Result<ContextualPhraseResult, Error>) {
        guard let current = active, current.job.request.requestID == requestID else { return }
        active = nil
        current.job.continuation.resume(with: result)
        if let next = pending {
            pending = nil
            start(next)
        }
    }

    private func cancel(requestID: UUID) {
        if let current = active, current.job.request.requestID == requestID {
            current.task.cancel()
            return
        }
        if let next = pending, next.request.requestID == requestID {
            pending = nil
            next.continuation.resume(throwing: ContextAnalysisError.cancelled)
        }
    }
}

private struct ContextAnalysisServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = ContextAnalysisService()
}

extension EnvironmentValues {
    var contextAnalysisService: ContextAnalysisService {
        get { self[ContextAnalysisServiceEnvironmentKey.self] }
        set { self[ContextAnalysisServiceEnvironmentKey.self] = newValue }
    }
}
