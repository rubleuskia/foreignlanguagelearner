import SwiftUI
import SwiftData

@main
struct ForeignLanguageLearnerApp: App {
    @AppStorage(AppLanguage.key) private var selectedLanguage = "ru"
    @State private var readingVocabulary = ReadingVocabularyStore(indexURL: ProcessInfo.processInfo.arguments.contains("--uitesting") ? nil : VocabularyIndex.defaultURL)
    @State private var translationCoordinator = DictionaryTranslationCoordinator()
    private let contextAnalysisService = ContextAnalysisService()
    private var wordExplanationService: any WordExplanationServing {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting"),
           ProcessInfo.processInfo.arguments.contains("--word-explanation-fixture") {
            return WordExplanationUIFixture()
        }
        #endif
        return liveWordExplanationService
    }
    private let liveWordExplanationService = WordExplanationService()

    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-interface-language") {
            UserDefaults.standard.set("ru", forKey: AppLanguage.key)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(\.locale, Locale(identifier:
                ProcessInfo.processInfo.arguments.contains("--uitesting") &&
                !ProcessInfo.processInfo.arguments.contains("--test-russian-ui")
                    ? "en" : AppLanguage.resolved(selectedLanguage)))
        }
            .modelContainer(for: [LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self], inMemory: ProcessInfo.processInfo.arguments.contains("--uitesting"))
            .environment(translationCoordinator)
            .environment(readingVocabulary)
            .environment(\.contextAnalysisService, contextAnalysisService)
            .environment(\.wordExplanationService, wordExplanationService)
    }
}

#if DEBUG
private struct WordExplanationUIFixture: WordExplanationServing {
    func explain(_ input: WordExplanationInput) async throws -> WordExplanation {
        try Task.checkCancellation()
        return .init(definition: "Часть суток, когда светло. В приветствии это слово входит в пожелание хорошего дня.",
                     meaningInContext: "Здесь человек вежливо здоровается.", examples: [
                        .init(phrase: "dzień dobry", translation: "добрый день"),
                        .init(phrase: "miłego dnia", translation: "хорошего дня")])
    }
}
#endif
