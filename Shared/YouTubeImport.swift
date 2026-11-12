import Foundation

struct YouTubeImport: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var videoID: String
    var title: String
    var language: String
    var duration: Double
    var cues: [Cue]

    struct Cue: Codable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    static func videoID(from value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let id: String?
        if host == "youtu.be" { id = parts.first }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) {
            if url.path == "/watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count == 2, ["shorts", "embed"].contains(parts[0]) { id = parts[1] }
            else { id = nil }
        } else { return nil }
        guard let id, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return id
    }

    func validated() throws -> Self {
        guard Self.videoID(from: "https://www.youtube.com/watch?v=\(videoID)") == videoID,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500,
              language.range(of: "^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$", options: .regularExpression) != nil,
              duration.isFinite, duration > 0, duration <= 86_400,
              !cues.isEmpty, cues.count <= 100_000 else { throw Failure.invalid }
        var previous = -Double.infinity
        var length = 0
        for cue in cues {
            length += cue.text.utf8.count
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.start >= previous,
                  cue.end > cue.start, cue.end <= duration + 1,
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  length <= 5_000_000 else { throw Failure.invalid }
            previous = cue.start
        }
        return self
    }

    enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: "The YouTube subtitles are invalid or exceed the supported limits."
            case .unavailable: "Play the video in Safari, enable subtitles in the desired language, then share the page again."
            }
        }
    }
}

enum YouTubeInbox {
    static let group = "group.com.rubleuskia.foreignlanguagelearner.youtube"
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("YouTubeImports", isDirectory: true)
    }

    static func save(_ payload: YouTubeImport) throws {
        let value = try payload.validated()
        guard let directory else { throw YouTubeImport.Failure.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard pending.count < 20 else { throw YouTubeImport.Failure.invalid }
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(value.id.uuidString + ".json"), options: .atomic)
    }

    static func pending() throws -> [(URL, YouTubeImport)] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(20).map { url in
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10_000_000 else {
                    throw YouTubeImport.Failure.invalid
                }
                return (url, try JSONDecoder().decode(YouTubeImport.self, from: Data(contentsOf: url)).validated())
            }
    }
}
