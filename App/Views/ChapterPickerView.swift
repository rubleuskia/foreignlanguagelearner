import SwiftUI

/// Capture rows when opening. Playback ticks and saved positions must not rebuild an open picker.
struct ChapterPickerSnapshot: Identifiable {
    struct Chapter: Identifiable {
        let id: String
        let title: String
        let completed: Bool
    }
    let id = UUID()
    let chapters: [Chapter]
    let selectedID: String?
}

struct ChapterPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: ChapterPickerSnapshot
    let select: (String) -> Void

    var body: some View {
        NavigationStack {
            List(snapshot.chapters) { chapter in
                Button {
                    select(chapter.id)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title).font(.headline).foregroundStyle(.primary)
                            Text(chapter.id == snapshot.selectedID ? "Current chapter" : chapter.completed ? "Read" : "Not read yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if chapter.completed { Image(systemName: "checkmark.circle").accessibilityLabel("Read") }
                        if chapter.id == snapshot.selectedID { Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Current chapter") }
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("reader.chapter.\(chapter.id)")
            }
            .accessibilityIdentifier("reader.chapters-list")
            .nativeForm()
            .navigationTitle("Chapters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
