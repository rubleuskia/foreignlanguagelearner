import Foundation

struct SelectionTranslationPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let selectedText: String
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let context: SelectionContext?
    let sourceItemID: UUID
    let sourceTitle: String
    let audioRange: ClosedRange<Double>?

    init(id: UUID = UUID(), selectedText: String, sourceLanguageCode: String,
         targetLanguageCode: String = "ru", context: SelectionContext?,
         sourceItemID: UUID, sourceTitle: String, audioRange: ClosedRange<Double>?) {
        self.id = id
        self.selectedText = selectedText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.context = context
        self.sourceItemID = sourceItemID
        self.sourceTitle = sourceTitle
        self.audioRange = audioRange
    }
}
