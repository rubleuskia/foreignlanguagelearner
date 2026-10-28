import SwiftUI

/// Immutable values cross to the worker; managed SwiftData objects stay on the UI executor.
struct PhraseAudioRequest: Equatable, Sendable {
    let entry: PhraseAudioSourceResolver.EntrySnapshot?
    let preview: SelectionTranslationPreview?
    let items: [PhraseAudioSourceResolver.ItemSnapshot]
    let mode: PhraseAudioMode
    let ignoreManualRange: Bool

    init(entry: DictionaryEntry, items: [LearningItem], mode: PhraseAudioMode = .selection,
         ignoreManualRange: Bool = false) {
        self.entry = .init(entry)
        preview = nil
        self.items = PhraseAudioSourceResolver.snapshots(items, localID: entry.localSourceItemID, sourceID: entry.sourceItemID)
        self.mode = mode
        self.ignoreManualRange = ignoreManualRange
    }

    init(preview: SelectionTranslationPreview, items: [LearningItem]) {
        entry = nil
        self.preview = preview
        self.items = PhraseAudioSourceResolver.snapshots(items, localID: nil, sourceID: preview.sourceItemID)
        mode = .selection
        ignoreManualRange = false
    }

    func resolve(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> PhraseAudioSource? {
        if let entry {
            return PhraseAudioSourceResolver.resolve(entry: entry, items: items, mode: mode, ignoreManualRange: ignoreManualRange, fileExists: fileExists)
        }
        if let preview { return PhraseAudioSourceResolver.resolve(preview: preview, items: items, fileExists: fileExists) }
        return nil
    }
}

/// Resolve only when audio inputs change, never on keystrokes, playback ticks or slider drags.
struct ResolvedPhraseAudio<Content: View>: View {
    let request: PhraseAudioRequest
    @ViewBuilder let content: (PhraseAudioSource?) -> Content
    @State private var completedRequest: PhraseAudioRequest?
    @State private var source: PhraseAudioSource?

    var body: some View {
        Group {
            if completedRequest == request { content(source) }
            else { ProgressView() }
        }
        .task(id: request) {
            let snapshot = request
            let worker = Task.detached(priority: .userInitiated) { snapshot.resolve() }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            source = value
            completedRequest = snapshot
        }
    }
}
