#if DEBUG
import AVFoundation
import Foundation
import SwiftData

@MainActor enum ProgressiveBookUIFixture {
    static func seed(context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("--progressive-books-fixture"),
              try context.fetchCount(FetchDescriptor<LearningItem>()) == 0 else { return }
        if ProcessInfo.processInfo.arguments.contains("--onboarding-fixture") {
            OnboardingPreferences.reset()
            UserDefaults.standard.set(true, forKey: OnboardingPreferences.enabledKey)
        }
        for kind in ["Text", "Audio", "Combined"] {
            let id = UUID(), directory = MediaImportService.directory(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = "A new day begins. " + String(repeating: "Anna reads a short story and saves a new word.\n\n", count: 80)
            if kind != "Audio" { try Data(text.utf8).write(to: directory.appending(path: "text.txt")) }
            var tracks: [LearningTrack] = []
            if kind != "Text" {
                let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                buffer.frameLength = buffer.frameCapacity
                do { let audio = try AVAudioFile(forWriting: directory.appending(path: "audio.wav"), settings: format.settings); try audio.write(from: buffer) }
                tracks = [.init(id: "fixture", title: "Chapter", mediaFilename: "audio.wav", duration: 2)]
            }
            let item = LearningItem(id: id, title: "\(kind) example", mediaKind: kind == "Text" ? "text" : "audio", mediaFilename: "",
                transcriptFilename: kind == "Audio" ? "" : "text.txt", duration: kind == "Text" ? 0 : 2,
                segments: kind == "Text" ? [.init(start: nil, end: nil, text: text)] : [], sourceLanguageCode: "en", tracks: tracks)
            item.readingVocabularyMigrationVersion = 1
            context.insert(item)
        }
        try context.save()
    }
}
#endif
