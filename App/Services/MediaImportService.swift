import Foundation
import AVFoundation

actor MediaImportService {
    struct Imported: Sendable {
        let id: UUID
        let title: String
        let mediaKind: String
        let mediaFilename: String
        let transcriptFilename: String
        let duration: Double
        let document: TranscriptDocument
    }

    static func directory(for id: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Library/\(id.uuidString)", directoryHint: .isDirectory)
    }

    func importFiles(media: URL, transcript: URL) async throws -> Imported {
        let mediaAccess = media.startAccessingSecurityScopedResource()
        let transcriptAccess = transcript.startAccessingSecurityScopedResource()
        defer {
            if mediaAccess { media.stopAccessingSecurityScopedResource() }
            if transcriptAccess { transcript.stopAccessingSecurityScopedResource() }
        }
        let values = try transcript.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 10_000_000 else {
            throw TranscriptParser.ParseError.invalid("Choose a transcript smaller than 10 MB.")
        }
        let document = try TranscriptParser.parse(String(contentsOf: transcript, encoding: .utf8), extension: transcript.pathExtension)
        let id = UUID()
        let directory = Self.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let mediaName = "media.\(media.pathExtension.lowercased())"
            let transcriptName = "transcript.\(transcript.pathExtension.lowercased())"
            let destination = directory.appending(path: mediaName)
            try FileManager.default.copyItem(at: media, to: destination)
            try FileManager.default.copyItem(at: transcript, to: directory.appending(path: transcriptName))
            let asset = AVURLAsset(url: destination)
            guard try await asset.load(.isPlayable) else {
                throw TranscriptParser.ParseError.invalid("This media format cannot be played on this device.")
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw TranscriptParser.ParseError.invalid("The media has no valid duration.")
            }
            let isVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
            return Imported(id: id, title: media.deletingPathExtension().lastPathComponent,
                            mediaKind: isVideo ? "video" : "audio", mediaFilename: mediaName,
                            transcriptFilename: transcriptName, duration: duration, document: document)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
