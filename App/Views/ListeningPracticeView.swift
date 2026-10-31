import SwiftUI

/// An ephemeral round: never writes dictionary levels, checkpoints or activity history.
struct ListeningPracticeView: View {
    let entries: [DictionaryEntry]
    let books: [LearningItem]
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [Card] = []
    @State private var prepared = false
    @State private var index = 0
    @State private var options: [String] = []
    @State private var correct: String?
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = false
    @State private var revision = 0
    @State private var playback = PlaybackController()
    @State private var openedAudio = false

    private struct Card: Sendable {
        let input: ListeningInput
        let audio: PhraseAudioSource
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !prepared {
                        ProgressView()
                    } else if cards.isEmpty {
                        Text("No dictionary phrases with available audio and a saved translation.")
                    } else if index >= cards.count {
                        Text("Listening practice complete").font(.title2)
                        Text("Progress has not been saved. Your phrase levels are unchanged.")
                        Button("Finish") { dismiss() }.nativePrimaryAction()
                    } else {
                        Text(AppLanguage.format("Phrase %d of %d", index + 1, cards.count))
                            .font(.headline)
                        Button(action: play) {
                            Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title).frame(maxWidth: .infinity, minHeight: 80)
                        }
                        .accessibilityIdentifier("listening.play")
                        if let message = playback.errorMessage { Text(message).foregroundStyle(.red) }
                        if loading { ProgressView("Preparing translations…") }
                        if let error {
                            Text(error).foregroundStyle(.red)
                            Button("Retry") { revision += 1 }
                            Button("Skip") { advance() }
                        }
                        ForEach(options, id: \.self) { option in
                            Button {
                                guard selected == nil else { return }
                                selected = option
                            } label: {
                                HStack {
                                    Text(option).multilineTextAlignment(.leading)
                                    Spacer()
                                    if selected != nil, option == correct {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if selected == option {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                    }
                                }
                                .padding().frame(maxWidth: .infinity, minHeight: 56)
                                .background(NativeDesign.surface, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
                            }
                            .buttonStyle(.plain)
                            .disabled(selected != nil)
                        }
                        if selected != nil {
                            Text(selected == correct ? "Correct" : "Incorrect")
                                .foregroundStyle(selected == correct ? Color.green : .red)
                            Button(index + 1 == cards.count ? "Finish" : "Next") { advance() }
                                .nativePrimaryAction()
                        }
                    }
                }
                .padding()
            }
            .background(NativeDesign.page)
            .navigationTitle("Listening practice")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            guard !prepared else { return }
            let candidates = entries.filter { $0.hasTranslation }.shuffled().map { entry in
                (ListeningInput(phrase: entry.text, dictionaryTranslation: entry.translationText ?? "", sourceLanguage: entry.sourceLanguageCode,
                                targetLanguage: entry.targetLanguageCode), PhraseAudioRequest(entry: entry, items: books))
            }
            let worker = Task.detached(priority: .userInitiated) {
                var result: [Card] = []
                for (input, request) in candidates {
                    guard !Task.isCancelled else { break }
                    if let audio = request.resolve() { result.append(Card(input: input, audio: audio)) }
                    if result.count == 10 { break }
                }
                return result
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            cards = result
            prepared = true
        }
        .task(id: "\(prepared)-\(index)-\(revision)") { await generate() }
        .onDisappear { playback.close() }
    }

    private func generate() async {
        guard prepared, index < cards.count else { return }
        loading = true
        error = nil
        do {
            guard ContextAnalysisSettings.isCloudAnalysisEnabled(),
                  let key = try OpenAIAPIKeyStore.load(), !key.isEmpty else {
                throw ContextAnalysisError.missingConfiguration
            }
            let provider = OpenAIListeningProvider(apiKey: key, model: ContextAnalysisSettings.selectedModel())
            let result = try await provider.generate(cards[index].input)
            try Task.checkCancellation()
            correct = result.correct
            options = ([result.correct] + result.distractors).shuffled()
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = AppLanguage.text((error as? ContextAnalysisError ?? .unknown).userMessage)
            loading = false
        }
    }

    private func advance() {
        playback.close()
        openedAudio = false
        selected = nil
        correct = nil
        options = []
        error = nil
        index += 1
    }

    private func play() {
        let source = cards[index].audio
        if openedAudio { playback.toggle() }
        else {
            playback.open(url: source.identity.url, position: source.identity.range.lowerBound, range: source.identity.range)
            // Keep the hidden source phrase out of system playback metadata too.
            playback.mediaTitle = AppLanguage.text("Listening practice")
            playback.mediaSubtitle = ""
            openedAudio = true
            playback.play()
        }
    }
}
