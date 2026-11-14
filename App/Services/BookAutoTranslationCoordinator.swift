import Foundation
import NaturalLanguage
import Observation
import SwiftData

@MainActor private enum BookAutoTranslationSession {
    static var enabledBooks: Set<UUID> = []
}

enum BookSentenceRanges {
    static func ranges(in text: String, language: String, reflowLineBreaks: Bool = false) -> [NSRange] {
        // Cue boundaries are not sentence boundaries. Reflow only for tokenization;
        // one-for-one replacements retain the original document's UTF-16 anchors.
        let tokenizationText = reflowLineBreaks
            ? text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") : text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue: SourceLanguage.canonical(language)))
        tokenizer.string = tokenizationText
        let source = text as NSString
        var result: [NSRange] = []
        tokenizer.enumerateTokens(in: tokenizationText.startIndex..<tokenizationText.endIndex) { range, _ in
            let raw = NSRange(range, in: tokenizationText)
            let piece = source.substring(with: raw) as NSString
            let first = piece.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
            let last = piece.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
            if first.location != NSNotFound {
                result.append(NSRange(location: raw.location + first.location,
                                      length: NSMaxRange(last) - first.location))
            }
            return true
        }
        return result
    }
}

/// One serial worker per open reader. Page changes snapshot eligibility before any result
/// changes vocabulary; jobs retain their own source identity when audio advances pages.
@MainActor @Observable final class BookAutoTranslationCoordinator {
    private struct Source: Equatable {
        let itemID: UUID
        let scope: String
        let digest: String
        let language: String
    }
    private struct Environment {
        let item: LearningItem
        let text: String
        let source: Source
        let vocabulary: ReadingVocabularyStore
        let context: ModelContext
        let service: any ContextAnalysisServing
    }
    private struct Job {
        let id: String
        let environment: Environment
        let itemRevision: String
        let range: NSRange
        let text: String
        let words: Set<String>
        let settings: TranslationRequestSettings
        var cacheKey: String {
            SentenceTranslation.key(text: text, sourceLanguage: environment.source.language, targetLanguage: "ru")
        }
    }
    private struct Failure {
        let job: Job
        let message: String
    }

    private(set) var enabled = false
    private(set) var translations: [TranslatedBookSentence] = []
    private(set) var retainedNewForms: Set<String> = []
    private(set) var revision = 0
    var showBlockedPopup = false
    private var itemID: UUID?
    private var isOpen = false
    private var visibleRange: NSRange?
    private var processedVisit = false
    private var queue: [Job] = []
    private var activeJob: Job?
    private var failures: [Failure] = []
    private var storageError: String?
    @ObservationIgnored private var environment: Environment?
    @ObservationIgnored private var sentenceRanges: [NSRange] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var pendingCount: Int {
        (queue + (activeJob.map { [$0] } ?? [])).filter { isVisible($0) }.count
    }
    var blocksManualTurn: Bool { enabled && pendingCount > 0 }
    var errorMessage: String? { storageError ?? failures.first(where: { isVisible($0.job) })?.message }

    func open(itemID: UUID) {
        guard !isOpen || self.itemID != itemID else { return }
        self.itemID = itemID; isOpen = true
        enabled = BookAutoTranslationSession.enabledBooks.contains(itemID)
    }

    func close() {
        cancelWork()
        isOpen = false; enabled = false; environment = nil; visibleRange = nil
        retainedNewForms = []; processedVisit = false
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if let itemID {
            if value { BookAutoTranslationSession.enabledBooks.insert(itemID) }
            else { BookAutoTranslationSession.enabledBooks.remove(itemID) }
        }
        if value { processedVisit = false; processVisiblePage() }
        else { cancelWork() }
    }

    func leavePages() {
        setEnabled(false)
        retainedNewForms = []; visibleRange = nil; processedVisit = false
        revision += 1
    }

    func pageVisible(_ range: NSRange, document: TranscriptDocument, item: LearningItem,
                     scope: String, vocabulary: ReadingVocabularyStore,
                     context: ModelContext, service: any ContextAnalysisServing, newVisit: Bool = true) {
        open(itemID: item.id)
        let previous = environment
        let sameText = previous?.text == document.text
        let source = Source(itemID: item.id, scope: scope,
                            digest: sameText ? previous!.source.digest : SentenceTranslation.digest(document.text),
                            language: SourceLanguage.canonical(item.sourceLanguageCode))
        let changed = previous?.source != source
        environment = Environment(item: item, text: document.text, source: source,
                                  vocabulary: vocabulary, context: context, service: service)
        if changed {
            sentenceRanges = BookSentenceRanges.ranges(in: document.text, language: source.language,
                reflowLineBreaks: document.segments.contains { $0.start != nil })
            translations = []; failures = []; storageError = nil
            restoreTranslations()
        }
        if range.length == 0, !changed, visibleRange != nil { return }
        if changed || range != visibleRange {
            visibleRange = range; processedVisit = false
            if changed || newVisit { retainedNewForms = [] }
            revision += 1
        }
        processVisiblePage()
    }

    /// Vocabulary readiness can arrive after the initial layout.
    func refresh() { processVisiblePage() }

    func retainedForms(on range: NSRange) -> Set<String> {
        range == visibleRange ? retainedNewForms : []
    }

    func translation(at range: NSRange) -> TranslatedBookSentence? {
        translations.first { $0.range == range }
    }

    func retry() {
        if storageError != nil { storageError = nil; restoreTranslations() }
        guard enabled else { return }
        let retry = failures.filter { isVisible($0.job) }
        failures.removeAll { isVisible($0.job) }
        for failure in retry where !containsJob(failure.job.id) { queue.append(failure.job) }
        startWorker()
    }

    func requestManualTurn() -> Bool {
        guard blocksManualTurn else { return true }
        showBlockedPopup = true
        return false
    }

    private func isVisible(_ job: Job) -> Bool {
        guard let environment, let visibleRange else { return false }
        return job.environment.source == environment.source && NSIntersectionRange(job.range, visibleRange).length > 0
    }

    private func containsJob(_ id: String) -> Bool { activeJob?.id == id || queue.contains { $0.id == id } }

    private func processVisiblePage() {
        guard enabled, !processedVisit, let environment, let visibleRange,
              visibleRange.length > 0, environment.vocabulary.ready,
              NSMaxRange(visibleRange) <= environment.text.utf16.count else { return }
        processedVisit = true
        let source = environment.text as NSString
        let currentKnowledge = environment.vocabulary.forms(for: environment.source.language)
        let known = currentKnowledge.subtracting(retainedNewForms)
        do {
            retainedNewForms.formUnion(try VocabularyTokenizer.forms(in: source.substring(with: visibleRange)).subtracting(known))
            // Build the entire candidate set synchronously, before the worker can learn words.
            for range in sentenceRanges where NSIntersectionRange(range, visibleRange).length > 0 {
                let text = source.substring(with: range)
                let overlap = NSIntersectionRange(range, visibleRange)
                guard !(try VocabularyTokenizer.forms(in: source.substring(with: overlap)).subtracting(known)).isEmpty else { continue }
                let words = try VocabularyTokenizer.forms(in: text).subtracting(known)
                guard !words.isEmpty else { continue }
                if words.isSubset(of: currentKnowledge), translations.contains(where: { $0.range == range }) { continue }
                let anchor = BookSentenceTranslation(itemID: environment.source.itemID, scope: environment.source.scope,
                    documentDigest: environment.source.digest, range: range,
                    translationKey: SentenceTranslation.key(text: text, sourceLanguage: environment.source.language, targetLanguage: "ru"))
                let job = Job(id: anchor.key, environment: environment, itemRevision: environment.item.resourceRevision,
                              range: range, text: text, words: words, settings: .current)
                guard !containsJob(job.id), !failures.contains(where: { $0.job.id == job.id }) else { continue }
                queue.append(job)
            }
            revision += 1
            startWorker()
        } catch { storageError = ContextAnalysisError.persistence.userMessage }
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty, enabled else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while self.generation == token, self.enabled, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                self.activeJob = job
                do {
                    let cached = try self.cached(job.cacheKey, context: job.environment.context)
                    let translation: String
                    if let cached { translation = cached.translation }
                    else {
                        var request = try ContextAnalysisRequestBuilder.build(.init(
                            subject: .preview(UUID()), revision: 1, expectedSelectedText: job.text,
                            context: .init(text: job.environment.text, selection: job.range),
                            sourceLanguage: job.environment.source.language, targetLanguage: "ru",
                            promptVersion: OpenAIContextAnalysisProvider.promptVersion, translationOnly: true))
                        request.translationOnly = true; request.execution = job.settings
                        let result = try await job.environment.service.analyze(request)
                        translation = result.directTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // Providers may ignore cancellation; check the generation before touching storage.
                    guard self.generation == token, self.enabled, !Task.isCancelled else { break }
                    guard job.environment.item.modelContext != nil,
                          job.environment.item.resourceRevision == job.itemRevision,
                          SourceLanguage.canonical(job.environment.item.sourceLanguageCode) == job.environment.source.language
                    else { throw ContextAnalysisError.invalidContext }
                    guard !translation.isEmpty, translation.utf16.count <= ContextAnalysisLimits.maximumSentenceTranslationUTF16
                    else { throw ContextAnalysisError.invalidOutput }
                    try self.persist(job, translation: translation)
                } catch {
                    guard self.generation == token, self.enabled, !Task.isCancelled else { break }
                    let message = (error as? ContextAnalysisError) == .inputTooLarge
                        ? "This sentence is too long for automatic translation."
                        : (error as? ContextAnalysisError)?.userMessage ?? ContextAnalysisError.persistence.userMessage
                    self.failures.append(Failure(job: job, message: message))
                }
                self.activeJob = nil
            }
            if self.generation == token { self.activeJob = nil; self.worker = nil }
        }
    }

    private func persist(_ job: Job, translation: String) throws {
        let context = job.environment.context
        let key = job.cacheKey
        let existing = try cached(key, context: context)
        let anchorID = job.id
        let anchorExists = try context.fetchCount(FetchDescriptor<BookSentenceTranslation>(predicate: #Predicate { $0.key == anchorID })) > 0
        try job.environment.vocabulary.learnTranslated(job.words, language: job.environment.source.language, context: context) {
            if existing == nil {
                context.insert(SentenceTranslation(text: job.text, sourceLanguage: job.environment.source.language,
                                                   targetLanguage: "ru", translation: translation))
            }
            if !anchorExists {
                context.insert(BookSentenceTranslation(itemID: job.environment.source.itemID, scope: job.environment.source.scope,
                    documentDigest: job.environment.source.digest, range: job.range, translationKey: key))
            }
        }
        if environment?.source == job.environment.source {
            translations.removeAll { $0.range == job.range }
            translations.append(.init(range: job.range, text: job.text, translation: translation))
            translations.sort { $0.range.location < $1.range.location }
            revision += 1
        }
    }

    private func cached(_ key: String, context: ModelContext) throws -> SentenceTranslation? {
        var descriptor = FetchDescriptor<SentenceTranslation>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func restoreTranslations() {
        guard let environment else { return }
        let id = environment.source.itemID, scope = environment.source.scope, digest = environment.source.digest
        do {
            let anchors = try environment.context.fetch(FetchDescriptor<BookSentenceTranslation>(predicate: #Predicate {
                $0.itemID == id && $0.scope == scope && $0.documentDigest == digest
            }))
            let source = environment.text as NSString
            translations = try anchors.compactMap { anchor in
                let range = NSRange(location: anchor.location, length: anchor.length)
                guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length,
                      let cached = try cached(anchor.translationKey, context: environment.context),
                      cached.sourceLanguage == environment.source.language, cached.targetLanguage == "ru" else { return nil }
                let text = source.substring(with: range)
                guard SentenceTranslation.key(text: text, sourceLanguage: environment.source.language, targetLanguage: "ru") == cached.key else { return nil }
                return TranslatedBookSentence(range: range, text: text, translation: cached.translation)
            }.sorted { $0.range.location < $1.range.location }
            revision += 1
        } catch { storageError = ContextAnalysisError.persistence.userMessage }
    }

    private func cancelWork() {
        generation = UUID()
        worker?.cancel(); worker = nil; queue = []; activeJob = nil; failures = []
    }
}
