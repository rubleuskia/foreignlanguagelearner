import AVFoundation
import Foundation
import ZIPFoundation

actor BookImportService {
    struct PreviewTrack: Identifiable, Equatable, Sendable {
        let id: String
        var title: String
        let sourcePath: String
        let mediaFilename: String
        let subtitleFilename: String?
        let duration: Double
        let alignmentStatus: TrackAlignmentStatus
    }

    struct Preview: Identifiable, Equatable, Sendable {
        let id: UUID
        let itemID: UUID
        var title: String
        let sourceLanguage: String
        var tracks: [PreviewTrack]
        let transcriptCandidates: [String]
        let selectedTranscript: String?
        let isManifestPackage: Bool
        let ignoredFileCount: Int
    }

    struct Prepared: Sendable {
        let transactionID: UUID
        let itemID: UUID
        let title: String
        let sourceLanguage: String
        let tracks: [LearningTrack]
        let transcriptFilename: String
        let duration: Double
        let stagedBookDirectory: URL
    }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            guard case .invalid(let value) = self else { return nil }
            return value
        }
    }

    private let limits: BookImportLimits
    private let fileManager: FileManager
    private var manifests: [UUID: BookManifest] = [:]

    init(limits: BookImportLimits = .standard, fileManager: FileManager = .default) {
        self.limits = limits
        self.fileManager = fileManager
    }

    static var stagingRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ImportStaging", directoryHint: .isDirectory)
    }

    func previewArchive(_ sourceURL: URL) async throws -> Preview {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, UInt64(size) <= limits.maximumArchiveBytes else { throw invalid("ZIP must be nonempty and no larger than 4 GiB.") }

        let transactionID = UUID()
        let root = Self.stagingRoot.appending(path: transactionID.uuidString, directoryHint: .isDirectory)
        let archiveURL = root.appending(path: "source.zip")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(resourceValues)
        do {
            try copyStreamed(from: sourceURL, to: archiveURL, maximumBytes: limits.maximumArchiveBytes)
            let archive = try Archive(url: archiveURL, accessMode: .read)
            let entries = Array(archive)
            guard entries.count <= limits.maximumEntries else { throw invalid("ZIP contains more than 1,000 entries.") }
            try validateEntries(entries)
            try checkCapacity(for: entries, at: root)
            if let manifestEntry = entries.first(where: { $0.path == "manifest.json" && $0.type == .file }) {
                return try await previewManifest(archive: archive, entries: entries, manifestEntry: manifestEntry,
                                                 transactionID: transactionID, root: root)
            }
            return try await previewRaw(archive: archive, entries: entries,
                                        transactionID: transactionID, root: root,
                                        suggestedTitle: sourceURL.deletingPathExtension().lastPathComponent)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func prepare(_ preview: Preview, title: String, sourceLanguage: String? = nil,
                 orderedTracks: [PreviewTrack], transcriptPath: String?,
                 externalTranscript: URL?) throws -> Prepared {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.unicodeScalars.count <= 500 else { throw invalid("Book title must contain 1–500 Unicode scalars.") }
        let language = sourceLanguage ?? preview.sourceLanguage
        guard language.range(of: "^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", options: .regularExpression) != nil,
              language.utf8.count <= 64 else { throw invalid("Source language must be an ASCII language tag.") }
        guard Set(orderedTracks.map(\.id)) == Set(preview.tracks.map(\.id)),
              orderedTracks.count == preview.tracks.count else { throw invalid("Track order contains missing or duplicate tracks.") }
        if preview.isManifestPackage, orderedTracks.map(\.id) != preview.tracks.map(\.id) {
            throw invalid("Manifest track order cannot be changed because it may carry text mappings.")
        }
        if preview.isManifestPackage, orderedTracks.map(\.title) != preview.tracks.map(\.title) {
            throw invalid("Manifest track titles cannot be edited during import.")
        }
        let root = Self.stagingRoot.appending(path: preview.id.uuidString, directoryHint: .isDirectory)
        let book = root.appending(path: "book", directoryHint: .isDirectory)
        let transcriptDestination = book.appending(path: "transcript.txt")
        if fileManager.fileExists(atPath: transcriptDestination.path) {
            try fileManager.removeItem(at: transcriptDestination)
        }
        if let externalTranscript {
            let accessed = externalTranscript.startAccessingSecurityScopedResource()
            defer { if accessed { externalTranscript.stopAccessingSecurityScopedResource() } }
            try copyStreamed(from: externalTranscript, to: transcriptDestination,
                             maximumBytes: UInt64(limits.maximumTranscriptBytes))
        } else if let transcriptPath {
            let candidate = root.appending(path: "transcript-candidates", directoryHint: .isDirectory)
                .appending(path: candidateName(for: transcriptPath))
            guard fileManager.fileExists(atPath: candidate.path) else { throw invalid("Choose a transcript from the ZIP or a separate TXT file.") }
            try fileManager.copyItem(at: candidate, to: transcriptDestination)
        } else if let selected = preview.selectedTranscript {
            let candidate = root.appending(path: "transcript-candidates", directoryHint: .isDirectory)
                .appending(path: candidateName(for: selected))
            try fileManager.copyItem(at: candidate, to: transcriptDestination)
        } else {
            throw invalid("Choose the book transcript before importing.")
        }
        let transcriptData = try Data(contentsOf: transcriptDestination, options: .mappedIfSafe)
        guard !transcriptData.isEmpty, transcriptData.count <= limits.maximumTranscriptBytes,
              String(data: transcriptData, encoding: .utf8) != nil else { throw invalid("Transcript must be nonempty UTF-8 under 10 MB.") }

        if var manifest = manifests[preview.id] {
            try BookManifestValidator.validate(manifest, transcriptData: transcriptData, limits: limits)
            manifest.title = cleanTitle
            try writeManifest(manifest, to: book.appending(path: "manifest.json"))
        } else {
            let tracks = orderedTracks.map {
                BookManifest.Track(id: $0.id, title: $0.title, audio: $0.mediaFilename,
                                   alignmentStatus: .untimed, subtitle: nil, textRange: nil)
            }
            let manifest = BookManifest(format: BookManifest.formatIdentifier,
                                        schemaVersion: BookManifest.schemaVersion, title: cleanTitle,
                                        sourceLanguage: language, transcript: "transcript.txt",
                                        tracks: tracks, textMapping: nil)
            try writeManifest(manifest, to: book.appending(path: "manifest.json"))
        }
        let learningTracks = orderedTracks.map {
            LearningTrack(id: $0.id, title: $0.title, mediaFilename: $0.mediaFilename,
                          subtitleFilename: $0.subtitleFilename, duration: $0.duration,
                          alignmentStatus: $0.alignmentStatus)
        }
        let duration = learningTracks.reduce(0) { $0 + $1.duration }
        guard duration.isFinite else { throw invalid("Combined duration is invalid.") }
        return Prepared(transactionID: preview.id, itemID: preview.itemID, title: cleanTitle,
                        sourceLanguage: language, tracks: learningTracks,
                        transcriptFilename: "transcript.txt", duration: duration,
                        stagedBookDirectory: book)
    }

    func movePreparedToLibrary(_ prepared: Prepared) throws {
        let final = MediaImportService.directory(for: prepared.itemID)
        guard !fileManager.fileExists(atPath: final.path) else { throw invalid("Import destination already exists.") }
        let journal = ImportJournal(transactionID: prepared.transactionID, itemID: prepared.itemID, state: .prepared)
        try writeJournal(journal)
        try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: prepared.stagedBookDirectory, to: final)
    }

    func complete(_ prepared: Prepared) {
        try? writeJournal(.init(transactionID: prepared.transactionID, itemID: prepared.itemID, state: .committed))
        cleanup(transactionID: prepared.transactionID, removeFinal: false, itemID: prepared.itemID)
        manifests[prepared.transactionID] = nil
    }

    func rollback(_ prepared: Prepared) {
        cleanup(transactionID: prepared.transactionID, removeFinal: true, itemID: prepared.itemID)
        manifests[prepared.transactionID] = nil
    }

    func cancel(_ preview: Preview) {
        cleanup(transactionID: preview.id, removeFinal: false, itemID: preview.itemID)
        manifests[preview.id] = nil
    }

    private func previewManifest(archive: Archive, entries: [Entry], manifestEntry: Entry,
                                 transactionID: UUID, root: URL) async throws -> Preview {
        let manifestData = try extractData(manifestEntry, from: archive, maximumBytes: limits.maximumManifestBytes)
        var manifest = try BookManifestValidator.decode(manifestData, limits: limits)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let allowed = Set(["manifest.json", manifest.transcript] + manifest.tracks.flatMap { [$0.audio, $0.subtitle].compactMap { $0 } })
        let unknown = entries.filter { $0.type == .file && !allowed.contains($0.path) && !isSystemMetadata($0.path) }
        guard unknown.isEmpty else { throw invalid("Strict package contains unreferenced file: \(unknown[0].path)") }
        guard let transcriptEntry = byPath[manifest.transcript], transcriptEntry.type == .file else { throw invalid("Manifest transcript is missing.") }
        let transcript = try extractData(transcriptEntry, from: archive, maximumBytes: limits.maximumTranscriptBytes)
        try BookManifestValidator.validate(manifest, transcriptData: transcript, limits: limits)
        let candidateDirectory = root.appending(path: "transcript-candidates", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        try transcript.write(to: candidateDirectory.appending(path: candidateName(for: manifest.transcript)), options: .atomic)
        let book = root.appending(path: "book", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: book.appending(path: "audio", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: book.appending(path: "subtitles", directoryHint: .isDirectory), withIntermediateDirectories: true)
        var subtitleTotal = 0
        var previewTracks: [PreviewTrack] = []
        for track in manifest.tracks {
            try Task.checkCancellation()
            guard let audioEntry = byPath[track.audio], audioEntry.type == .file else { throw invalid("Missing audio for track \(track.id).") }
            guard audioEntry.uncompressedSize <= limits.maximumAudioBytes else { throw invalid("Track \(track.id) exceeds the 2 GiB audio limit.") }
            let audioExtension = URL(fileURLWithPath: track.audio).pathExtension.lowercased()
            let mediaFilename = "audio/\(track.id).\(audioExtension)"
            let audioDestination = book.appending(path: mediaFilename)
            try extractFile(audioEntry, from: archive, to: audioDestination, maximumBytes: limits.maximumAudioBytes)
            let duration = try await probeAudio(audioDestination)
            var subtitleFilename: String?
            if let subtitle = track.subtitle {
                guard let subtitleEntry = byPath[subtitle], subtitleEntry.type == .file else { throw invalid("Missing subtitles for track \(track.id).") }
                guard subtitleEntry.uncompressedSize < limits.maximumSubtitleBytes else { throw invalid("Track \(track.id) subtitles reach the 10 MB limit.") }
                subtitleTotal += Int(subtitleEntry.uncompressedSize)
                guard subtitleTotal <= limits.maximumCombinedSubtitleBytes else { throw invalid("Combined subtitles exceed 50 MB.") }
                let subtitleExtension = URL(fileURLWithPath: subtitle).pathExtension.lowercased()
                subtitleFilename = "subtitles/\(track.id).\(subtitleExtension)"
                let destination = book.appending(path: subtitleFilename!)
                try extractFile(subtitleEntry, from: archive, to: destination, maximumBytes: UInt64(limits.maximumSubtitleBytes - 1))
                try validateSubtitle(destination, duration: duration)
            }
            previewTracks.append(.init(id: track.id, title: track.title, sourcePath: track.audio,
                                       mediaFilename: mediaFilename, subtitleFilename: subtitleFilename,
                                       duration: duration, alignmentStatus: track.alignmentStatus))
        }
        manifest.title = manifest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        manifests[transactionID] = manifest
        return .init(id: transactionID, itemID: UUID(), title: manifest.title,
                     sourceLanguage: manifest.sourceLanguage, tracks: previewTracks,
                     transcriptCandidates: [manifest.transcript], selectedTranscript: manifest.transcript,
                     isManifestPackage: true, ignoredFileCount: entries.filter { isSystemMetadata($0.path) }.count)
    }

    private func previewRaw(archive: Archive, entries: [Entry], transactionID: UUID,
                            root: URL, suggestedTitle: String) async throws -> Preview {
        let files = entries.filter { $0.type == .file && !isSystemMetadata($0.path) }
        let audio = files.filter { ["mp3", "m4a", "wav"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            .sorted(by: naturalPathOrder)
        guard (1...limits.maximumTracks).contains(audio.count) else { throw invalid("Raw ZIP must contain 1–100 supported audio files.") }
        let transcripts = files.filter { URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "txt" }
            .sorted(by: naturalPathOrder)
        let candidateDirectory = root.appending(path: "transcript-candidates", directoryHint: .isDirectory)
        let book = root.appending(path: "book", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: book.appending(path: "audio", directoryHint: .isDirectory), withIntermediateDirectories: true)
        for entry in transcripts {
            try extractFile(entry, from: archive, to: candidateDirectory.appending(path: candidateName(for: entry.path)),
                            maximumBytes: UInt64(limits.maximumTranscriptBytes))
        }
        var tracks: [PreviewTrack] = []
        for entry in audio {
            try Task.checkCancellation()
            guard entry.uncompressedSize <= limits.maximumAudioBytes else { throw invalid("Audio file exceeds 2 GiB: \(entry.path)") }
            let id = UUID().uuidString
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            let mediaFilename = "audio/\(id).\(ext)"
            let destination = book.appending(path: mediaFilename)
            try extractFile(entry, from: archive, to: destination, maximumBytes: limits.maximumAudioBytes)
            let duration = try await probeAudio(destination)
            let title = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
            tracks.append(.init(id: id, title: title, sourcePath: entry.path,
                                mediaFilename: mediaFilename, subtitleFilename: nil,
                                duration: duration, alignmentStatus: .untimed))
        }
        let known = Set(audio.map(\.path) + transcripts.map(\.path))
        let ignored = files.filter { !known.contains($0.path) }.count
        return .init(id: transactionID, itemID: UUID(),
                     title: suggestedTitle,
                     sourceLanguage: "pl", tracks: tracks,
                     transcriptCandidates: transcripts.map(\.path),
                     selectedTranscript: transcripts.count == 1 ? transcripts[0].path : nil,
                     isManifestPackage: false, ignoredFileCount: ignored)
    }

    private func validateEntries(_ entries: [Entry]) throws {
        var keys = Set<String>()
        var fileKeys = Set<String>()
        var directoryKeys = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            let checkedPath = entry.type == .directory && entry.path.hasSuffix("/")
                ? String(entry.path.dropLast()) : entry.path
            try BookManifestValidator.validatePath(checkedPath)
            guard entry.type != .symlink else { throw invalid("Symbolic links are not allowed in book archives.") }
            let key = BookManifestValidator.normalizedCollisionKey(checkedPath)
            guard keys.insert(key).inserted else { throw invalid("Archive contains duplicate or case/NFC-colliding paths.") }
            let sum = total.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= limits.maximumExtractedBytes else {
                throw invalid("Extracted ZIP content exceeds 8 GiB.")
            }
            total = sum.partialValue
            if entry.type == .directory { directoryKeys.insert(key) } else { fileKeys.insert(key) }
        }
        for file in fileKeys where directoryKeys.contains(file) { throw invalid("Archive path is both a file and directory.") }
        for file in fileKeys {
            let parts = file.split(separator: "/")
            for end in 1..<parts.count where fileKeys.contains(parts.prefix(end).joined(separator: "/")) {
                throw invalid("Archive file/directory paths collide.")
            }
        }
    }

    private func checkCapacity(for entries: [Entry], at url: URL) throws {
        let required = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           UInt64(max(0, available)) < required + UInt64(limits.reservedCapacityBytes) {
            throw invalid("Not enough free storage for this book plus the 256 MiB safety reserve.")
        }
    }

    private func extractData(_ entry: Entry, from archive: Archive, maximumBytes: Int) throws -> Data {
        var data = Data()
        let checksum = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximumBytes else { throw self.invalid("Archive entry exceeds its size limit: \(entry.path)") }
            data.append(chunk)
        }
        guard checksum == entry.checksum else { throw invalid("CRC mismatch for \(entry.path).") }
        return data
    }

    private func extractFile(_ entry: Entry, from archive: Archive, to destination: URL,
                             maximumBytes: UInt64) throws {
        guard entry.type == .file, entry.uncompressedSize <= maximumBytes else { throw invalid("Archive entry exceeds its size limit: \(entry.path)") }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: destination.path) else { throw invalid("Refusing to overwrite an extracted file.") }
        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var count: UInt64 = 0
        do {
            let checksum = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                count += UInt64(chunk.count)
                guard count <= maximumBytes else { throw self.invalid("Decoded entry exceeds its size limit: \(entry.path)") }
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            guard checksum == entry.checksum, count == entry.uncompressedSize else { throw invalid("CRC or decoded size mismatch for \(entry.path).") }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func probeAudio(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw invalid("Audio cannot be played: \(url.lastPathComponent)") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw invalid("Audio has invalid duration: \(url.lastPathComponent)") }
        guard try await asset.loadTracks(withMediaType: .audio).isEmpty == false else { throw invalid("File has no audio track: \(url.lastPathComponent)") }
        return duration
    }

    private func validateSubtitle(_ url: URL, duration: Double) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else { throw invalid("Subtitles must be UTF-8.") }
        let document = try TranscriptParser.parse(text, extension: url.pathExtension)
        for cue in document.segments {
            guard let start = cue.start, let end = cue.end, start.isFinite, end.isFinite,
                  start >= 0, start < end, end <= duration + 0.100 else { throw invalid("Subtitle cue exceeds track duration in \(url.lastPathComponent).") }
        }
    }

    private func writeManifest(_ manifest: BookManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func copyStreamed(from source: URL, to destination: URL, maximumBytes: UInt64) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let input = InputStream(url: source), let output = OutputStream(url: destination, append: false) else { throw invalid("Could not open selected file.") }
        input.open(); output.open()
        defer { input.close(); output.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var count: UInt64 = 0
        while input.hasBytesAvailable {
            try Task.checkCancellation()
            let read = input.read(&buffer, maxLength: buffer.count)
            guard read >= 0 else { throw input.streamError ?? invalid("Could not read selected file.") }
            if read == 0 { break }
            count += UInt64(read)
            guard count <= maximumBytes else { throw invalid("Selected file exceeds its size limit.") }
            var written = 0
            while written < read {
                let result = buffer.withUnsafeBufferPointer { pointer in
                    output.write(pointer.baseAddress! + written, maxLength: read - written)
                }
                guard result > 0 else { throw output.streamError ?? invalid("Could not copy selected file.") }
                written += result
            }
        }
    }

    private func naturalPathOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let comparison = lhs.path.localizedStandardCompare(rhs.path)
        if comparison == .orderedSame { return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) }
        return comparison == .orderedAscending
    }

    private func candidateName(for path: String) -> String {
        Data(path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".txt"
    }

    private func isSystemMetadata(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains("__MACOSX") || parts.contains(where: { $0 == ".DS_Store" || $0.hasPrefix(".") })
    }

    private func cleanup(transactionID: UUID, removeFinal: Bool, itemID: UUID) {
        if removeFinal { try? fileManager.removeItem(at: MediaImportService.directory(for: itemID)) }
        try? fileManager.removeItem(at: Self.stagingRoot.appending(path: transactionID.uuidString))
        try? fileManager.removeItem(at: ImportJournal.url(for: transactionID))
    }

    private func writeJournal(_ journal: ImportJournal) throws {
        try fileManager.createDirectory(at: ImportJournal.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: ImportJournal.url(for: journal.transactionID), options: [.atomic, .completeFileProtection])
    }

    private func invalid(_ message: String) -> ImportError { .invalid(message) }
}

struct ImportJournal: Codable, Sendable {
    enum State: String, Codable, Sendable { case prepared, committed }
    let transactionID: UUID
    let itemID: UUID
    let state: State

    static var root: URL { URL.applicationSupportDirectory.appending(path: "ImportJournals", directoryHint: .isDirectory) }
    static func url(for id: UUID) -> URL { root.appending(path: "\(id.uuidString).json") }
}
