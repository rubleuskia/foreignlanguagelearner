import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportItemView: View {
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
                if importing { ProgressView("Importing…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Upload item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await importItem() } }
                        .disabled(media == nil || transcript == nil || importing)
                }
            }
            .disabled(importing)
            .interactiveDismissDisabled(importing)
            .task { sourceLanguages = await SourceLanguage.availableForRussian() }
        }
    }

    @MainActor private func importItem() async {
        guard let media, let transcript else { return }
        importing = true
        errorMessage = nil
        defer { importing = false }
        do {
            let imported = try await MediaImportService().importFiles(media: media, transcript: transcript)
            let parts = splitIntoParts ? LearningPartPlanner.makeParts(segments: imported.document.segments, duration: imported.duration, targetDuration: Double(partMinutes * 60)) : []
            if splitIntoParts && parts.isEmpty {
                try? FileManager.default.removeItem(at: MediaImportService.directory(for: imported.id))
                throw TranscriptParser.ParseError.invalid("Splitting needs a timed transcript and media longer than the selected part length.")
            }
            let item = LearningItem(id: imported.id, title: imported.title, mediaKind: imported.mediaKind,
                                    mediaFilename: imported.mediaFilename, transcriptFilename: imported.transcriptFilename,
                                    duration: imported.duration, segments: imported.document.segments, parts: parts,
                                    sourceLanguageCode: sourceLanguageCode)
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
