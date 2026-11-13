import CryptoKit
import Foundation
import ZIPFoundation

enum CloudAlignmentFiles {
    static let maximumBytes = 100_000_000
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav"]
    static var root: URL { URL.applicationSupportDirectory.appending(path: "CloudAlignment", directoryHint: .isDirectory) }
    struct Package: Sendable { let bytes: Int; let sha256: String }
    static func invalid(_ text: String) -> NSError {
        NSError(domain: "CloudAlignment", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLanguage.text(text)])
    }
    static func initialize(_ directory: URL = root) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    static func stage(_ source: URL, audio: Bool, directory: URL = root) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard (audio ? audioExtensions.union(["zip"]) : ["txt", "epub"]).contains(ext) else {
            throw invalid(audio ? "Choose MP3, M4A, WAV or an audio ZIP." : "Choose UTF-8 TXT or EPUB.")
        }
        let limit = audio ? maximumBytes : 10_000_000
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let bytes = size.fileSize, bytes > 0, bytes <= limit else {
            throw invalid(audio ? "Audio or ZIP must be between 1 byte and 100 MB." : "Book text must be between 1 byte and 10 MB.")
        }
        try initialize(directory)
        let name = "\(UUID().uuidString).\(ext)"
        let target = directory.appending(path: name)
        do {
            try copy(source, to: target, limit: limit)
            if ext == "zip" { _ = try audioEntries(target) }
            if ext == "txt" {
                let data = try Data(contentsOf: target)
                guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("Choose a nonempty UTF-8 TXT file.")
                }
            }
            if ext == "epub" {
                let archive = try Archive(url: target, accessMode: .read)
                guard Array(archive).count <= 5000, archive.reduce(UInt64(0), { $0 + $1.uncompressedSize }) <= 200_000_000,
                      let entry = archive["mimetype"], entry.uncompressedSize < 100 else { throw invalid("Invalid EPUB file.") }
                var mime = Data()
                _ = try archive.extract(entry) { mime.append($0) }
                guard String(data: mime, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
                    throw invalid("Invalid EPUB file.")
                }
            }
            return name
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    static func copy(_ source: URL, to target: URL, limit: Int) throws {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let incoming = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
        defer { try? incoming.close(); try? output.close() }
        var count = 0
        while let block = try incoming.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            count += block.count
            guard count <= limit else { throw invalid("File exceeds the size limit.") }
            try output.write(contentsOf: block)
        }
    }
    static func audioEntries(_ url: URL) throws -> [Entry] {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= 1000, entries.reduce(UInt64(0), { $0 + $1.uncompressedSize }) <= 1_000_000_000 else {
            throw invalid("Audio ZIP contains too many files or expands beyond 1 GB.")
        }
        var seen = Set<String>()
        var tracks: [Entry] = []
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            try BookManifestValidator.validatePath(path)
            guard entry.type != .symlink, seen.insert(BookManifestValidator.normalizedCollisionKey(path)).inserted else {
                throw invalid("Audio ZIP contains unsafe or duplicate paths.")
            }
            if entry.type == .directory { continue }
            let components = path.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { continue }
            guard audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                throw invalid("Audio ZIP must contain only MP3, M4A or WAV tracks.")
            }
            tracks.append(entry)
        }
        guard !tracks.isEmpty, tracks.count <= 500 else { throw invalid("Choose a ZIP with 1–500 audio tracks.") }
        return tracks.sorted {
            $0.path.compare($1.path, options: [.numeric, .literal], locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
        }
    }
    static func package(audio: String, text: String, directory: URL = root) throws -> Package {
        let temporary = directory.appending(path: "building-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = directory.appending(path: audio)
        var names: [String] = []
        if source.pathExtension == "zip" {
            let archive = try Archive(url: source, accessMode: .read)
            for (index, entry) in try audioEntries(source).enumerated() {
                try Task.checkCancellation()
                let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                let name = String(format: "audio-%04d.%@", index, ext)
                let target = temporary.appending(path: name)
                let crc = try archive.extract(entry, to: target)
                guard crc == entry.checksum else { throw invalid("Audio ZIP is damaged.") }
                names.append(name)
            }
        } else {
            let name = "audio.\(source.pathExtension)"
            try FileManager.default.copyItem(at: source, to: temporary.appending(path: name))
            names = [name]
        }
        let textName = "text.\(URL(fileURLWithPath: text).pathExtension)"
        try FileManager.default.copyItem(at: directory.appending(path: text), to: temporary.appending(path: textName))
        let manifest: [String: Any] = ["schemaVersion": 1, "audio": names, "text": textName]
        try JSONSerialization.data(withJSONObject: manifest).write(to: temporary.appending(path: "input.json"))
        let output = temporary.appending(path: "input.zip")
        let zip = try Archive(url: output, accessMode: .create)
        for name in names + [textName, "input.json"] {
            try Task.checkCancellation()
            try zip.addEntry(with: name, relativeTo: temporary, compressionMethod: .deflate)
            guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumBytes else {
                throw invalid("The prepared ZIP exceeds 100 MB. Choose smaller files.")
            }
        }
        let result = try inspect(output)
        guard result.bytes <= maximumBytes else { throw invalid("The prepared ZIP exceeds 100 MB. Choose smaller files.") }
        let final = directory.appending(path: "input.zip")
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: output, to: final)
        return result
    }
    static func inspect(_ url: URL) throws -> Package {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), bytes = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); digest.update(data: chunk); bytes += chunk.count
        }
        return Package(bytes: bytes, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
