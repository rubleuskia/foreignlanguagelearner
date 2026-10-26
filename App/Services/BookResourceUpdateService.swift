import Foundation
import SwiftData

enum BookResourceAction: String, Identifiable, Sendable {
    case text, audio, synchronization
    var id: Self { self }
}

/// A new generation is published before model references change. Recovery removes
/// unpublished generations; existing referenced files are never overwritten.
struct BookResourceJournal: Codable {
    let id: UUID
    let itemID: UUID
    var obsoleteFiles: [String] = []
    var stagingID: UUID? = nil
    var prefix: String { "resource-updates/\(id.uuidString)" }
    var directory: URL { MediaImportService.directory(for: itemID).appending(path: prefix) }
    static var root: URL { URL.applicationSupportDirectory.appending(path: "ResourceJournals") }
    var url: URL { Self.root.appending(path: "\(id.uuidString).json") }
}

actor BookSynchronizationValidator {
    // Matching is explicit by previewed order and exact audio bytes, never filenames.
    func validate(_ prepared: BookImportService.Prepared, existing: [LearningTrack],
                  directory: URL, transcriptFilename: String) throws {
        guard prepared.tracks.count == existing.count,
              prepared.tracks.contains(where: { $0.alignmentStatus.hasTimedTranscript }) else {
            throw BookManifestError.invalid("Choose a synchronized book package with the same audio tracks in the same order.")
        }
        if !transcriptFilename.isEmpty {
            let url = directory.appending(path: transcriptFilename)
            let old = try TranscriptParser.parse(String(contentsOf: url, encoding: .utf8), extension: url.pathExtension).text
            let new = try String(contentsOf: prepared.stagedBookDirectory.appending(path: prepared.transcriptFilename), encoding: .utf8)
            guard try BookTextNormalization.normalize(old) == BookTextNormalization.normalize(new) else {
                throw BookManifestError.invalid("The package text differs from this book. Replace the text separately before adding synchronization.")
            }
        }
        for (incoming, old) in zip(prepared.tracks, existing) {
            guard try WordAudioTimingFile.audioHash(prepared.stagedBookDirectory.appending(path: incoming.mediaFilename))
                == WordAudioTimingFile.audioHash(directory.appending(path: old.mediaFilename)) else {
                throw BookManifestError.invalid("Audio differs for \(old.title). Choose a package made from the current recordings in the displayed order.")
            }
            if let name = incoming.wordTimingsFilename {
                let url = prepared.stagedBookDirectory.appending(path: name)
                let file = try WordAudioTimingFile.read(url)
                let remapped = WordAudioTimingFile(schemaVersion: file.schemaVersion, trackID: old.id,
                    audioSHA256: file.audioSHA256, textSHA256: file.textSHA256, words: file.words)
                try JSONEncoder().encode(remapped).write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }
}

@MainActor enum BookResourceUpdateService {
    static func synchronizationTracks(_ item: LearningItem) -> [LearningTrack] {
        if !item.tracks.isEmpty { return item.tracks }
        guard item.hasAudio else { return [] }
        return [.init(id: "legacy", title: item.title, mediaFilename: item.mediaFilename,
            duration: item.duration, lastPosition: item.lastPosition, isCompleted: item.isBookCompleted)]
    }
    static func apply(_ prepared: BookImportService.Prepared, to item: LearningItem,
                      action: BookResourceAction, expectedRevision: String,
                      context: ModelContext, save: (() throws -> Void)? = nil) throws {
        guard item.modelContext != nil, item.resourceRevision == expectedRevision else { throw ReadingVocabularyError.changed }
        if action == .text, prepared.transcriptFilename.isEmpty { throw BookManifestError.invalid("Choose a TXT file.") }
        if action != .text, prepared.tracks.isEmpty { throw BookManifestError.invalid("Choose audio or an audiobook ZIP.") }
        // Flush unrelated playback/dictionary changes before this isolated mutation.
        if context.hasChanges { try context.save() }
        let snapshot = BookResourceSnapshot(item)
        let entries = try context.fetch(FetchDescriptor<DictionaryEntry>()).filter { ($0.localSourceItemID ?? $0.sourceItemID) == item.id }
        let entrySnapshots = entries.map { ($0, DictionaryEntryRollbackSnapshot($0)) }
        let oldFiles = [item.mediaFilename, item.transcriptFilename] + item.tracks.flatMap { [$0.mediaFilename, $0.subtitleFilename ?? "", $0.wordTimingsFilename ?? ""] }
        var journal = BookResourceJournal(id: UUID(), itemID: item.id)
        journal.stagingID = prepared.transactionID
        journal.obsoleteFiles = oldFiles.filter { !$0.isEmpty }
            + prepared.tracks.flatMap { ["\(journal.prefix)/\($0.mediaFilename)", $0.subtitleFilename.map { "\(journal.prefix)/\($0)" } ?? "", $0.wordTimingsFilename.map { "\(journal.prefix)/\($0)" } ?? ""] }.filter { !$0.isEmpty }
        let fm = FileManager.default
        try fm.createDirectory(at: BookResourceJournal.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journal.url, options: [.atomic, .completeFileProtection])
        do {
            try fm.createDirectory(at: journal.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: prepared.stagedBookDirectory, to: journal.directory)
            func path(_ name: String) -> String { name.isEmpty ? "" : "\(journal.prefix)/\(name)" }
            let wasLegacy = item.tracks.isEmpty
            let oldTracks = action == .synchronization ? synchronizationTracks(item) : item.tracks
            item.sourceLanguageLockedByHistory = item.isSourceLanguageLocked
            if action == .text {
                item.transcriptFilename = path(prepared.transcriptFilename)
                item.segments = oldTracks.isEmpty ? try TranscriptParser.parse(
                    String(contentsOf: journal.directory.appending(path: prepared.transcriptFilename), encoding: .utf8), extension: "txt").segments : []
                item.readingCharacterOffset = 0
                item.isBookCompleted = false
                item.parts = []
                item.tracks = oldTracks.map { track in
                    var result = track
                    result.subtitleFilename = nil; result.wordTimingsFilename = nil
                    result.alignmentStatus = .untimed; result.isCompleted = false
                    return result
                }
            } else if action == .audio {
                // Give replacements fresh identities, including strict-package tracks
                // whose IDs happen to match a previous but different recording.
                item.tracks = prepared.tracks.map { track in
                    LearningTrack(id: UUID().uuidString, title: track.title,
                        mediaFilename: path(track.mediaFilename), duration: track.duration)
                }
                item.mediaFilename = ""; item.mediaKind = "audio"
                item.lastPosition = 0; item.lastTrackID = item.tracks.first?.id
                item.duration = prepared.duration; item.parts = []; item.isBookCompleted = false
                // Legacy segments are the full reading text when adding/replacing audio.
                item.segments = item.segments.map { .init(start: nil, end: nil, text: $0.text) }
                if oldTracks.isEmpty && !item.segments.isEmpty {
                    // A legacy SRT/VTT becomes a genuine untimed full-text file.
                    let filename = "preserved-text.txt"
                    try Data(TranscriptDocument(segments: item.segments).text.utf8).write(to: journal.directory.appending(path: filename), options: [.atomic, .completeFileProtection])
                    item.transcriptFilename = path(filename)
                    item.segments = []
                }
                if !item.transcriptFilename.isEmpty, !oldTracks.isEmpty { item.segments = [] }
            } else {
                guard oldTracks.count == prepared.tracks.count else { throw ReadingVocabularyError.changed }
                item.tracks = zip(prepared.tracks, oldTracks).map { incoming, old in
                    var track = old
                    track.subtitleFilename = incoming.subtitleFilename.map(path)
                    track.wordTimingsFilename = incoming.wordTimingsFilename.map(path)
                    track.alignmentStatus = incoming.alignmentStatus
                    return track
                }
                if wasLegacy {
                    item.mediaFilename = ""; item.mediaKind = "audio"
                    item.segments = []; item.parts = []; item.lastTrackID = oldTracks.first?.id
                    item.transcriptFilename = path(prepared.transcriptFilename)
                    for entry in entries where entry.sourceTrackID == nil { entry.sourceTrackID = oldTracks.first?.id }
                } else if item.transcriptFilename.isEmpty {
                    item.transcriptFilename = path(prepared.transcriptFilename)
                    item.isBookCompleted = false
                }
            }
            if action != .synchronization {
                for entry in entries {
                    entry.audioStart = nil; entry.audioEnd = nil
                    entry.phraseAudioStart = nil; entry.phraseAudioEnd = nil
                    entry.manualAudioStart = nil; entry.manualAudioEnd = nil
                    entry.manualPhraseAudioStart = nil; entry.manualPhraseAudioEnd = nil
                    entry.segmentIndex = nil
                }
            } else {
                // Old cue indices cannot be applied to a changed segmentation. Keep
                // exact manual/recorded audio ranges on the same verified recordings.
                for entry in entries { entry.segmentIndex = nil }
            }
            item.resourceRevision = journal.id.uuidString
            try (save ?? { try context.save() })()
            cleanup(journal, item: item)
            try? fm.removeItem(at: journal.url)
        } catch {
            context.rollback()
            snapshot.restore(item)
            for (entry, saved) in entrySnapshots { saved.restore(entry) }
            if fm.fileExists(atPath: journal.directory.path), !fm.fileExists(atPath: prepared.stagedBookDirectory.path) {
                try? fm.moveItem(at: journal.directory, to: prepared.stagedBookDirectory)
            }
            try? fm.removeItem(at: journal.url)
            throw error
        }
    }

    static func recover(context: ModelContext) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: BookResourceJournal.root.path) else { return }
        let items = try context.fetch(FetchDescriptor<LearningItem>())
        for url in try fm.contentsOfDirectory(at: BookResourceJournal.root, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let value = try? JSONDecoder().decode(BookResourceJournal.self, from: Data(contentsOf: url)), value.id == id else { continue }
            let item = items.first { $0.id == value.itemID }
            let references = item.map { [$0.transcriptFilename, $0.mediaFilename] + $0.tracks.flatMap { [$0.mediaFilename, $0.subtitleFilename ?? "", $0.wordTimingsFilename ?? ""] } } ?? []
            if references.contains(where: { $0.hasPrefix(value.prefix + "/") }) {
                guard fm.fileExists(atPath: value.directory.path) else { throw CocoaError(.fileNoSuchFile) }
                if let item { cleanup(value, item: item) }
            } else { try? fm.removeItem(at: value.directory) }
            if let id = value.stagingID { try? fm.removeItem(at: BookImportService.stagingRoot.appending(path: id.uuidString)) }
            try? fm.removeItem(at: url)
        }
    }

    private static func cleanup(_ journal: BookResourceJournal, item: LearningItem) {
        let references = Set([item.mediaFilename, item.transcriptFilename] + item.tracks.flatMap { [$0.mediaFilename, $0.subtitleFilename ?? "", $0.wordTimingsFilename ?? ""] })
        for name in journal.obsoleteFiles where !references.contains(name) {
            guard (try? BookManifestValidator.validatePath(name)) != nil else { continue }
            try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id).appending(path: name))
        }
    }
}

/// SwiftData rollback alone does not reliably refresh observed Codable arrays.
@MainActor private struct BookResourceSnapshot {
    let mediaKind: String
    let mediaFilename: String
    let transcriptFilename: String
    let duration: Double
    let lastPosition: Double
    let lastTrackID: String?
    let segments: [TranscriptSegment]
    let parts: [LearningPart]
    let tracks: [LearningTrack]
    let completed: Bool
    let offset: Int
    let revision: String
    let languageLocked: Bool
    init(_ item: LearningItem) {
        mediaKind = item.mediaKind; mediaFilename = item.mediaFilename
        transcriptFilename = item.transcriptFilename; duration = item.duration
        lastPosition = item.lastPosition; lastTrackID = item.lastTrackID
        segments = item.segments; parts = item.parts; tracks = item.tracks
        completed = item.isBookCompleted; offset = item.readingCharacterOffset; revision = item.resourceRevision
        languageLocked = item.sourceLanguageLockedByHistory
    }
    func restore(_ item: LearningItem) {
        item.mediaKind = mediaKind; item.mediaFilename = mediaFilename
        item.transcriptFilename = transcriptFilename; item.duration = duration
        item.lastPosition = lastPosition; item.lastTrackID = lastTrackID
        item.segments = segments; item.parts = parts; item.tracks = tracks
        item.isBookCompleted = completed; item.readingCharacterOffset = offset; item.resourceRevision = revision
        item.sourceLanguageLockedByHistory = languageLocked
    }
}
