import SwiftData
import SwiftUI

struct SelectionTranslationView: View {
    @Environment(\.dismiss) private var dismiss
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
                Section("Phrase translation") {
                    translationContent
                    if let value = coordinator.selectedTranslation {
                        CopyButton(value: value, label: "Copy phrase translation",
                                   identifier: "preview.copy-translation")
                    }
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
                    Section("Sentence translation") {
                        if let value = coordinator.sentenceTranslation {
                            Text(value).textSelection(.enabled)
                            CopyButton(value: value, label: "Copy sentence translation",
                                       identifier: "preview.copy-sentence-translation")
                        } else if case .failed(let message) = coordinator.status {
                            Text(message).foregroundStyle(.red)
                        } else {
                            ProgressView()
                        }
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
            .task { coordinator.start() }
            .translationTask(coordinator.configuration, action: coordinator.perform(session:))
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

    @ViewBuilder private var translationContent: some View {
        switch coordinator.status {
        case .idle, .preparing:
            HStack { ProgressView(); Text("Preparing translation…") }
        case .translating:
            HStack { ProgressView(); Text("Translating phrase…") }
        case .ready:
            if let value = coordinator.selectedTranslation {
                Text(value).textSelection(.enabled)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry() }
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
