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
        if ProcessInfo.processInfo.arguments.contains("--chapter-end-fixture") {
            item.tracks[0].lastPosition = 19
        }
        if ProcessInfo.processInfo.arguments.contains("--chapter-scroll-fixture") {
            item.tracks = (1...100).map { number in
                .init(id: "chapter-\(number)", title: "Chapter \(number)", mediaFilename: "media.wav",
                      subtitleFilename: "one.srt", duration: 20, alignmentStatus: .aligned)
            }
            item.lastTrackID = item.tracks.first?.id
        }
        if ProcessInfo.processInfo.arguments.contains("--paused-scroll-fixture") {
            let sentence = String(repeating: "Kot i pies czytają książkę przy oknie. ", count: 8)
            let subtitles = (0..<200).map { index in
                let start = String(format: "00:00:%02d,%03d", index / 10, (index % 10) * 100)
                let next = index + 1
                let end = String(format: "00:00:%02d,%03d", next / 10, (next % 10) * 100)
                return "\(index + 1)\n\(start) --> \(end)\n\(sentence)\n"
            }.joined(separator: "\n")
            try subtitles.write(to: directory.appending(path: "one.srt"), atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.arguments.contains("--phrase-pages-fixture") {
            let phrase = String(repeating: "Kot i pies czytają książkę przy oknie. ", count: 8)
            let subtitles = (0..<10).map { index in
                let start = String(format: "00:00:%02d,000", index * 2)
                let end = String(format: "00:00:%02d,000", (index + 1) * 2)
                return "\(index + 1)\n\(start) --> \(end)\n\(phrase)\n"
            }.joined(separator: "\n")
            try subtitles.write(to: directory.appending(path: "one.srt"), atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.arguments.contains("--legacy-reader-fixture") {
            item.tracks = []
            item.lastTrackID = nil
            item.mediaFilename = "media.wav"
            item.duration = 20
            item.segments = [.init(start: 0, end: 20, text: "Kot i kot.")]
            item.parts = [.init(start: 0, end: 20)]
        }
        item.readingVocabularyMigrationVersion = 1
        context.insert(item)
        if ProcessInfo.processInfo.arguments.contains("--audio-boundary-fixture") {
            let entry = DictionaryEntry(text: "Kot", item: item, segmentIndex: 0,
                                        audioStart: 2, audioEnd: 3, sourceTrackID: "one")
            if ProcessInfo.processInfo.arguments.contains("--dual-audio-fixture") {
                entry.phraseAudioStart = 1
                entry.phraseAudioEnd = 5
            }
            if ProcessInfo.processInfo.arguments.contains("--editing-context-fixture") {
                entry.contextText = "Kot i kot."
                entry.contextSelectionLocation = 0
                entry.contextSelectionLength = 3
                entry.contextTranslationText = "Kot — kot — кот"
            }
            entry.translationText = "Кот"
            entry.translationStatus = .ready
            context.insert(entry)
        }
        try context.save()
    }
}
#endif
