import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookImportView: View {
    enum Source: String, CaseIterable, Identifiable {
        case text = "Book text", audio = "Audio file", tracks = "Audio ZIP + separate text", package = "Complete book ZIP"
        var id: Self { self }
        var detail: String {
            switch self {
            case .text: return "UTF-8 TXT. Read and save phrases now; add audio later."
            case .audio: return "Listen now; add book text later."
            case .tracks: return "MP3, M4A or WAV tracks in a ZIP. You can add a separate TXT now or later."
            case .package: return "Audio and text, with synchronization when the package includes it."
            }
        }
        var symbol: String { self == .text ? "doc.text" : self == .audio ? "headphones" : "archivebox" }
    }
    private enum FileChoice { case audio, text, archive }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ReadingVocabularyStore.self) private var vocabulary
    var item: LearningItem? = nil
    var action: BookResourceAction? = nil
    @State private var step = 0
    @State private var source: Source = .text
    @State private var audioURL: URL?
    @State private var textURL: URL?
    @State private var archiveURL: URL?
    @State private var choice: FileChoice = .text
    @State private var picking = false
    @State private var preview: BookImportService.Preview?
    @State private var selectedTranscript: String?
    @State private var title = ""
    @State private var language = UserDefaults.standard.string(forKey: SourceLanguage.importKey) ?? "pl"
    @State private var expectedRevision = ""
    @State private var working = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var result: LearningItem?
    @State private var confirming = false
    @State private var legacyImport = false
    @State private var service = BookImportService()
    @State private var validator = BookSynchronizationValidator()
    @State private var wordPreview: VocabularyImportPreview?
    @State private var wordError: String?
    @State private var wordPreviewKey = ""
    private var previewKey: String { "\(preview?.id.uuidString ?? ""):\(selectedTranscript ?? ""):\(textURL?.absoluteString ?? ""):\(language)" }
    private var hasPreviewText: Bool { selectedTranscript != nil || (usesArchive && textURL != nil) || preview?.tracks.contains(where: { $0.subtitleFilename != nil }) == true }

    private var usesArchive: Bool { source == .tracks || source == .package || action == .synchronization }
    private var canCheck: Bool { usesArchive ? archiveURL != nil : audioURL != nil || textURL != nil }
    private var replacing: Bool {
        guard let item, let action else { return false }
        switch action {
        case .text: return item.hasText
        case .audio: return item.hasAudio
        case .synchronization: return item.tracks.contains { $0.subtitleFilename != nil }
        }
    }
    private var fileTypes: [UTType] {
        switch choice {
        case .audio: return [.audio]
        case .text: return [.plainText]
        case .archive: return [.zip]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section {
                        Label(item == nil ? "Book added" : "Book updated", systemImage: "checkmark.circle.fill")
                        Text(result.resourceStatus)
                        NavigationLink(result.hasText ? "Start reading" : "Start listening") {
                            if result.tracks.isEmpty { ReaderView(item: result).id(result.resourceRevision) }
                            else { BookReaderView(item: result).id(result.resourceRevision) }
                        }
                        .accessibilityIdentifier("import.open-book")
                    }
                } else if step == 0 {
                    Section {
                        ForEach(Source.allCases) { value in
                            Button {
                                audioURL = nil; textURL = nil; archiveURL = nil; title = ""
                                source = value; step = 1
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(value.rawValue).foregroundStyle(.primary)
                                        Text(value.detail).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 6)
                                } icon: { Image(systemName: value.symbol).foregroundStyle(.tint) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("import.source.\(value.id)")
                        }
                    } header: { Text("What do you have?") } footer: {
                        Text("Start with text or audio. Add missing files to the same book later from its ⋮ menu.")
                    }
                    Section {
                        Button("Audio or video with SRT / VTT subtitles") { legacyImport = true }
                    }
                } else if step == 1 {
                    Section {
                        if action == .audio {
                            Picker("Audio source", selection: $source) {
                                Text("One audio file").tag(Source.audio)
                                Text("Audio ZIP").tag(Source.tracks)
                            }
                        }
                        if usesArchive {
                            fileButton(archiveURL?.lastPathComponent ?? "Choose ZIP", choice: .archive)
                        } else {
                            if source == .audio { fileButton(audioURL?.lastPathComponent ?? "Choose audio", choice: .audio) }
                            if action != .audio { fileButton(textURL?.lastPathComponent ?? (source == .audio ? "Add text (optional)" : "Choose TXT"), choice: .text) }
                        }
                        if usesArchive && action != .synchronization && action != .audio {
                            fileButton(textURL?.lastPathComponent ?? "Add separate TXT (optional)", choice: .text)
                        }
                    } header: { Text("Step 1 of 2 · Choose files") } footer: {
                        Text(action == .synchronization
                            ? "Choose a complete synchronized book package made from the same recordings and text. Audio is checked in the displayed track order."
                            : "Text: UTF-8 TXT under 10 MB. ZIP: up to 4 GiB and 100 MP3, M4A or WAV tracks. Synchronization is optional; SRT/VTT in raw ZIPs are not linked automatically.")
                    }
                    Button("Check files") { checkFiles() }
                        .disabled(!canCheck || working)
                        .accessibilityIdentifier("import.check")
                } else if let value = preview {
                    Section("Step 2 of 2 · Review book") {
                        TextField("Title", text: $title).disabled(item != nil)
                        Picker("Book language", selection: $language) {
                            ForEach(readingLanguages) { Text($0.name).tag($0.code) }
                        }.disabled(item != nil || value.isManifestPackage)
                        if value.transcriptCandidates.count > 1 && textURL == nil {
                            Picker("Book text", selection: Binding(get: { selectedTranscript ?? "" }, set: { selectedTranscript = $0.isEmpty ? nil : $0 })) {
                                Text("Choose TXT or continue without text").tag("")
                                ForEach(value.transcriptCandidates, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        LabeledContent("Text", value: textURL?.lastPathComponent ?? selectedTranscript ?? "Add later")
                        LabeledContent("Audio tracks", value: "\(value.tracks.count)")
                        Text(value.tracks.contains { $0.alignmentStatus.hasTimedTranscript }
                             ? "Synchronization included. Tracks marked for review may need timing corrections."
                             : "No synchronization. You can read and listen independently, and add synchronization later.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !value.isManifestPackage && !value.tracks.isEmpty {
                            Text("Check the track order. Drag rows to reorder.").font(.caption)
                        }
                    }
                    if !value.tracks.isEmpty {
                        Section("Track order") {
                            ForEach(value.tracks) { track in
                                VStack(alignment: .leading) {
                                    Text(track.title)
                                    Text(track.sourcePath).font(.caption).foregroundStyle(.secondary)
                                }
                            }.onMove { from, to in
                                guard !value.isManifestPackage else { return }
                                preview?.tracks.move(fromOffsets: from, toOffset: to)
                            }.moveDisabled(value.isManifestPackage)
                        }
                    }
                    if value.ignoredFileCount > 0 { Text("\(value.ignoredFileCount) unrelated files will be ignored.") }
                    if hasPreviewText && action != .audio {
                        Section("Reading vocabulary") {
                            ReadingVocabularyStatus()
                            VocabularyStatisticsView(words: wordPreviewKey == previewKey ? wordPreview?.words : nil, language: language, error: wordError)
                            if wordError != nil { Button("Retry word count") { Task { await countWords() } } }
                        }
                    }
                    if let action { Section("Effect on this book") { Text(consequences(action)) } }
                    Button(item == nil ? "Add book" : "Save changes") {
                        if replacing { confirming = true } else { commit() }
                    }
                    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (action == .text && selectedTranscript == nil && textURL == nil)
                              || (hasPreviewText && action != .audio && (wordPreview == nil || wordPreviewKey != previewKey || !vocabulary.ready)))
                    .accessibilityIdentifier("import.commit")
                }
                if working { ProgressView("Checking and preparing files…") }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("import.error")
                        if step == 2 { Button("Check files again") { step = 1; self.error = nil } }
                    }
                }
            }
            .environment(\.editMode, .constant(step == 2 ? .active : .inactive))
            .disabled(working)
            .navigationTitle(item == nil ? "Add book" : "Update book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { close() }
                }
                if step > (action == nil ? 0 : 1) && result == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { step -= 1; error = nil }.disabled(working)
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .fileImporter(isPresented: $picking, allowedContentTypes: fileTypes) { value in
                switch value {
                case .success(let url):
                    switch choice { case .audio: audioURL = url; case .text: textURL = url; case .archive: archiveURL = url }
                    error = nil
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .confirmationDialog("Replace existing files?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Replace and save", role: .destructive) { commit() }
                Button("Cancel", role: .cancel) { }
            } message: { Text(action.map(consequences) ?? "") }
            .sheet(isPresented: $legacyImport) { ImportItemView() }
            .task(id: previewKey) { await countWords() }
            .onAppear {
                if let item, let action, step == 0 {
                    expectedRevision = item.resourceRevision; title = item.title; language = item.sourceLanguageCode
                    source = action == .text ? .text : action == .audio ? .audio : .package
                    step = 1
                }
            }
            .onDisappear { work?.cancel(); if let preview { Task { await service.cancel(preview) } } }
        }
    }

    private var readingLanguages: [SourceLanguage] {
        var values = SourceLanguage.supported
        if !values.contains(where: { $0.code == language }) { values.append(.init(code: language, name: SourceLanguage.name(for: language))) }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fileButton(_ label: String, choice: FileChoice) -> some View {
        Button(label) { self.choice = choice; picking = true }
    }

    private func consequences(_ action: BookResourceAction) -> String {
        switch action {
        case .text: return "The new text replaces the current text and resets its reading position, completion and synchronization. Saved phrases, translations and studied words stay. Audio links on saved phrases will be cleared."
        case .audio: return "This replaces the entire audio track set. Book text and saved phrases stay. Playback starts from the beginning; synchronization, chapter completion and old phrase audio links are cleared."
        case .synchronization: return "Audio and text must match this book. Track identities and manual audio boundaries stay; old phrase cue links are cleared because subtitle segmentation may change."
        }
    }

    private func checkFiles() {
        working = true; error = nil
        work = Task {
            defer { working = false }
            do {
                if let preview { await service.cancel(preview); self.preview = nil }
                let value: BookImportService.Preview
                if usesArchive, let archiveURL { value = try await service.previewArchive(archiveURL) }
                else { value = try await service.previewFiles(audio: audioURL, text: textURL) }
                guard !Task.isCancelled else { await service.cancel(value); return }
                preview = value; selectedTranscript = value.selectedTranscript
                if item == nil { if title.isEmpty { title = value.title }; if value.isManifestPackage { language = SourceLanguage.canonical(value.sourceLanguage) } }
                if action == .synchronization && !value.isManifestPackage { throw BookManifestError.invalid("Synchronization requires a complete package with a manifest, text and audio.") }
                step = 2
            } catch { self.error = error.localizedDescription }
        }
    }

    private func commit() {
        guard let preview else { return }
        working = true; error = nil
        work = Task {
            defer { working = false }
            do {
                _ = try VocabularyTokenizer.language(language)
                let reviewed = try await service.vocabularyPreview(preview, transcriptPath: selectedTranscript, externalTranscript: usesArchive ? textURL : nil)
                if hasPreviewText && action != .audio, reviewed.fingerprint != wordPreview?.fingerprint {
                    wordPreview = reviewed; wordPreviewKey = previewKey
                    throw ReadingVocabularyError.changed
                }
                if item == nil { UserDefaults.standard.set(language, forKey: SourceLanguage.importKey) }
                let prepared = try await service.prepare(preview, title: title, sourceLanguage: language,
                    orderedTracks: preview.tracks, transcriptPath: selectedTranscript,
                    externalTranscript: usesArchive ? textURL : nil)
                let stagedWords = try await service.vocabularyPreview(prepared)
                guard stagedWords.fingerprint == reviewed.fingerprint else { throw ReadingVocabularyError.changed }
                try Task.checkCancellation()
                if let item, let action {
                    if action == .synchronization {
                        try await validator.validate(prepared, existing: BookResourceUpdateService.synchronizationTracks(item),
                            directory: MediaImportService.directory(for: item.id), transcriptFilename: item.transcriptFilename)
                    }
                    try Task.checkCancellation()
                    try BookResourceUpdateService.apply(prepared, to: item, action: action,
                        expectedRevision: expectedRevision, context: context)
                    await service.cancel(preview)
                    result = item
                } else {
                    let segments = prepared.tracks.isEmpty ? try TranscriptParser.parse(
                        String(contentsOf: prepared.stagedBookDirectory.appending(path: prepared.transcriptFilename), encoding: .utf8), extension: "txt").segments : []
                    try await service.movePreparedToLibrary(prepared)
                    do { try Task.checkCancellation() }
                    catch { await service.rollback(prepared); throw error }
                    let added = LearningItem(id: prepared.itemID, title: prepared.title,
                        mediaKind: prepared.tracks.isEmpty ? "text" : "audio", mediaFilename: "",
                        transcriptFilename: prepared.transcriptFilename, duration: prepared.duration,
                        segments: segments, sourceLanguageCode: prepared.sourceLanguage,
                        tracks: prepared.tracks, lastTrackID: prepared.tracks.first?.id)
                    added.readingVocabularyMigrationVersion = 1
                    context.insert(added)
                    do { try context.save() }
                    catch { context.delete(added); await service.rollback(prepared); throw error }
                    await service.complete(prepared)
                    result = added
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func countWords() async {
        guard let preview else { wordPreview = nil; return }
        let key = previewKey
        wordError = nil
        do {
            let value = try await service.vocabularyPreview(preview, transcriptPath: selectedTranscript, externalTranscript: usesArchive ? textURL : nil)
            try Task.checkCancellation()
            guard key == previewKey else { return }
            wordPreview = value; wordPreviewKey = key
        } catch is CancellationError { }
        catch { if key == previewKey { wordPreview = nil; wordError = error.localizedDescription } }
    }

    private func close() {
        work?.cancel()
        if let preview { Task { await service.cancel(preview) } }
        dismiss()
    }
}
