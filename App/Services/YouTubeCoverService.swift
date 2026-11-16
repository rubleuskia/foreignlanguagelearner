import Foundation

enum YouTubeCoverService {
    /// Thumbnail downloads are optional: captions can still be saved when the CDN is unavailable.
    static func fetch(videoID: String,
                      download: @Sendable (URLRequest) async throws -> (URL, URLResponse) = {
                          try await URLSession.shared.download(for: $0)
                      }) async -> Data? {
        guard YouTubeImport.videoID(from: "https://www.youtube.com/watch?v=\(videoID)") == videoID else { return nil }
        for name in ["maxresdefault", "hqdefault"] {
            guard !Task.isCancelled else { return nil }
            let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            do {
                let (temporaryURL, response) = try await download(request)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { continue }
                return try BookCoverService.load(temporaryURL)
            } catch {
                // Higher-resolution thumbnails are not available for every video; try the standard cover.
                continue
            }
        }
        return nil
    }
}
