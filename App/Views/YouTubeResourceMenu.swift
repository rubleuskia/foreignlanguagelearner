import SwiftUI

struct YouTubeResourceMenu: View {
    let item: LearningItem
    var beforeUpdate: () -> Void = {}
    @State private var updatingSubtitles = false

    var body: some View {
        Menu {
            if let url = item.youtubeURL {
                Link("Open on YouTube", destination: url)
            }
            Button("Update subtitles", systemImage: "arrow.clockwise") {
                beforeUpdate()
                updatingSubtitles = true
            }.accessibilityIdentifier("youtube.update-subtitles")
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("YouTube actions")
        .accessibilityIdentifier("youtube.actions")
        .sheet(isPresented: $updatingSubtitles) { YouTubeImportView(replacing: item) }
    }
}
