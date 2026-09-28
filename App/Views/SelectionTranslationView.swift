import SwiftData
import SwiftUI

struct SelectionTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contextAnalysisService) private var contextAnalysisService
    @Query private var sourceItems: [LearningItem]
    let preview: SelectionTranslationPreview
    @State private var coordinator: SelectionTranslationCoordinator
    @State private var playback = PlaybackController()
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?

    init(preview: SelectionTranslationPreview) {
        self.preview = preview
        _coordinator = State(initialValue: SelectionTranslationCoordinator(preview: preview))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Context explanation") {
                    analysisContent
                }
                Section("Original") {
                    Text(preview.selectedText).textSelection(.enabled)
                    CopyButton(value: preview.selectedText, label: "Copy original",
                               identifier: "preview.copy-original")
                }
                Section("Audio") { audioContent }
                if let sentence = coordinator.sourceSentence {
                    Section("Source sentence") {
                        Text(sentence).textSelection(.enabled)
                        CopyButton(value: sentence, label: "Copy source sentence",
                                   identifier: "preview.copy-source-sentence")
                    }
                } else if coordinator.contextUnavailable {
                    Section("Source context") {
                        Label("Context is unavailable", systemImage: "text.badge.xmark")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Source") { Text(preview.sourceTitle) }
            }
            .navigationTitle("Translate in Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { coordinator.start(service: contextAnalysisService) }
            .onDisappear {
                coordinator.dismiss()
                playback.close()
                openedAudioIdentity = nil
            }
            .alert("Playback error", isPresented: Binding(
                get: { playback.errorMessage != nil },
                set: { if !$0 { playback.errorMessage = nil } }
            )) { Button("OK") {} } message: { Text(playback.errorMessage ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var analysisContent: some View {
        switch coordinator.status {
        case .idle, .preparing:
            HStack { ProgressView(); Text("Preparing translation…") }
        case .translating:
            HStack { ProgressView(); Text("Translating phrase…") }
        case .ready:
            if let explanation = coordinator.contextExplanation,
               let translation = coordinator.selectedTranslation {
                Text(explanation)
                    .textSelection(.enabled)
                CopyButton(value: explanation, label: "Copy word explanations",
                           identifier: "preview.copy-word-explanations")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overall translation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(translation).textSelection(.enabled)
                }
                CopyButton(value: translation, label: "Copy phrase translation",
                           identifier: "preview.copy-translation")
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Retry", systemImage: "arrow.clockwise") {
                coordinator.retry(service: contextAnalysisService)
            }
        }
    }

    @ViewBuilder private var audioContent: some View {
        if let source = PhraseAudioSourceResolver.resolve(preview: preview, items: sourceItems) {
            HStack {
                Button {
                    toggleAudio(source)
                } label: {
                    Label(playback.isPlaying ? "Pause phrase" : "Play phrase",
                          systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                }
                .accessibilityIdentifier("preview.play-audio")
                Spacer()
                PlaybackRateMenu(playback: playback)
            }
        } else {
            Label("Audio unavailable on this device", systemImage: "speaker.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func toggleAudio(_ source: PhraseAudioSource) {
        if openedAudioIdentity != source.identity {
            playback.open(url: source.identity.url, position: source.identity.range.lowerBound,
                          range: source.identity.range)
            openedAudioIdentity = source.identity
            playback.play()
        } else {
            playback.toggle()
        }
    }
}
