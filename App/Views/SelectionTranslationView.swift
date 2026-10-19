import SwiftData
import SwiftUI

struct SelectionTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.contextAnalysisService) private var contextAnalysisService
    @Query private var sourceItems: [LearningItem]
    private var preview: SelectionTranslationPreview { coordinator.preview }
    let saveOnOpen: Bool
    @State private var coordinator: SelectionTranslationCoordinator
    @State private var playback = PlaybackController()
    @State private var openedAudioIdentity: PhraseAudioSource.Identity?

    init(coordinator: SelectionTranslationCoordinator, saveOnOpen: Bool = false) {
        self.saveOnOpen = saveOnOpen
        _coordinator = State(initialValue: coordinator)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Context explanation") {
                    analysisContent
                }
                Section {
                    Button(coordinator.savedEntryID != nil ? "Added to Dictionary" : "Add to Dictionary",
                           systemImage: coordinator.savedEntryID != nil ? "checkmark.circle.fill" : "text.badge.plus") {
                        coordinator.saveToDictionary(context: context, service: contextAnalysisService)
                    }
                    .disabled(coordinator.savedEntryID != nil || coordinator.isSaving)
                    .accessibilityIdentifier("preview.add-to-dictionary")
                    if coordinator.isSaving { Text("Translating before saving…").foregroundStyle(.secondary) }
                }
                Section("Original") {
                    CopyableContentRow(value: preview.selectedText, label: "Copy original",
                                       identifier: "preview.copy-original") {
                        Text(preview.selectedText).textSelection(.enabled)
                    }
                }
                Section("Audio") { audioContent }
                if let sentence = coordinator.sourceSentence {
                    Section("Source sentence") {
                        CopyableContentRow(value: sentence, label: "Copy source sentence",
                                           identifier: "preview.copy-source-sentence") {
                            Text(sentence).textSelection(.enabled)
                        }
                    }
                } else if coordinator.contextUnavailable {
                    Section("Source context") {
                        Label("Context is unavailable", systemImage: "text.badge.xmark")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Source") { Text(preview.sourceTitle) }
                Section { ExportLogsButton() }
            }
            .navigationTitle("Translate in Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                if saveOnOpen { coordinator.saveToDictionary(context: context, service: contextAnalysisService) }
                else { coordinator.start(service: contextAnalysisService) }
            }
            .onDisappear {
                coordinator.dismiss()
                playback.close()
                openedAudioIdentity = nil
            }
            .alert("Translation or playback error", isPresented: Binding(
                get: { coordinator.errorMessage != nil || playback.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil; playback.errorMessage = nil } }
            )) { Button("OK") {} } message: { Text(coordinator.errorMessage ?? playback.errorMessage ?? "") }
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
                if !explanation.isEmpty {
                    CopyableContentRow(value: explanation, label: "Copy word explanations",
                                       identifier: "preview.copy-word-explanations") {
                        ContextWordExplanationView(explanation: explanation, selectedText: preview.selectedText,
                            context: preview.context, sourceLanguage: preview.sourceLanguageCode,
                            targetLanguage: preview.targetLanguageCode)
                    }
                }
                CopyableContentRow(value: translation, label: "Copy phrase translation",
                                   identifier: "preview.copy-translation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Overall translation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(translation).textSelection(.enabled)
                    }
                }
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
