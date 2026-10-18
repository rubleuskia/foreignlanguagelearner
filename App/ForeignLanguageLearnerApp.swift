import SwiftUI
import SwiftData

@main
struct ForeignLanguageLearnerApp: App {
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

    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [LearningItem.self, DictionaryEntry.self], inMemory: ProcessInfo.processInfo.arguments.contains("--uitesting"))
            .environment(translationCoordinator)
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
