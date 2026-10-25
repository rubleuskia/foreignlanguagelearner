import Foundation

/// Restores observed model values as well as the persistent rollback after a failed import.
struct DictionaryEntryRollbackSnapshot {
    private let id: UUID
    private let text: String
    private let sourceItemID: UUID
    private let sourceTitle: String
    private let segmentIndex: Int?
    private let createdAt: Date
    private let sourceLanguageCode: String
    private let targetLanguageCode: String
    private let translationText: String?
    private let translationOriginRaw: String?
    private let translationStatusRaw: String
    private let translationErrorCode: String?
    private let translationUpdatedAt: Date?
    private let translationRevision: Int
    private let learningLevel: Int
    private let levelChangedAt: Date?
    private let localSourceItemID: UUID?
    private let audioStart: Double?
    private let phraseAudioStart: Double?
    private let phraseAudioEnd: Double?
    private let manualPhraseAudioStart: Double?
    private let manualPhraseAudioEnd: Double?
    private let manualAudioStart: Double?
    private let audioEnd: Double?
    private let manualAudioEnd: Double?
    private let sourceTrackID: String?
    private let contextText: String?
    private let contextSelectionLocation: Int?
    private let contextSelectionLength: Int?
    private let contextSelectedTranslationText: String?
    private let contextTranslationText: String?
    private let contextAnalysisUpdatedAt: Date?
    private let contextAnalysisRevision: Int
    private let wordHelpItems: [WordHelpItem]
    private let wordHelpUpdatedAt: Date?
    private let selectedSenseText: String?
    private let userNote: String?

    init(_ entry: DictionaryEntry) {
        id = entry.id
        text = entry.text
        sourceItemID = entry.sourceItemID
        sourceTitle = entry.sourceTitle
        segmentIndex = entry.segmentIndex
        createdAt = entry.createdAt
        sourceLanguageCode = entry.sourceLanguageCode
        targetLanguageCode = entry.targetLanguageCode
        translationText = entry.translationText
        translationOriginRaw = entry.translationOriginRaw
        translationStatusRaw = entry.translationStatusRaw
        translationErrorCode = entry.translationErrorCode
        translationUpdatedAt = entry.translationUpdatedAt
        translationRevision = entry.translationRevision
        learningLevel = entry.learningLevel
        levelChangedAt = entry.levelChangedAt
        localSourceItemID = entry.localSourceItemID
        audioStart = entry.audioStart
        phraseAudioStart = entry.phraseAudioStart
        phraseAudioEnd = entry.phraseAudioEnd
        manualPhraseAudioStart = entry.manualPhraseAudioStart
        manualPhraseAudioEnd = entry.manualPhraseAudioEnd
        manualAudioStart = entry.manualAudioStart
        audioEnd = entry.audioEnd
        manualAudioEnd = entry.manualAudioEnd
        sourceTrackID = entry.sourceTrackID
        contextText = entry.contextText
        contextSelectionLocation = entry.contextSelectionLocation
        contextSelectionLength = entry.contextSelectionLength
        contextSelectedTranslationText = entry.contextSelectedTranslationText
        contextTranslationText = entry.contextTranslationText
        contextAnalysisUpdatedAt = entry.contextAnalysisUpdatedAt
        contextAnalysisRevision = entry.contextAnalysisRevision
        wordHelpItems = entry.wordHelpItems
        wordHelpUpdatedAt = entry.wordHelpUpdatedAt
        selectedSenseText = entry.selectedSenseText
        userNote = entry.userNote
    }

    func restore(_ entry: DictionaryEntry) {
        entry.id = id
        entry.text = text
        entry.sourceItemID = sourceItemID
        entry.sourceTitle = sourceTitle
        entry.segmentIndex = segmentIndex
        entry.createdAt = createdAt
        entry.sourceLanguageCode = sourceLanguageCode
        entry.targetLanguageCode = targetLanguageCode
        entry.translationText = translationText
        entry.translationOriginRaw = translationOriginRaw
        entry.translationStatusRaw = translationStatusRaw
        entry.translationErrorCode = translationErrorCode
        entry.translationUpdatedAt = translationUpdatedAt
        entry.translationRevision = translationRevision
        entry.learningLevel = learningLevel
        entry.levelChangedAt = levelChangedAt
        entry.localSourceItemID = localSourceItemID
        entry.audioStart = audioStart
        entry.phraseAudioStart = phraseAudioStart
        entry.phraseAudioEnd = phraseAudioEnd
        entry.manualPhraseAudioStart = manualPhraseAudioStart
        entry.manualPhraseAudioEnd = manualPhraseAudioEnd
        entry.manualAudioStart = manualAudioStart
        entry.audioEnd = audioEnd
        entry.manualAudioEnd = manualAudioEnd
        entry.sourceTrackID = sourceTrackID
        entry.contextText = contextText
        entry.contextSelectionLocation = contextSelectionLocation
        entry.contextSelectionLength = contextSelectionLength
        entry.contextSelectedTranslationText = contextSelectedTranslationText
        entry.contextTranslationText = contextTranslationText
        entry.contextAnalysisUpdatedAt = contextAnalysisUpdatedAt
        entry.contextAnalysisRevision = contextAnalysisRevision
        entry.wordHelpItems = wordHelpItems
        entry.wordHelpUpdatedAt = wordHelpUpdatedAt
        entry.selectedSenseText = selectedSenseText
        entry.userNote = userNote
    }
}
