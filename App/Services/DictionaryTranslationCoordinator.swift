import Foundation
import Observation
import SwiftData
import Translation

@MainActor @Observable
final class DictionaryTranslationCoordinator {
    struct Job: Equatable {
        let id: UUID
        let text: String
        let source: String
        let target: String
        let revision: Int
    }

    var configuration: TranslationSession.Configuration?
    private(set) var currentJob: Job?
    private var queued: [UUID] = []
    private var modelContext: ModelContext?
    private var attemptedPreparationPairs: Set<String> = []

    func enqueue(_ entry: DictionaryEntry, context: ModelContext) {
        modelContext = context
        guard !entry.hasTranslation, entry.translationStatus != .unsupported else { return }
        let activeIsCurrentRevision = currentJob?.id == entry.id && currentJob?.revision == entry.translationRevision
        if !activeIsCurrentRevision, !queued.contains(entry.id) { queued.append(entry.id) }
        startNext(context: context)
    }

    func retry(_ entry: DictionaryEntry, context: ModelContext) {
        attemptedPreparationPairs.remove("\(entry.sourceLanguageCode)>\(entry.targetLanguageCode)")
        entry.translationRevision += 1
        entry.translationErrorCode = nil
        entry.translationStatus = .pending
        try? context.save()
        enqueue(entry, context: context)
    }

    func recover(context: ModelContext) {
        modelContext = context
        guard let entries = try? context.fetch(FetchDescriptor<DictionaryEntry>()) else { return }
        let localItemIDs = Set((try? context.fetch(FetchDescriptor<LearningItem>()).map(\.id)) ?? [])
        for entry in entries where entry.localSourceItemID == nil && localItemIDs.contains(entry.sourceItemID) {
            entry.localSourceItemID = entry.sourceItemID
        }
        for entry in entries where entry.translationStatus == .translating {
            entry.translationStatus = .pending
        }
        try? context.save()
        for entry in entries where entry.translationStatus == .pending { enqueue(entry, context: context) }
    }

    func cancel(_ id: UUID) { queued.removeAll { $0 == id } }

    nonisolated func perform(session: TranslationSession) async {
        guard let job = await activeJob() else { return }
        do {
            let source = Locale.Language(identifier: job.source)
            let target = Locale.Language(identifier: job.target)
            let status = await LanguageAvailability().status(from: source, to: target)
            switch status {
            case .unsupported:
                await markUnsupported(job)
                return
            case .supported:
                guard await markNeedsDownload(job) else { return }
                guard await beginPreparation(job) else { return }
                try await session.prepareTranslation()
            case .installed:
                break
            @unknown default:
                await fail(job, code: "unknownLanguageAvailability", keepNeedsDownload: false)
                return
            }
            guard await markTranslating(job) else { return }
            let response = try await session.translate(job.text)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { throw TranslationWorkerError.emptyResult }
            await complete(job, translation: translated)
        } catch is CancellationError {
            await cancel(job)
        } catch {
            await fail(job, code: String(describing: error), keepNeedsDownload: true)
        }
    }

    private func activeJob() -> Job? {
        guard let job = currentJob else { return nil }
        guard let context = modelContext,
              let entry = fetch(job.id, context: context), entry.translationRevision == job.revision else {
            finish(job)
            return nil
        }
        return job
    }

    private func markUnsupported(_ job: Job) {
        guard let entry = currentEntry(for: job) else { finish(job); return }
        entry.translationStatus = .unsupported
        entry.translationErrorCode = "unsupportedLanguagePair"
        saveAndFinish(job)
    }

    private func markNeedsDownload(_ job: Job) -> Bool {
        guard let entry = currentEntry(for: job) else { finish(job); return false }
        entry.translationStatus = .needsDownload
        try? modelContext?.save()
        return true
    }

    private func beginPreparation(_ job: Job) -> Bool {
        let pair = "\(job.source)>\(job.target)"
        guard attemptedPreparationPairs.insert(pair).inserted else {
            finish(job)
            return false
        }
        return true
    }

    private func markTranslating(_ job: Job) -> Bool {
        guard let entry = currentEntry(for: job), entry.translationOrigin != .manual,
              entry.translationOrigin != .imported else { finish(job); return false }
        entry.translationStatus = .translating
        try? modelContext?.save()
        return true
    }

    private func complete(_ job: Job, translation: String) {
        guard let entry = currentEntry(for: job), entry.translationOrigin != .manual,
              entry.translationOrigin != .imported else { finish(job); return }
        entry.translationText = translation
        entry.translationOrigin = .apple
        entry.translationUpdatedAt = .now
        entry.translationErrorCode = nil
        entry.translationStatus = .ready
        saveAndFinish(job)
    }

    private func cancel(_ job: Job) {
        guard let entry = currentEntry(for: job) else { finish(job); return }
        entry.translationStatus = .pending
        saveAndFinish(job)
    }

    private func fail(_ job: Job, code: String, keepNeedsDownload: Bool) {
        guard let entry = currentEntry(for: job) else { finish(job); return }
        if !keepNeedsDownload || entry.translationStatus != .needsDownload { entry.translationStatus = .failed }
        entry.translationErrorCode = code
        saveAndFinish(job)
    }

    private func currentEntry(for job: Job) -> DictionaryEntry? {
        guard currentJob == job, let context = modelContext,
              let entry = fetch(job.id, context: context), entry.translationRevision == job.revision else { return nil }
        return entry
    }

    private func saveAndFinish(_ job: Job) {
        try? modelContext?.save()
        finish(job)
    }

    private func startNext(context: ModelContext) {
        guard currentJob == nil else { return }
        while !queued.isEmpty {
            let id = queued.removeFirst()
            guard let entry = fetch(id, context: context), !entry.hasTranslation,
                  entry.translationStatus != .unsupported else { continue }
            let job = Job(id: id, text: entry.text, source: entry.sourceLanguageCode,
                          target: entry.targetLanguageCode, revision: entry.translationRevision)
            currentJob = job
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: job.source),
                target: Locale.Language(identifier: job.target)
            )
            return
        }
    }

    private func finish(_ job: Job) {
        guard currentJob == job else { return }
        currentJob = nil
        configuration = nil
        Task { @MainActor in
            await Task.yield()
            if let context = self.modelContext { self.startNext(context: context) }
        }
    }

    private func fetch(_ id: UUID, context: ModelContext) -> DictionaryEntry? {
        var descriptor = FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

private enum TranslationWorkerError: Error { case emptyResult }
