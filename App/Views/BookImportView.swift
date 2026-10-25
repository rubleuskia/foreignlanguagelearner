import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookImportView: View {
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var archiveURL: URL?
    @State private var preview: BookImportService.Preview?
    @State private var title = ""
    @State private var sourceLanguageCode = "pl"
    @State private var selectedTranscript: String?
    @State private var externalTranscript: URL?
    @State private var pickingArchive = false
    @State private var pickingTranscript = false
    @State private var processing = false
    @State private var progressMessage = ""
    @State private var errorMessage: String?
    @State private var work: Task<Void, Never>?

    @State private var wordPreview: VocabularyImportPreview?
    @State private var wordPreviewKey: String?
    @State private var wordError: String?
    private var previewKey: String { "\(preview?.id.uuidString ?? ""):\(selectedTranscript ?? ""):\(externalTranscript?.absoluteString ?? ""):\(sourceLanguageCode)" }

    @State private var service = BookImportService()
    private let zipType = UTType(filenameExtension: "zip") ?? .data

    var body: some View {
        NavigationStack {
            Form {
                Section("Archive") {
                    Button(archiveURL?.lastPathComponent ?? "Choose ZIP or .book.zip") { pickingArchive = true }
                        .fileImporter(isPresented: $pickingArchive, allowedContentTypes: [zipType]) { result in
                            switch result {
                            case .success(let url): archiveURL = url; loadPreview(url)
                            case .failure(let error): errorMessage = error.localizedDescription
                            }
                        }
                    if processing { HStack { ProgressView(); Text(progressMessage) } }
                }
                if let value = preview {
                    Section("Book") {
                        TextField("Title", text: $title)
                        TextField("Source language tag", text: $sourceLanguageCode)
                            .textInputAutocapitalization(.never)
                            .disabled(value.isManifestPackage)
                    }
                    Section {
                        if value.transcriptCandidates.count == 1 {
                            LabeledContent("Transcript", value: value.transcriptCandidates[0])
                        } else if !value.transcriptCandidates.isEmpty {
                            Picker("Transcript", selection: Binding(
                                get: { selectedTranscript ?? "" },
                                set: { selectedTranscript = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("Choose a TXT file").tag("")
                                ForEach(value.transcriptCandidates, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Button(externalTranscript?.lastPathComponent ?? "Choose a separate TXT") { pickingTranscript = true }
                            .fileImporter(isPresented: $pickingTranscript, allowedContentTypes: [.plainText]) { result in
                                switch result {
                                case .success(let url): externalTranscript = url
                                case .failure(let error): errorMessage = error.localizedDescription
                                }
                            }
                    } header: { Text("Transcript") } footer: {
                        Text("Plain TXT is read as full untimed text. Subtitle files in raw ZIPs are ignored; timed tracks require a book manifest.")
                    }
                    Section("Reading vocabulary") {
                        ReadingVocabularyStatus()
                        VocabularyStatisticsView(words: wordPreviewKey == previewKey ? wordPreview?.words : nil,
                                                 language: sourceLanguageCode, error: wordError)
                        if wordError != nil { Button("Retry word count") { wordPreviewKey = nil; Task { await countWords() } } }
                    }
                    Section {
                        ForEach(value.tracks) { track in
                            VStack(alignment: .leading) {
                                TextField("Track title", text: Binding(
                                    get: { preview?.tracks.first(where: { $0.id == track.id })?.title ?? track.title },
                                    set: { updateTrack(track.id, title: $0) }
                                ))
                                .disabled(value.isManifestPackage)
                                Text("\(track.sourcePath) · \(formatTime(track.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if track.alignmentStatus == .reviewRequired {
                                    Label("Timing review required", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .onMove { from, to in
                            guard !value.isManifestPackage else { return }
                            var reordered = preview?.tracks ?? []
                            reordered.move(fromOffsets: from, toOffset: to)
                            preview?.tracks = reordered
                        }
                    } header: { Text("Tracks") } footer: {
                        Text(value.isManifestPackage
                             ? "Manifest order and track IDs are fixed."
                             : "This natural filename order is a suggestion. Reorder before importing; track IDs remain stable.")
                    }
                    if value.ignoredFileCount > 0 {
                        Section { Text("\(value.ignoredFileCount) unrelated file(s) will be ignored.") }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(processing)
            .environment(\.editMode, .constant(.active))
            .nativeForm()
            .navigationTitle("Import audiobook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(processing ? "Cancel" : "Close") {
                        if processing { work?.cancel() } else { cancelAndDismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importBook() }
                        .nativePrimaryAction()
                        .disabled(preview == nil || processing || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasTranscript || wordPreviewKey != previewKey || wordPreview == nil || !vocabulary.ready)
                }
            }
            .interactiveDismissDisabled(processing)
            .task(id: previewKey) { await countWords() }
        }
    }

    private var hasTranscript: Bool {
        externalTranscript != nil || selectedTranscript != nil || preview?.selectedTranscript != nil
    }

    private func loadPreview(_ url: URL) {
        work?.cancel()
        if let old = preview { Task { await service.cancel(old) } }
        preview = nil; externalTranscript = nil; selectedTranscript = nil
        processing = true; progressMessage = "Validating and reading archive…"; errorMessage = nil
        work = Task {
            do {
                let loaded = try await service.previewArchive(url)
                guard !Task.isCancelled else { await service.cancel(loaded); return }
                preview = loaded
                title = loaded.title
                sourceLanguageCode = loaded.sourceLanguage
                selectedTranscript = loaded.selectedTranscript
            } catch is CancellationError {
                errorMessage = "Import cancelled. No library files were changed."
            } catch {
                errorMessage = error.localizedDescription
            }
            processing = false
        }
    }

    private func importBook() {
        guard let preview else { return }
        processing = true; progressMessage = "Committing book…"; errorMessage = nil
        work = Task {
            do {
                let language = try VocabularyTokenizer.language(sourceLanguageCode)
                let latest = try await service.vocabularyPreview(preview, transcriptPath: selectedTranscript, externalTranscript: externalTranscript)
                guard latest.fingerprint == wordPreview?.fingerprint else {
                    wordPreview = latest; wordPreviewKey = previewKey
                    throw ReadingVocabularyError.changed
                }
                let prepared = try await service.prepare(preview, title: title,
                    sourceLanguage: language, orderedTracks: preview.tracks,
                    transcriptPath: selectedTranscript, externalTranscript: externalTranscript)
                let staged = try await service.vocabularyPreview(prepared)
                try Task.checkCancellation()
                guard staged.fingerprint == latest.fingerprint else {
                    wordPreview = staged; wordPreviewKey = previewKey
                    throw ReadingVocabularyError.changed
                }
                try await service.movePreparedToLibrary(prepared)
                let item = LearningItem(id: prepared.itemID, title: prepared.title, mediaKind: "audio",
                                        mediaFilename: "", transcriptFilename: prepared.transcriptFilename,
                                        duration: prepared.duration, segments: [], sourceLanguageCode: prepared.sourceLanguage,
                                        tracks: prepared.tracks, lastTrackID: prepared.tracks.first?.id)
                item.readingVocabularyMigrationVersion = 1
                context.insert(item)
                do { try context.save() }
                catch {
                    context.delete(item)
                    await service.rollback(prepared)
                    throw error
                }
                await service.complete(prepared)
                dismiss()
            } catch is CancellationError {
                errorMessage = "Import cancelled. No library files were changed."
            } catch {
                errorMessage = error.localizedDescription
            }
            processing = false
        }
    }

    @MainActor private func countWords() async {
        let key = previewKey
        wordError = nil
        guard let preview, hasTranscript else { wordPreview = nil; wordPreviewKey = nil; return }
        do {
            _ = try VocabularyTokenizer.language(sourceLanguageCode)
            let result = try await service.vocabularyPreview(preview, transcriptPath: selectedTranscript, externalTranscript: externalTranscript)
            try Task.checkCancellation()
            guard key == previewKey else { return }
            wordPreview = result; wordPreviewKey = key
        } catch is CancellationError { }
        catch { if key == previewKey { wordError = error.localizedDescription; wordPreview = nil } }
    }

    private func updateTrack(_ id: String, title: String) {
        guard let index = preview?.tracks.firstIndex(where: { $0.id == id }) else { return }
        preview?.tracks[index].title = title
    }

    private func cancelAndDismiss() {
        if let preview { Task { await service.cancel(preview) } }
        dismiss()
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
