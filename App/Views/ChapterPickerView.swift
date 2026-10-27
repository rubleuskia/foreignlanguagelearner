import SwiftUI

/// Capture rows when opening. Playback ticks and saved positions must not rebuild an open picker.
struct ChapterPickerSnapshot: Identifiable {
    struct Chapter: Identifiable {
        let id: String
        let title: String
        let completed: Bool
        let duration: TimeInterval
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
                            Text(AppLanguage.text(chapter.id == snapshot.selectedID ? "Current chapter" : chapter.completed ? "Read" : "Not read yet"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.formattedDuration(chapter.duration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(AppLanguage.format("Audio duration %@", Self.formattedDuration(chapter.duration)))
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

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "–" }
        let seconds = Int(duration.rounded())
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}
