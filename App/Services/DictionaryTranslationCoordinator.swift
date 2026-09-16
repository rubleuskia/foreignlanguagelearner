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

    func force(_ entry: DictionaryEntry, context: ModelContext) throws {
        modelContext = context
        let previous = (entry.translationText, entry.translationOriginRaw, entry.translationStatusRaw,
                        entry.translationErrorCode, entry.translationUpdatedAt, entry.translationRevision)
        entry.translationText = nil
        entry.translationOrigin = nil
        entry.translationStatus = .pending
        entry.translationErrorCode = nil
        entry.translationUpdatedAt = nil
        entry.translationRevision += 1
        do {
            try context.save()
        } catch {
            (entry.translationText, entry.translationOriginRaw, entry.translationStatusRaw,
             entry.translationErrorCode, entry.translationUpdatedAt, entry.translationRevision) = previous
            throw error
        }

        attemptedPreparationPairs.remove("\(entry.sourceLanguageCode)>\(entry.targetLanguageCode)")
        queued.removeAll { $0 == entry.id }
        queued.insert(entry.id, at: 0)
        if let active = currentJob, active.id == entry.id { finish(active) }
        else { startNext(context: context) }
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
            configuration = TranslationConfiguration.next(previous: configuration,
                                                          source: job.source, target: job.target)
            return
        }
    }

    private func finish(_ job: Job) {
        guard currentJob == job else { return }
        currentJob = nil
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

enum TranslationConfiguration {
    static func next(previous: TranslationSession.Configuration?, source: String,
                     target: String) -> TranslationSession.Configuration {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if var previous, previous.source == sourceLanguage, previous.target == targetLanguage {
            previous.invalidate()
            return previous
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }
}

private enum TranslationWorkerError: Error { case emptyResult }
