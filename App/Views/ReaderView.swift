import SwiftUI
import SwiftData
import AVKit

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let item: LearningItem
    @State private var playback = PlaybackController()
    @State private var following = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var message: String?
    private let document: TranscriptDocument

    init(item: LearningItem) {
        self.item = item
        self.document = TranscriptDocument(segments: item.segments)
    }

    var body: some View {
        VStack(spacing: 0) {
            if item.mediaKind == "video" {
                VideoPlayer(player: playback.player).frame(height: 200)
            }
            if item.segments.first?.start == nil {
                Text("This transcript has no timestamps. You can read and save phrases; synchronized scrolling requires SRT or WebVTT.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            TranscriptTextView(document: document, activeSegment: document.activeSegment(at: playback.position), following: $following) { text, segment in
                let entry = DictionaryEntry(text: text, item: item, segmentIndex: segment)
                guard !entry.text.isEmpty else { return }
                context.insert(entry)
                do { try context.save(); message = "Added to Dictionary" }
                catch { context.delete(entry); message = error.localizedDescription }
            }
            if !following {
                Button("Follow audio", systemImage: "arrow.down.to.line") { following = true }
                    .padding(8)
            }
        }
        .safeAreaInset(edge: .bottom) { playerBar }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            playback.open(url: MediaImportService.directory(for: item.id).appending(path: item.mediaFilename), position: item.lastPosition)
        }
        .onChange(of: playback.position) { _, position in
            if abs(item.lastPosition - position) >= 5 { item.lastPosition = position }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { item.lastPosition = playback.position; try? context.save() }
        }
        .onDisappear { item.lastPosition = playback.position; playback.close(); try? context.save() }
        .alert("Dictionary", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .alert("Playback error", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
            Button("OK") { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
    }

    private var playerBar: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(playback.position, item.duration) }, set: { scrubPosition = $0 }), in: 0...max(item.duration, 0.01)) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubPosition); following = true }
            }.accessibilityLabel("Playback position")
            HStack {
                Text(time(playback.position)).monospacedDigit()
                Spacer()
                Button { playback.seek(to: max(0, playback.position - 10)); following = true } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Back 10 seconds")
                Button { playback.toggle(); if playback.isPlaying { following = true } } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.seek(to: min(item.duration, playback.position + 10)); following = true } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel("Forward 10 seconds")
                Spacer()
                Text(time(item.duration)).monospacedDigit()
            }
        }.padding().background(.bar)
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
