import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ForeignLanguageLearner

private struct NeverCompletingContextAnalysisService: ContextAnalysisServing {
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

final class LearningUXTests: XCTestCase {
    @MainActor
    private func trainingEntry(level: Int) -> DictionaryEntry {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0)
        entry.translationText = "замок"
        entry.translationStatus = .ready
        entry.learningLevel = level
        return entry
    }

    @MainActor
    func testCooldownRemainingTimeUsesSavedDateAndCurrentSettings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = trainingEntry(level: 2)
        entry.levelChangedAt = now
        XCTAssertEqual(LearningCooldown.remainingTime(entry, now: now, defaults: defaults), 72 * 3600)
        XCTAssertEqual(LearningCooldown.remainingDescription(seconds: 72 * 3600), "3d 0h 0m")
        XCTAssertEqual(LearningCooldown.remainingDescription(seconds: 90061), "1d 1h 2m")
        XCTAssertEqual(LearningCooldown.remainingDescription(seconds: 1), "0d 0h 1m")
        XCTAssertEqual(LearningCooldown.remainingTime(entry, now: now.addingTimeInterval(72 * 3600), defaults: defaults), 0)
        defaults.set(1.0, forKey: "learning.cooldown.level.2")
        XCTAssertEqual(LearningCooldown.remainingTime(entry, now: now.addingTimeInterval(1800), defaults: defaults), 1800)
        entry.levelChangedAt = nil
        XCTAssertNil(LearningCooldown.remainingTime(entry, now: now, defaults: defaults))
    }

    @MainActor
    func testCooldownBoundariesOverridesAndLegacyBackfill() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (level, hours) in [(1, 24.0), (2, 72.0), (3, 96.0)] {
            let entry = trainingEntry(level: level)
            entry.levelChangedAt = now
            XCTAssertFalse(LearningCooldown.isReady(entry, now: now.addingTimeInterval(hours * 3600 - 1), defaults: defaults))
            XCTAssertTrue(LearningCooldown.isReady(entry, now: now.addingTimeInterval(hours * 3600), defaults: defaults))
            XCTAssertTrue(LearningRoundPool.entries(from: [entry], now: now, defaults: defaults).isEmpty)
            XCTAssertEqual(LearningRoundPool.entries(from: [entry], ignoreCooldown: true, now: now, defaults: defaults).count, 1)
        }
        let legacy = trainingEntry(level: 2)
        legacy.levelChangedAt = nil
        try LearningCooldown.backfill([legacy], now: now, save: {})
        try LearningCooldown.backfill([legacy], now: now.addingTimeInterval(100), save: {})
        XCTAssertEqual(legacy.levelChangedAt, now)
        defaults.set(0.0, forKey: "learning.cooldown.level.2")
        XCTAssertTrue(LearningCooldown.isReady(legacy, now: now, defaults: defaults))
    }

    @MainActor
    func testCooldownAnswerRollbackAndUndo() throws {
        let entry = trainingEntry(level: 1)
        let originalDate = entry.levelChangedAt
        var round = LearningRoundState(selection: .five, selectedIDs: [entry.id])
        let before = round
        let firstPresentation = round.currentPresentationID
        XCTAssertThrowsError(try LearningAnswerTransaction.apply(entry: entry, round: &round,
            expectedEntryID: entry.id, presentationID: firstPresentation, right: true,
            save: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(entry.learningLevel, 1)
        XCTAssertEqual(entry.levelChangedAt, originalDate)
        let presentation = round.currentPresentationID
        XCTAssertTrue(try LearningAnswerTransaction.apply(entry: entry, round: &round,
            expectedEntryID: entry.id, presentationID: presentation, right: true, save: {}))
        XCTAssertFalse(LearningCooldown.isReady(entry))
        let undo = LearningAnswerUndo(entryID: entry.id, previousLevel: 1, savedLevel: 2,
            previousRound: before, answeredRound: round, expiresAt: .now.addingTimeInterval(3),
            previousLevelChangedAt: originalDate, savedLevelChangedAt: entry.levelChangedAt)
        XCTAssertTrue(try undo.restore(entry: entry, round: &round, save: {}))
        XCTAssertEqual(entry.levelChangedAt, originalDate)
    }

    @MainActor
    func testPoolFillsRoundFromLowestLevelsFirst() {
        let first = trainingEntry(level: 1), second = trainingEntry(level: 1)
        let higher = trainingEntry(level: 2), highest = trainingEntry(level: 3)
        let known = trainingEntry(level: 4), untranslated = trainingEntry(level: 1)
        untranslated.translationText = nil
        let entries = [highest, first, higher, second, known, untranslated, first]
        XCTAssertEqual(Set(LearningRoundPool.entries(from: entries, limit: 30).map(\.id)), [first.id, second.id, higher.id, highest.id])
        XCTAssertEqual(LearningRoundPool.entries(from: entries, limit: 2).count, 2)
        first.learningLevel = 2
        XCTAssertEqual(Set(LearningRoundPool.entries(from: entries).map(\.id)), [first.id, second.id, higher.id, highest.id])
        second.learningLevel = 2
        XCTAssertEqual(Set(LearningRoundPool.entries(from: entries).map(\.id)), [first.id, second.id, higher.id, highest.id])
        first.learningLevel = 3
        second.learningLevel = 3
        higher.learningLevel = 3
        XCTAssertEqual(LearningRoundPool.entries(from: entries).count, 4)
        XCTAssertTrue(LearningRoundPool.entries(from: [known, untranslated]).isEmpty)
    }

    @MainActor
    func testUndoRestoresRightAndWrongIncludingRoundCompletion() throws {
        for right in [true, false] {
            let entry = trainingEntry(level: 3)
            let before = LearningRoundState(selection: .five, selectedIDs: [entry.id])
            var round = before
            XCTAssertTrue(try LearningAnswerTransaction.apply(entry: entry, round: &round,
                expectedEntryID: entry.id, presentationID: before.currentPresentationID,
                right: right, save: {}))
            let now = Date()
            let undo = LearningAnswerUndo(entryID: entry.id, previousLevel: 3,
                savedLevel: entry.learningLevel, previousRound: before, answeredRound: round,
                expiresAt: now.addingTimeInterval(3))
            XCTAssertTrue(try undo.restore(entry: entry, round: &round, now: now, save: {}))
            XCTAssertEqual(entry.learningLevel, 3)
            XCTAssertEqual(round.pendingIDs, before.pendingIDs)
            XCTAssertEqual(round.completedIDs, [])
            XCTAssertEqual(round.wrongAttemptCount, 0)
            XCTAssertFalse(round.isComplete)
            XCTAssertTrue(round.hasValidPartition)
            XCTAssertNotEqual(round.currentPresentationID, before.currentPresentationID)
            XCTAssertFalse(try undo.restore(entry: entry, round: &round, now: now, save: {}))
        }
    }

    @MainActor
    func testUndoExpiryAndSaveFailurePreserveAnsweredState() throws {
        enum Expected: Error { case failure }
        let entry = trainingEntry(level: 1)
        let before = LearningRoundState(selection: .five, selectedIDs: [entry.id])
        var round = before
        _ = try LearningAnswerTransaction.apply(entry: entry, round: &round,
            expectedEntryID: entry.id, presentationID: before.currentPresentationID,
            right: true, save: {})
        let answered = round, now = Date()
        let undo = LearningAnswerUndo(entryID: entry.id, previousLevel: 1, savedLevel: 2,
            previousRound: before, answeredRound: round, expiresAt: now.addingTimeInterval(3))
        XCTAssertThrowsError(try undo.restore(entry: entry, round: &round, now: now,
                                             save: { throw Expected.failure }))
        XCTAssertEqual(entry.learningLevel, 2)
        XCTAssertEqual(round, answered)
        XCTAssertFalse(try undo.restore(entry: entry, round: &round, now: now.addingTimeInterval(3),
                                       save: { XCTFail("Expired undo must not save") }))
        XCTAssertEqual(entry.learningLevel, 2)
        XCTAssertEqual(round, answered)
    }

    func testUnfinishedRoundCheckpointSurvivesReopeningAndClearsOnCompletion() throws {
        let suite = "LearningCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        var round = LearningRoundState(selection: .five, selectedIDs: [a, b])
        LearningRoundCheckpoint.save(round, defaults: defaults)
        XCTAssertNil(LearningRoundCheckpoint.load(defaults: defaults))
        round.recordAnswer(entryID: a, presentationID: round.currentPresentationID, right: false)
        LearningRoundCheckpoint.save(round, defaults: defaults)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var resumed = try XCTUnwrap(LearningRoundCheckpoint.load(defaults: reopenedDefaults))
        XCTAssertEqual(resumed, round)
        XCTAssertEqual(resumed.pendingIDs, [b, a])
        resumed.recordAnswer(entryID: b, presentationID: resumed.currentPresentationID, right: true)
        LearningRoundCheckpoint.save(resumed, defaults: defaults)
        XCTAssertEqual(LearningRoundCheckpoint.load(defaults: defaults)?.completedIDs, [b])
        resumed.recordAnswer(entryID: a, presentationID: resumed.currentPresentationID, right: true)
        LearningRoundCheckpoint.save(resumed, defaults: defaults)
        XCTAssertNil(LearningRoundCheckpoint.load(defaults: defaults))
    }

    func testCheckpointIgnoresCorruptDataAndClearsWhenRemainingEntryIsSkipped() throws {
        let suite = "LearningCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: LearningRoundCheckpoint.key)
        XCTAssertNil(LearningRoundCheckpoint.load(defaults: defaults))
        let id = UUID()
        var round = LearningRoundState(selection: .five, selectedIDs: [id])
        round.recordAnswer(entryID: id, presentationID: round.currentPresentationID, right: false)
        LearningRoundCheckpoint.save(round, defaults: defaults)
        round.skip(entryID: id, presentationID: round.currentPresentationID)
        LearningRoundCheckpoint.save(round, defaults: defaults)
        XCTAssertNil(LearningRoundCheckpoint.load(defaults: defaults))
    }

    @MainActor
    func testRightAnswerPersistsLevelBeforeRoundCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("learning.store"))
        let id: UUID
        var checkpoint: Data
        do {
            let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                               configurations: configuration)
            let context = ModelContext(container)
            let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                    mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                    duration: 10, segments: [])
            let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0)
            entry.translationText = "замок"
            entry.translationStatus = .ready
            entry.learningLevel = 2
            id = entry.id
            context.insert(item)
            context.insert(entry)
            try context.save()
            var round = LearningRoundState(selection: .five, selectedIDs: [id, UUID()])
            XCTAssertTrue(try LearningAnswerTransaction.apply(entry: entry, round: &round,
                expectedEntryID: id, presentationID: round.currentPresentationID, right: true,
                save: { try context.save() }))
            XCTAssertFalse(round.isComplete)
            checkpoint = try JSONEncoder().encode(round)
        }
        let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: configuration)
        let entries = try ModelContext(reopened).fetch(FetchDescriptor<DictionaryEntry>())
        XCTAssertEqual(entries.first(where: { $0.id == id })?.learningLevel, 3)
        let resumed = try JSONDecoder().decode(LearningRoundState.self, from: checkpoint)
        XCTAssertEqual(resumed.completedIDs, [id])
        XCTAssertFalse(resumed.pendingIDs.contains(id))
    }

    func testRoundSelectionCountsForZeroThreeAndTwentyFiveAvailable() {
        XCTAssertEqual(LearningRoundSelection.five.count(available: 0), 0)
        XCTAssertEqual(LearningRoundSelection.five.count(available: 3), 3)
        XCTAssertEqual(LearningRoundSelection.ten.count(available: 25), 10)
        XCTAssertEqual(LearningRoundSelection.twenty.count(available: 25), 20)
        XCTAssertEqual(LearningRoundSelection.all.count(available: 25), 25)
    }

    func testRoundMaintainsFixedUniquePartitionAndRejectsDuplicatePresentation() {
        let a = UUID(), b = UUID()
        let firstPresentation = UUID()
        var round = LearningRoundState(selection: .five,
                                       selectedIDs: [a, b, a],
                                       presentationID: firstPresentation)
        XCTAssertEqual(round.selectedIDs, [a, b])
        XCTAssertEqual(round.totalSelectedCount, 2)

        let secondPresentation = UUID()
        XCTAssertTrue(round.recordAnswer(entryID: a, presentationID: firstPresentation,
                                         right: false, nextPresentationID: secondPresentation))
        XCTAssertEqual(round.pendingIDs, [b, a])
        XCTAssertEqual(round.totalSelectedCount, 2)
        XCTAssertFalse(round.recordAnswer(entryID: a, presentationID: firstPresentation,
                                          right: false))
        XCTAssertEqual(round.wrongAttemptCount, 1)

        let thirdPresentation = UUID()
        XCTAssertTrue(round.recordAnswer(entryID: b, presentationID: secondPresentation,
                                         right: true, nextPresentationID: thirdPresentation))
        XCTAssertEqual(round.completedIDs, [b])
        XCTAssertTrue(round.recordAnswer(entryID: a, presentationID: thirdPresentation,
                                         right: true))
        XCTAssertTrue(round.isComplete)
        XCTAssertEqual(round.completedIDs, [b, a])
        XCTAssertTrue(round.hasValidPartition)
    }

    func testSingleWrongCreatesNewPresentationWithoutDuplicatingPendingID() {
        let id = UUID(), firstPresentation = UUID(), nextPresentation = UUID()
        var round = LearningRoundState(selection: .five, selectedIDs: [id],
                                       presentationID: firstPresentation)
        XCTAssertTrue(round.recordAnswer(entryID: id, presentationID: firstPresentation,
                                         right: false, nextPresentationID: nextPresentation))
        XCTAssertEqual(round.pendingIDs, [id])
        XCTAssertEqual(round.currentPresentationID, nextPresentation)
        XCTAssertEqual(round.wrongAttemptCount, 1)
        XCTAssertTrue(round.hasValidPartition)
    }

    func testSkipDoesNotChangeAttemptCountsOrRefillRound() {
        let a = UUID(), b = UUID(), presentation = UUID()
        var round = LearningRoundState(selection: .twenty, selectedIDs: [a, b],
                                       presentationID: presentation)
        XCTAssertTrue(round.skip(entryID: a, presentationID: presentation))
        XCTAssertEqual(round.pendingIDs, [b])
        XCTAssertEqual(round.skippedIDs, [a])
        XCTAssertEqual(round.rightAttemptCount, 0)
        XCTAssertEqual(round.wrongAttemptCount, 0)
        XCTAssertEqual(round.totalSelectedCount, 2)
        XCTAssertTrue(round.hasValidPartition)
    }

    @MainActor
    func testFailedSaveRestoresLevelAndDoesNotAdvanceRound() {
        enum Expected: Error { case failure }
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0)
        entry.translationText = "замок"
        entry.translationStatus = .ready
        entry.learningLevel = 2
        let presentation = UUID()
        var round = LearningRoundState(selection: .five, selectedIDs: [entry.id],
                                       presentationID: presentation)

        XCTAssertThrowsError(try LearningAnswerTransaction.apply(
            entry: entry, round: &round, expectedEntryID: entry.id,
            presentationID: presentation, right: true,
            save: { throw Expected.failure }
        ))
        XCTAssertEqual(entry.learningLevel, 2)
        XCTAssertEqual(round.pendingIDs, [entry.id])
        XCTAssertEqual(round.rightAttemptCount, 0)
        XCTAssertEqual(round.currentPresentationID, presentation)
    }

    @MainActor
    func testGlobalLearntListIncludesPreviousLevelFourAndFiltersInvalidTranslations() {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        func entry(_ text: String, level: Int, status: TranslationStatus = .ready,
                   target: String = "ru", date: Date) -> DictionaryEntry {
            let value = DictionaryEntry(text: text, item: item, segmentIndex: nil)
            value.translationText = "перевод"
            value.translationStatus = status
            value.targetLanguageCode = target
            value.learningLevel = level
            value.createdAt = date
            return value
        }
        let previous = entry("C", level: 4, date: Date(timeIntervalSince1970: 1))
        let becameLearnt = entry("B", level: 4, date: Date(timeIntervalSince1970: 2))
        let stillLearning = entry("A", level: 2, date: Date(timeIntervalSince1970: 3))
        let pending = entry("D", level: 4, status: .pending,
                            date: Date(timeIntervalSince1970: 4))
        let unsupported = entry("E", level: 4, status: .unsupported,
                                date: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(LearningCompletion.learntEntries(
            from: [previous, becameLearnt, stillLearning, pending, unsupported]
        ).map(\.text), ["B", "C"])
    }

    @MainActor
    func testPreviewSuccessFailureRetryDismissAndLateResponseDoNotMutatePersistence() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0)
        entry.translationText = "замок"
        entry.translationStatus = .ready
        context.insert(item)
        context.insert(entry)
        try context.save()
        let originalExport = try DictionaryTransferService.export(entries: [entry], includeContext: true)
        let originalPayload = try DictionaryTransferService.decode(originalExport.data).entries

        let source = "Zepsuł się zamek w kurtce."
        let preview = SelectionTranslationPreview(
            selectedText: "zamek", sourceLanguageCode: "pl",
            context: SelectionContext(text: source,
                                      selection: (source as NSString).range(of: "zamek")),
            sourceItemID: item.id, sourceTitle: item.title, audioRange: nil
        )
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        let service = NeverCompletingContextAnalysisService()
        coordinator.start(service: service)
        let first = try XCTUnwrap(coordinator.currentRequest())
        coordinator.acceptResult(
            token: first.token,
            previewID: preview.id,
            result: ContextualPhraseResult(
                directTranslation: "молния",
                contextExplanation: "В этом контексте речь идёт о застёжке."
            )
        )
        XCTAssertEqual(coordinator.selectedTranslation, "молния")
        XCTAssertEqual(coordinator.status, .ready)

        coordinator.retry(service: service)
        let failed = try XCTUnwrap(coordinator.currentRequest())
        coordinator.acceptResult(
            token: failed.token,
            previewID: preview.id,
            result: ContextualPhraseResult(directTranslation: "   ", contextExplanation: "explanation")
        )
        XCTAssertEqual(coordinator.status, .failed(ContextAnalysisError.invalidOutput.userMessage))
        coordinator.retry(service: service)
        let dismissed = try XCTUnwrap(coordinator.currentRequest())
        coordinator.dismiss()
        coordinator.acceptResult(
            token: dismissed.token,
            previewID: preview.id,
            result: ContextualPhraseResult(directTranslation: "stale", contextExplanation: "stale")
        )
        XCTAssertNil(coordinator.selectedTranslation)
        XCTAssertEqual(coordinator.status, .idle)

        let saved = try context.fetch(FetchDescriptor<DictionaryEntry>())
        let finalExport = try DictionaryTransferService.export(entries: saved, includeContext: true)
        let finalPayload = try DictionaryTransferService.decode(finalExport.data).entries
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(finalPayload.map(\.id), originalPayload.map(\.id))
        XCTAssertEqual(finalPayload.map(\.text), originalPayload.map(\.text))
        XCTAssertEqual(finalPayload.map(\.translation.text), originalPayload.map(\.translation.text))
        XCTAssertEqual(finalPayload.map(\.learningLevel), originalPayload.map(\.learningLevel))
    }

    func testExpandedSelectionUsesOneValidatedRangeForTextContextAndAudioMapping() throws {
        let text = "On powiedział: Zepsuł się zamek."
        let partial = (text as NSString).range(of: "epsuł si")
        let selection = try XCTUnwrap(
            TranscriptTextView.Coordinator.validatedExpandedSelection(in: text, selection: partial)
        )
        XCTAssertEqual(selection.text, "Zepsuł się")
        XCTAssertEqual((text as NSString).substring(with: selection.range), selection.text)
        XCTAssertNotNil(TranscriptTextView.Coordinator.context(in: text, selection: selection.range))
    }

    func testFollowOffsetClampsFirstMiddleLastShortAndAsymmetricInsets() throws {
        XCTAssertEqual(try XCTUnwrap(TranscriptFollowLayout.targetOffsetY(
            lineRect: CGRect(x: 0, y: 10, width: 20, height: 20),
            boundsHeight: 200, contentHeight: 800, adjustedTop: 20, adjustedBottom: 10
        )), -20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(TranscriptFollowLayout.targetOffsetY(
            lineRect: CGRect(x: 0, y: 390, width: 20, height: 20),
            boundsHeight: 200, contentHeight: 800, adjustedTop: 20, adjustedBottom: 10
        )), 295, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(TranscriptFollowLayout.targetOffsetY(
            lineRect: CGRect(x: 0, y: 780, width: 20, height: 20),
            boundsHeight: 200, contentHeight: 800, adjustedTop: 20, adjustedBottom: 10
        )), 610, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(TranscriptFollowLayout.targetOffsetY(
            lineRect: CGRect(x: 0, y: 40, width: 20, height: 20),
            boundsHeight: 200, contentHeight: 120, adjustedTop: 15, adjustedBottom: 25
        )), -15, accuracy: 0.001)
        XCTAssertNil(TranscriptFollowLayout.targetOffsetY(
            lineRect: .zero, boundsHeight: 20, contentHeight: 100,
            adjustedTop: 10, adjustedBottom: 10
        ))
    }

    func testFollowReadingZoneAndForcedReturn() throws {
        func offset(_ lineY: CGFloat, force: Bool = false) -> CGFloat? {
            TranscriptFollowLayout.followOffsetY(
                lineRect: CGRect(x: 0, y: lineY - 10, width: 20, height: 20),
                currentOffset: 200, boundsHeight: 500, contentHeight: 2000,
                adjustedTop: 20, adjustedBottom: 30, force: force
            )
        }
        XCTAssertNil(offset(400), "A cue inside the reading zone must not move the text")
        XCTAssertNil(offset(490), "The lower edge is still inside the reading zone")
        XCTAssertEqual(try XCTUnwrap(offset(500)), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(offset(350)), 150, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(offset(430, force: true)), 230, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(TranscriptFollowLayout.followOffsetY(
            lineRect: CGRect(x: 0, y: 50, width: 20, height: 20),
            currentOffset: 0, boundsHeight: 500, contentHeight: 100,
            adjustedTop: 20, adjustedBottom: 30, force: true
        )), -20, accuracy: 0.001)
    }

    @MainActor
    func testFollowRecomputesAfterLayoutAndExplicitResume() throws {
        final class RecordingTextView: UITextView {
            var destinations = [CGPoint]()
            override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
                destinations.append(contentOffset)
                super.setContentOffset(contentOffset, animated: false)
            }
        }
        let document = TranscriptDocument(segments: (0..<30).map {
            .init(start: Double($0), end: Double($0 + 1),
                  text: "A passage with several words for testing transcript layout.")
        })
        let representable = TranscriptTextView(
            document: document, activeSegment: 15, following: .constant(true),
            followGeneration: 0, onSelectionBegan: {}, handleSelection: { _, _, _, _, _ in }
        )
        let coordinator = representable.makeCoordinator()
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let view = RecordingTextView(frame: .zero, textContainer: container)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        view.font = .systemFont(ofSize: 17)
        coordinator.apply(to: view)
        view.layoutIfNeeded()
        coordinator.applyFollow(to: view)
        let original = try XCTUnwrap(view.destinations.last).y
        view.destinations.removeAll()
        coordinator.applyFollow(to: view)
        XCTAssertTrue(view.destinations.isEmpty, "Unchanged layout must not restart scrolling")

        view.contentSize.height += 50
        coordinator.applyFollow(to: view)
        XCTAssertTrue(view.destinations.isEmpty, "Estimated content height changes must not interrupt the same cue's scrolling")

        view.textContainerInset.top += 100
        view.layoutIfNeeded()
        coordinator.applyFollow(to: view)
        XCTAssertEqual(try XCTUnwrap(view.destinations.last).y, original + 100, accuracy: 1)

        view.setContentOffset(.zero, animated: false)
        coordinator.resetFollow(in: view)
        coordinator.applyFollow(to: view)
        XCTAssertEqual(try XCTUnwrap(view.destinations.last).y, original + 100, accuracy: 1)

        view.selectedRange = NSRange(location: 10, length: 4)
        view.destinations.removeAll()
        coordinator.applyFollow(to: view)
        XCTAssertTrue(view.destinations.isEmpty, "Selection must prevent automatic movement")
    }

    @MainActor
    func testTextKitUsesFirstVisualLineOfLongCueAndSelectionPausesOnce() throws {
        var following = true
        var pauseCount = 0
        let cue = String(repeating: "Long phrase wrapping across the display. ", count: 20)
        let document = TranscriptDocument(segments: [.init(start: 0, end: 10, text: cue)])
        let representable = TranscriptTextView(
            document: document, activeSegment: 0,
            following: Binding(get: { following }, set: { following = $0 }),
            followGeneration: 0,
            onSelectionBegan: { pauseCount += 1 },
            handleSelection: { _, _, _, _, _ in }
        )
        let coordinator = representable.makeCoordinator()
        let textView = TranscriptTextView.LayoutAwareTextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 260, height: 300)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 40, right: 16)
        textView.text = document.text
        textView.layoutIfNeeded()
        let firstLine = try XCTUnwrap(TranscriptTextView.Coordinator.firstVisualLineRect(
            for: document.ranges[0], in: textView
        ))
        XCTAssertLessThan(firstLine.minY, 60, "The helper must return the cue's first visual line")

        textView.selectedRange = NSRange(location: 1, length: 3)
        coordinator.textViewDidChangeSelection(textView)
        textView.selectedRange = NSRange(location: 2, length: 4)
        coordinator.textViewDidChangeSelection(textView)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertFalse(following)
        textView.selectedRange = NSRange(location: 0, length: 0)
        coordinator.textViewDidChangeSelection(textView)
        textView.selectedRange = NSRange(location: 5, length: 2)
        coordinator.textViewDidChangeSelection(textView)
        XCTAssertEqual(pauseCount, 2)
    }

    @MainActor
    func testPlaybackRateIsSessionLocalAndPauseDoesNotStartPlayback() {
        let playback = PlaybackController()
        XCTAssertEqual(playback.selectedRate, .normal)
        playback.setRate(.threeQuarters)
        XCTAssertEqual(playback.selectedRate, .threeQuarters)
        XCTAssertFalse(playback.wantsToPlay)
        playback.pause()
        XCTAssertFalse(playback.isPlaying)
        playback.close()
        XCTAssertEqual(playback.selectedRate, .threeQuarters)
        XCTAssertEqual(PlaybackController().selectedRate, .normal)
    }

    @MainActor
    func testPhraseAudioResolverRequiresMatchingLocalFileAndValidRange() {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0,
                                    audioStart: 2, audioEnd: 3)
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item],
                                                       fileExists: { _ in false }))
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item],
                                                         fileExists: { _ in true })?.identity.range,
                       2...3)
        entry.audioEnd = 11
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item],
                                                       fileExists: { _ in true }))
        entry.audioStart = 4
        entry.audioEnd = 3
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item],
                                                       fileExists: { _ in true }))
    }
}

extension LearningUXTests {
    @MainActor private func previewEntry(level: Int = 1) -> DictionaryEntry {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "story.m4a", transcriptFilename: "story.srt", duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: nil)
        entry.translationText = "замок"
        entry.translationStatus = .ready
        entry.learningLevel = level
        return entry
    }

    @MainActor func testPreviewSkipExcludesWordWithoutMutatingOrSaving() throws {
        let entry = previewEntry(level: 2), next = previewEntry()
        var preview = LearningPreviewState(selection: .five, selectedIDs: [entry.id, next.id])
        let presentation = preview.currentPresentationID
        XCTAssertTrue(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: presentation, action: .skip, save: { XCTFail("Skip must not save") }))
        XCTAssertEqual(entry.learningLevel, 2)
        XCTAssertEqual(preview.currentID, next.id)
        XCTAssertTrue(preview.learningIDs.isEmpty)
        XCTAssertFalse(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: presentation, action: .skip, save: { XCTFail("Stale skip must not save") }))
        XCTAssertTrue(try LearningPreviewTransaction.apply(entry: next, preview: &preview,
            presentationID: preview.currentPresentationID, action: .skip,
            save: { XCTFail("Skip must not save") }))
        XCTAssertTrue(preview.isComplete)
        XCTAssertTrue(preview.learningIDs.isEmpty)
    }

    @MainActor func testPreviewCollectsOnlyStartLearningAndTransitionsToNormalRound() throws {
        let entries = [previewEntry(), previewEntry(level: 2), previewEntry()]
        var preview = LearningPreviewState(selection: .five, selectedIDs: entries.map(\.id) + [entries[0].id])
        XCTAssertEqual(preview.selectedIDs.count, 3)
        for (entry, action) in zip(entries, [LearningPreviewAction.startLearning, .moveToNextLevel, .markAsKnown]) {
            XCTAssertTrue(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
                presentationID: preview.currentPresentationID, action: action, save: {}))
        }
        XCTAssertTrue(preview.isComplete)
        XCTAssertEqual(preview.reviewedCount, 3)
        XCTAssertEqual(preview.learningIDs, [entries[0].id])
        XCTAssertEqual(entries.map(\.learningLevel), [1, 3, 4])
        let round = LearningRoundState(selection: preview.selection, selectedIDs: preview.learningIDs)
        XCTAssertEqual(round.currentID, entries[0].id)
        XCTAssertEqual(round.wrongAttemptCount, 0)
        XCTAssertEqual(round.rightAttemptCount, 0)
        XCTAssertTrue(round.hasValidPartition)
    }

    @MainActor func testPreviewFailedSaveKeepsCardAndLevelAndRejectsStaleDoubleTap() throws {
        struct FailedSave: Error {}
        let entry = previewEntry(level: 3)
        var preview = LearningPreviewState(selection: .five, selectedIDs: [entry.id])
        let original = preview
        for action in [LearningPreviewAction.moveToNextLevel, .markAsKnown] {
            XCTAssertThrowsError(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
                presentationID: preview.currentPresentationID, action: action, save: { throw FailedSave() }))
            XCTAssertEqual(entry.learningLevel, 3)
            XCTAssertEqual(preview, original)
        }
        var saves = 0
        XCTAssertTrue(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: original.currentPresentationID, action: .moveToNextLevel, save: { saves += 1 }))
        XCTAssertEqual(entry.learningLevel, 4)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: original.currentPresentationID, action: .moveToNextLevel, save: { saves += 1 }))
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(preview.learningIDs.isEmpty)
    }

    @MainActor func testPreviewStartLearningDoesNotMutateOrSaveAndSkipHandlesMissingEntry() throws {
        let entry = previewEntry(level: 2)
        let missing = UUID()
        var preview = LearningPreviewState(selection: .five, selectedIDs: [missing, entry.id])
        let stale = preview.currentPresentationID
        XCTAssertTrue(preview.advance(entryID: missing, presentationID: stale, learn: false))
        XCTAssertFalse(preview.advance(entryID: entry.id, presentationID: stale, learn: false))
        XCTAssertTrue(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: preview.currentPresentationID, action: .startLearning,
            save: { XCTFail("Start learning does not change stored progress") }))
        XCTAssertEqual(entry.learningLevel, 2)
        XCTAssertEqual(preview.learningIDs, [entry.id])
    }
}
