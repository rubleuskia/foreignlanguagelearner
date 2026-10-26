import AVFoundation
import Foundation
import SwiftData

/// Original demonstration text. Narration is synthesized locally on the user's
/// device, rather than distributing a recording of a system voice.
@MainActor enum DemoBookService {
    static let id: UUID = {
        #if DEBUG
        // UI tests reset their in-memory database on launch but keep sandbox files.
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return UUID() }
        #endif
        return UUID(uuidString: "BE0D2CB3-D884-45F2-AC42-73138FA8B9D9")!
    }()
    static let text = "A new day begins. Anna opens a book and reads a short story. She finds a new word and saves it. Every small step helps her learn."

    static func add(context: ModelContext, itemID: UUID? = nil, narration: ((URL) async throws -> Void)? = nil) async throws -> LearningItem {
        let demoID = itemID ?? id
        if let existing = try context.fetch(FetchDescriptor<LearningItem>()).first(where: { $0.id == demoID }) { return existing }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let textURL = temporary.appending(path: "A new day.txt")
        try Data(text.utf8).write(to: textURL)
        let audioURL = temporary.appending(path: "example.caf")
        var hasNarration = true
        do {
            if let narration { try await narration(audioURL) }
            else { try await narrate(to: audioURL) }
        } catch { hasNarration = false }
        let service = BookImportService()
        let preview = try await service.previewFiles(audio: hasNarration ? audioURL : nil, text: textURL)
        do {
            let prepared = try await service.prepare(preview, title: hasNarration ? "A new day · Example" : "A new day · Text example", sourceLanguage: "en",
                orderedTracks: preview.tracks, transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            // One real cue spans the one narration. No word timestamps are invented.
            let duration = prepared.duration
            if hasNarration {
                let subtitle = "WEBVTT\n\n00:00:00.000 --> \(timestamp(duration))\n\(text)\n"
                try Data(subtitle.utf8).write(to: prepared.stagedBookDirectory.appending(path: "example.vtt"))
            }
            let final = BookImportService.Prepared(transactionID: prepared.transactionID, itemID: demoID,
                title: prepared.title, sourceLanguage: "en", tracks: prepared.tracks.map {
                    var track = $0; track.subtitleFilename = "example.vtt"; track.alignmentStatus = .aligned; return track
                }, transcriptFilename: prepared.transcriptFilename, duration: duration, stagedBookDirectory: prepared.stagedBookDirectory)
            try await service.movePreparedToLibrary(final)
            let item = LearningItem(id: demoID, title: final.title, mediaKind: hasNarration ? "audio" : "text", mediaFilename: "",
                transcriptFilename: final.transcriptFilename, duration: final.duration,
                segments: hasNarration ? [] : [.init(start: nil, end: nil, text: text)],
                sourceLanguageCode: "en", tracks: final.tracks, lastTrackID: final.tracks.first?.id)
            item.readingVocabularyMigrationVersion = 1
            context.insert(item)
            do { try context.save() }
            catch { context.delete(item); await service.rollback(final); throw error }
            await service.complete(final)
            return item
        } catch { await service.cancel(preview); throw error }
    }

    private static func narrate(to audioURL: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let writer = DemoNarrationWriter(url: audioURL, continuation: continuation)
            Task {
                try? await Task.sleep(for: .seconds(15))
                writer.fail(BookManifestError.invalid("Example narration is unavailable on this device."))
            }
            synthesizer.write(utterance) { buffer in writer.consume(buffer) }
        }
        } catch { synthesizer.stopSpeaking(at: .immediate); throw error }
        // Retain the synthesizer across the asynchronous buffer stream.
        _ = synthesizer.isSpeaking
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int(seconds * 1000)
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

/// AVSpeechSynthesizer may deliver buffers off the main actor. All mutable
/// writer state is protected by the lock, including the single completion.
private final class DemoNarrationWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: AVAudioFile?

    init(url: URL, continuation: CheckedContinuation<Void, Error>) {
        self.url = url; self.continuation = continuation
    }

    func consume(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else { throw CocoaError(.fileReadCorruptFile) }
            if pcm.frameLength == 0 {
                guard file != nil else { throw BookManifestError.invalid("The example voice is unavailable on this device. Add your own text or audio instead.") }
                file = nil; self.continuation = nil; continuation.resume()
            } else {
                if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                try file?.write(from: pcm)
            }
        } catch { file = nil; self.continuation = nil; continuation.resume(throwing: error) }
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        file = nil; self.continuation = nil; continuation.resume(throwing: error)
    }
}
