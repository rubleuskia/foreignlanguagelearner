import SwiftUI

struct ContentView: View {
    @State private var session = PracticeSession.sample

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("A little practice, every day")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Polish • Sample flashcard")
                    .foregroundStyle(.secondary)

                Text(session.word)
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("practice.word")

                if session.isTranslationVisible {
                    Text(session.translation)
                        .font(.title)
                        .accessibilityIdentifier("practice.translation")
                    Button("Practice again") {
                        session.restart()
                    }
                    .accessibilityIdentifier("practice.restart")
                } else {
                    Button("Show translation") {
                        session.revealTranslation()
                    }
                    .accessibilityIdentifier("practice.reveal")
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Language Learner")
        }
    }
}

#Preview {
    ContentView()
}
