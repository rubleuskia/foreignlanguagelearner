import SwiftUI
import SwiftData

@main
struct ForeignLanguageLearnerApp: App {
    @State private var translationCoordinator = DictionaryTranslationCoordinator()
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [LearningItem.self, DictionaryEntry.self], inMemory: ProcessInfo.processInfo.arguments.contains("--uitesting"))
            .environment(translationCoordinator)
    }
}
