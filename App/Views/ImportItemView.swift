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

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    Button(media?.lastPathComponent ?? "Choose audio or video") { pickingMedia = true }
                }
                Section {
                    Button(transcript?.lastPathComponent ?? "Choose transcript") { pickingTranscript = true }
                } header: { Text("Transcript") } footer: {
                    Text("SRT and WebVTT support synchronized scrolling. Plain UTF-8 text supports reading and phrase selection.")
                }
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
            .fileImporter(isPresented: $pickingMedia, allowedContentTypes: [.audio, .movie]) { result in
                switch result { case .success(let url): media = url; case .failure(let error): errorMessage = error.localizedDescription }
            }
            .fileImporter(isPresented: $pickingTranscript, allowedContentTypes: [.plainText, UTType(filenameExtension: "srt") ?? .data, UTType(filenameExtension: "vtt") ?? .data]) { result in
                switch result { case .success(let url): transcript = url; case .failure(let error): errorMessage = error.localizedDescription }
            }
        }
    }

    @MainActor private func importItem() async {
        guard let media, let transcript else { return }
        importing = true
        errorMessage = nil
        defer { importing = false }
        do {
            let imported = try await MediaImportService().importFiles(media: media, transcript: transcript)
            let item = LearningItem(id: imported.id, title: imported.title, mediaKind: imported.mediaKind,
                                    mediaFilename: imported.mediaFilename, transcriptFilename: imported.transcriptFilename,
                                    duration: imported.duration, segments: imported.document.segments)
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
