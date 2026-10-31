import SwiftUI

struct BookResourceMenu: View {
    let item: LearningItem
    var beforeUpdate: () -> Void = {}
    var onUpdatePhraseAudio: (() -> Void)? = nil
    var isUpdatingPhraseAudio = false
    @AppStorage("reader.highlight-new-words") private var highlightsNewWords = true
    @State private var action: BookResourceAction?
    @State private var showingFiles = false

    var body: some View {
        Menu {
            if item.hasText {
                Toggle("New words", isOn: $highlightsNewWords)
                    .accessibilityIdentifier("reader.new-words")
                Divider()
            }
            Button(AppLanguage.text(item.hasText ? "Replace text" : "Add text"), systemImage: "doc.text") { open(.text) }
            Button(AppLanguage.text(item.hasAudio ? "Replace audio" : "Add audio"), systemImage: "headphones") { open(.audio) }
            if item.hasAudio && item.mediaKind != "video" {
                Button(AppLanguage.text(item.tracks.contains { $0.subtitleFilename != nil } ? "Update synchronization" : "Add synchronization"),
                       systemImage: "text.line.first.and.arrowtriangle.forward") { open(.synchronization) }
            }
            if let onUpdatePhraseAudio {
                Button("Update phrase audio", systemImage: "waveform.badge.plus", action: onUpdatePhraseAudio)
                    .disabled(isUpdatingPhraseAudio)
                    .accessibilityIdentifier("reader.update-phrase-audio")
            }
            Button("Book files", systemImage: "folder") { showingFiles = true }
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Book actions")
        .accessibilityIdentifier("book.resources")
        .sheet(item: $action) { BookImportView(item: item, action: $0) }
        .sheet(isPresented: $showingFiles) { BookFilesView(item: item) }
    }

    private func open(_ value: BookResourceAction) { beforeUpdate(); action = value }
}

private struct BookFilesView: View {
    let item: LearningItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section(item.title) {
                    Text(AppLanguage.text(item.resourceStatus))
                    Text(AppLanguage.format("Language: %@", SourceLanguage.name(for: item.sourceLanguageCode)))
                    LabeledContent("Book text", value: item.transcriptFilename.isEmpty ? "Not added" : URL(fileURLWithPath: item.transcriptFilename).lastPathComponent)
                }
                if !item.mediaFilename.isEmpty { Section("Media") { Text(URL(fileURLWithPath: item.mediaFilename).lastPathComponent) } }
                ForEach(item.tracks) { track in
                    Section(track.title) {
                        Text(AppLanguage.format("Audio: %@", URL(fileURLWithPath: track.mediaFilename).lastPathComponent))
                        Text(AppLanguage.text(track.subtitleFilename == nil ? "Without synchronization" : track.alignmentStatus == .reviewRequired ? "Synchronization needs review" : "Synchronized"))
                        Text(AppLanguage.text(track.wordTimingsFilename == nil ? "No word timings" : "Word timings included"))
                    }
                }
            }
            .navigationTitle("Book files")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
