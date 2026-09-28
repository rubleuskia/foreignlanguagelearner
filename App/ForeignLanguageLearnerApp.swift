import SwiftUI
import SwiftData

@main
struct ForeignLanguageLearnerApp: App {
    @State private var translationCoordinator = DictionaryTranslationCoordinator()
    private let contextAnalysisService = ContextAnalysisService()
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [LearningItem.self, DictionaryEntry.self], inMemory: ProcessInfo.processInfo.arguments.contains("--uitesting"))
            .environment(translationCoordinator)
            .environment(\.contextAnalysisService, contextAnalysisService)
    }
}
