import Foundation
import ZIPFoundation

/// Imports only validated timing sidecars into an existing book; media and reading progress stay in place.
actor WordTimingUpdateService {
    struct Prepared: Sendable {
        let directory: URL
        let filenames: [String: String]
    }

    func prepare(archiveURL: URL, tracks: [LearningTrack], directory: URL) throws -> Prepared {
        let accessed = archiveURL.startAccessingSecurityScopedResource()
        defer { if accessed { archiveURL.stopAccessingSecurityScopedResource() } }
        guard let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, UInt64(size) <= BookImportLimits.standard.maximumArchiveBytes else {
            throw BookManifestError.invalid("Choose a book ZIP under 4 GiB.")
        }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= BookImportLimits.standard.maximumEntries,
              let manifestEntry = archive["manifest.json"] else { throw BookManifestError.invalid("Choose a book ZIP containing word timings.") }
        let manifest = try BookManifestValidator.decode(read(manifestEntry, from: archive, maximumBytes: BookImportLimits.standard.maximumManifestBytes))
        guard manifest.tracks.map(\.id) == tracks.map(\.id) else {
            throw BookManifestError.invalid("This archive has different tracks from the open book.")
        }
        let identifier = UUID().uuidString
        let relativeDirectory = "word-timing-updates/\(identifier)"
        let updateDirectory = directory.appending(path: relativeDirectory)
        try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        do {
            var filenames: [String: String] = [:]
            var total = 0
            for (source, track) in zip(manifest.tracks, tracks) {
                try Task.checkCancellation()
                guard let path = source.wordTimings else { continue }
                guard let entry = archive[path], let subtitleFilename = track.subtitleFilename else {
                    throw BookManifestError.invalid("Missing word timings or local subtitles for track \(track.id).")
                }
                let data = try read(entry, from: archive, maximumBytes: WordAudioTimingFile.maximumBytes)
                total += data.count
                guard total <= WordAudioTimingFile.maximumCombinedBytes else { throw BookManifestError.invalid("Combined word timings exceed 50 MB.") }
                let file = try JSONDecoder().decode(WordAudioTimingFile.self, from: data)
                let subtitleURL = directory.appending(path: subtitleFilename)
                let document = try TranscriptParser.parse(String(contentsOf: subtitleURL, encoding: .utf8), extension: subtitleURL.pathExtension)
                _ = try file.applying(to: document, trackID: track.id, duration: track.duration)
                guard try file.audioSHA256 == WordAudioTimingFile.audioHash(directory.appending(path: track.mediaFilename)) else {
                    throw BookManifestError.invalid("This archive's word timings belong to different audio (track \(track.id)).")
                }
                let name = "\(track.id).json"
                try data.write(to: updateDirectory.appending(path: name), options: [.atomic, .completeFileProtection])
                filenames[track.id] = "\(relativeDirectory)/\(name)"
            }
            guard !filenames.isEmpty else { throw BookManifestError.invalid("This book archive has no word timings.") }
            return Prepared(directory: updateDirectory, filenames: filenames)
        } catch {
            try? FileManager.default.removeItem(at: updateDirectory)
            throw error
        }
    }

    private func read(_ entry: Entry, from archive: Archive, maximumBytes: Int) throws -> Data {
        guard entry.type == .file, entry.uncompressedSize <= maximumBytes else {
            throw BookManifestError.invalid("Missing or oversized timing data.")
        }
        var data = Data()
        let checksum = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximumBytes else { throw BookManifestError.invalid("Timing data exceeds its size limit.") }
            data.append(chunk)
        }
        guard checksum == entry.checksum, data.count == entry.uncompressedSize else { throw BookManifestError.invalid("Damaged timing data in ZIP.") }
        return data
    }
}

@MainActor
enum WordTimingUpdateCommit {
    /// Keep dictionary backups current while retaining the original source and track identities.
    static func apply(_ prepared: WordTimingUpdateService.Prepared, to item: LearningItem,
                      entries: [DictionaryEntry], save: () throws -> Void) throws -> Int {
        let previousTracks = item.tracks
        let previousRanges = entries.map { ($0, $0.audioStart, $0.audioEnd) }
        item.tracks = item.tracks.map { track in
            var result = track
            if let filename = prepared.filenames[track.id] { result.wordTimingsFilename = filename }
            return result
        }
        var updated = 0
        for entry in entries where (entry.localSourceItemID ?? entry.sourceItemID) == item.id {
            if let source = PhraseAudioSourceResolver.resolve(entry: entry, items: [item], ignoreManualRange: true), source.usesWordTimings {
                entry.audioStart = source.identity.range.lowerBound
                entry.audioEnd = source.identity.range.upperBound
                updated += 1
            }
        }
        do { try save() }
        catch {
            item.tracks = previousTracks
            for (entry, start, end) in previousRanges { entry.audioStart = start; entry.audioEnd = end }
            try? FileManager.default.removeItem(at: prepared.directory)
            throw error
        }
        return updated
    }
}
