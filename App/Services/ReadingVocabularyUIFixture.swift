#if DEBUG
import AVFoundation
import Foundation
import SwiftData

@MainActor enum ReadingVocabularyUIFixture {
    static func seed(context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("--reading-vocabulary-fixture"),
              try context.fetchCount(FetchDescriptor<LearningItem>()) == 0 else { return }
        let id = UUID()
        let directory = MediaImportService.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!
        buffer.frameLength = buffer.frameCapacity
        let audio = try AVAudioFile(forWriting: directory.appending(path: "media.wav"), settings: format.settings)
        try audio.write(from: buffer)
        try "Kot i pies śpi.".write(to: directory.appending(path: "text.txt"), atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:10,000\nKot i kot.\n".write(to: directory.appending(path: "one.srt"), atomically: true, encoding: .utf8)
        let item = LearningItem(id: id, title: "Reading vocabulary story", mediaKind: "audio", mediaFilename: "",
            transcriptFilename: "text.txt", duration: 40, segments: [], tracks: [
                .init(id: "one", title: "Chapter one", mediaFilename: "media.wav", subtitleFilename: "one.srt", duration: 20, alignmentStatus: .aligned),
                .init(id: "two", title: "Chapter two", mediaFilename: "media.wav", duration: 20)
            ], lastTrackID: "one")
        if ProcessInfo.processInfo.arguments.contains("--chapter-scroll-fixture") {
            item.tracks = (1...100).map { number in
                .init(id: "chapter-\(number)", title: "Chapter \(number)", mediaFilename: "media.wav",
                      subtitleFilename: "one.srt", duration: 20, alignmentStatus: .aligned)
            }
            item.lastTrackID = item.tracks.first?.id
        }
        item.readingVocabularyMigrationVersion = 1
        context.insert(item); try context.save()
    }
}
#endif
