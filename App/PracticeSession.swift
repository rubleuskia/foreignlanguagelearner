struct PracticeSession {
    let word: String
    let translation: String
    private(set) var isTranslationVisible = false

    mutating func revealTranslation() {
        isTranslationVisible = true
    }

    mutating func restart() {
        isTranslationVisible = false
    }

    static let sample = PracticeSession(word: "Cześć", translation: "Hello")
}
