import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportItemView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var media: URL?
    @State private var transcript: URL?
    @State private var pickingMedia = false
    @State private var pickingTranscript = false
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var splitIntoParts = false
    @State private var partMinutes = 10
    @State private var sourceLanguageCode = "pl"
    @State private var sourceLanguages = [SourceLanguage.polish]

    @State private var wordPreview: VocabularyImportPreview?
    @State private var wordPreviewKey: String?
    @State private var wordError: String?
    private var previewKey: String { "\(transcript?.absoluteString ?? ""):\(sourceLanguageCode)" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    Button(media?.lastPathComponent ?? "Choose audio or video") { pickingMedia = true }
                        .accessibilityIdentifier("import.media")
                        .fileImporter(isPresented: $pickingMedia, allowedContentTypes: [.audio, .movie]) { result in
                            switch result { case .success(let url): media = url; case .failure(let error): errorMessage = error.localizedDescription }
                        }
                }
                Section {
                    Button(transcript?.lastPathComponent ?? "Choose transcript") { pickingTranscript = true }
                        .accessibilityIdentifier("import.transcript")
                        .fileImporter(isPresented: $pickingTranscript, allowedContentTypes: [.plainText, UTType(filenameExtension: "srt") ?? .data, UTType(filenameExtension: "vtt") ?? .data]) { result in
                            switch result { case .success(let url): transcript = url; case .failure(let error): errorMessage = error.localizedDescription }
                        }
                } header: { Text("Transcript") } footer: {
                    Text("SRT and WebVTT support synchronized scrolling. Plain UTF-8 text supports reading and phrase selection.")
                }
                Section {
                    Picker("Source language", selection: $sourceLanguageCode) {
                        ForEach(sourceLanguages) { language in Text(language.name).tag(language.code) }
                    }.accessibilityIdentifier("import.language")
                } header: { Text("Language") } footer: { Text("Used to translate saved phrases into Russian.") }
                Section {
                    Toggle("Split into parts", isOn: $splitIntoParts).accessibilityIdentifier("import.split")
                    if splitIntoParts { Stepper("Part length: \(partMinutes) minutes", value: $partMinutes, in: 1...60) }
                } header: { Text("Parts") } footer: { Text("Parts share the imported media file. Splitting requires a timed SRT or WebVTT transcript.") }
                if transcript != nil {
                    Section("Reading vocabulary") {
                        ReadingVocabularyStatus()
                        VocabularyStatisticsView(words: wordPreviewKey == previewKey ? wordPreview?.words : nil,
                                                 language: sourceLanguageCode, error: wordError)
                        if wordError != nil { Button("Retry word count") { Task { await countWords() } } }
                    }
                }
                if importing { ProgressView("Importing…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .nativeForm()
            .navigationTitle("Add material")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await importItem() } }
                        .nativePrimaryAction()
                        .disabled(media == nil || transcript == nil || importing || !vocabulary.ready || wordPreviewKey != previewKey || wordPreview == nil)
                }
            }
            .disabled(importing)
            .interactiveDismissDisabled(importing)
            .task(id: previewKey) { await countWords() }
            .task { sourceLanguages = await SourceLanguage.availableForRussian() }
        }
    }

    @MainActor private func countWords() async {
        let key = previewKey
        wordError = nil
        guard let transcript else { wordPreview = nil; return }
        do {
            _ = try VocabularyTokenizer.language(sourceLanguageCode)
            let job = Task.detached { try VocabularyImportPreview.file(transcript) }
            let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            try Task.checkCancellation()
            guard key == previewKey else { return }
            wordPreview = result; wordPreviewKey = key
        } catch is CancellationError { }
        catch { if key == previewKey { wordError = error.localizedDescription; wordPreview = nil } }
    }

    @MainActor private func importItem() async {
        guard let media, let transcript else { return }
        importing = true
        errorMessage = nil
        defer { importing = false }
        do {
            let language = try VocabularyTokenizer.language(sourceLanguageCode)
            let latest = try await Task.detached { try VocabularyImportPreview.file(transcript) }.value
            guard latest.fingerprint == wordPreview?.fingerprint else {
                wordPreview = latest; wordPreviewKey = previewKey
                throw ReadingVocabularyError.changed
            }
            let imported = try await MediaImportService().importFiles(media: media, transcript: transcript)
            let committedWords = try await Task.detached { try VocabularyImportPreview(text: imported.document.text) }.value
            guard committedWords.fingerprint == latest.fingerprint else {
                try? FileManager.default.removeItem(at: MediaImportService.directory(for: imported.id))
                wordPreview = committedWords; wordPreviewKey = previewKey
                throw ReadingVocabularyError.changed
            }
            let parts = splitIntoParts ? LearningPartPlanner.makeParts(segments: imported.document.segments, duration: imported.duration, targetDuration: Double(partMinutes * 60)) : []
            if splitIntoParts && parts.isEmpty {
                try? FileManager.default.removeItem(at: MediaImportService.directory(for: imported.id))
                throw TranscriptParser.ParseError.invalid("Splitting needs a timed transcript and media longer than the selected part length.")
            }
            let item = LearningItem(id: imported.id, title: imported.title, mediaKind: imported.mediaKind,
                                    mediaFilename: imported.mediaFilename, transcriptFilename: imported.transcriptFilename,
                                    duration: imported.duration, segments: imported.document.segments, parts: parts,
                                    sourceLanguageCode: language)
            item.readingVocabularyMigrationVersion = 1
            context.insert(item)
            do { try context.save() }
            catch {
                context.delete(item)
                try? FileManager.default.removeItem(at: MediaImportService.directory(for: imported.id))
                throw error
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
