import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ForeignLanguageLearner

final class LearningUXTests: XCTestCase {
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
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
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
        coordinator.start()
        let first = try XCTUnwrap(coordinator.currentRequest())
        var values = [first.phraseRequestID: "молния"]
        values[try XCTUnwrap(first.sentenceRequestID)] = "В куртке сломалась молния."
        coordinator.acceptTranslations(token: first.token, previewID: preview.id, values: values)
        XCTAssertEqual(coordinator.selectedTranslation, "молния")
        XCTAssertEqual(coordinator.status, .ready)

        coordinator.retry()
        let failed = try XCTUnwrap(coordinator.currentRequest())
        coordinator.acceptTranslations(token: failed.token, previewID: preview.id,
                                       values: [failed.phraseRequestID: "   "])
        XCTAssertEqual(coordinator.status,
                       .failed("Translation returned no usable phrase translation."))
        coordinator.retry()
        let dismissed = try XCTUnwrap(coordinator.currentRequest())
        coordinator.dismiss()
        coordinator.acceptTranslations(token: dismissed.token, previewID: preview.id,
                                       values: [dismissed.phraseRequestID: "stale"])
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
