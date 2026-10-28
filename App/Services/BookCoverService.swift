import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Covers are bounded, downsampled images; originals never enter the library.
enum BookCoverService {
    static let maximumBytes = 16 * 1_024 * 1_024
    static let bundled = ["cover-books", "cover-white", "cover-leather", "cover-dark", "cover-ornate", "cover-yellow"]
    static let filename = "cover.jpg"

    static func isCoverPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().lastPathComponent.lowercased() == "cover"
            && ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }

    static func jpeg(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BookManifestError.invalid("Choose a valid cover image under 16 MiB.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BookManifestError.invalid("Could not prepare cover image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BookManifestError.invalid("Could not prepare cover image.") }
        return output as Data
    }

    static func load(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw BookManifestError.invalid("Choose a valid cover image under 16 MiB.")
        }
        return try jpeg(Data(contentsOf: url, options: .mappedIfSafe))
    }
}
