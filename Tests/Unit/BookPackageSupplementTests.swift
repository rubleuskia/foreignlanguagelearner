import AVFoundation
import Foundation
import XCTest
import ZIPFoundation
@testable import ForeignLanguageLearner

final class BookPackageSupplementTests: XCTestCase {
    func testCatalogResourcesSurvivePrepareRetryAndLibraryMove() async throws {
        let provenance = Data(#"{"provider":"Wolne Lektury","url":"https://wolnelektury.pl/katalog/lektura/antek/","narration":[],"originalNotices":"Source attribution and license notices."}"#.utf8)
        let epub = Data("Original EPUB bytes retained without rewriting".utf8)
        for includeEPUB in [false, true] {
            let fixture = try Fixture(resources: ["provenance.json": provenance].merging(includeEPUB ? ["source.epub": epub] : [:]) { _, new in new })
            defer { fixture.remove() }
            let importer = BookImportService()
            let preview = try await importer.previewArchive(fixture.archive)
            do {
                XCTAssertTrue(preview.isManifestPackage)
                XCTAssertEqual(preview.ignoredFileCount, 0)
                for _ in 0..<2 {
                    let prepared = try await importer.prepare(preview, title: "Antek", orderedTracks: preview.tracks,
                        transcriptPath: preview.selectedTranscript, externalTranscript: nil)
                    XCTAssertEqual(try Data(contentsOf: prepared.stagedBookDirectory.appending(path: "provenance.json")), provenance)
                    if includeEPUB { XCTAssertEqual(try Data(contentsOf: prepared.stagedBookDirectory.appending(path: "source.epub")), epub) }
                }
                let prepared = try await importer.prepare(preview, title: "Antek", orderedTracks: preview.tracks,
                    transcriptPath: preview.selectedTranscript, externalTranscript: nil)
                try await importer.movePreparedToLibrary(prepared)
                let destination = MediaImportService.directory(for: prepared.itemID)
                XCTAssertEqual(try Data(contentsOf: destination.appending(path: "provenance.json")), provenance)
                if includeEPUB { XCTAssertEqual(try Data(contentsOf: destination.appending(path: "source.epub")), epub) }
                await importer.rollback(prepared)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            } catch {
                await importer.cancel(preview)
                throw error
            }
        }
    }

    func testUnknownFilesAndNestedSupplementNamesAreStillRejected() async throws {
        for path in ["notes.json", "nested/provenance.json", "nested/source.epub"] {
            let fixture = try Fixture(resources: [path: Data("Unexpected resource".utf8)])
            defer { fixture.remove() }
            do {
                let importer = BookImportService()
                let preview = try await importer.previewArchive(fixture.archive)
                await importer.cancel(preview)
                XCTFail("Unreferenced file accepted: \(path)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("unreferenced file: \(path)"), error.localizedDescription)
            }
        }
    }

    func testOversizedSupplementsAreRejectedBeforeAudioProcessing() async throws {
        for (path, maximum) in [("provenance.json", 2_000_000), ("source.epub", 10_000_000)] {
            let fixture = try Fixture(resources: [path: Data(repeating: 1, count: maximum + 1)])
            defer { fixture.remove() }
            do {
                let importer = BookImportService()
                let preview = try await importer.previewArchive(fixture.archive)
                await importer.cancel(preview)
                XCTFail("Oversized resource accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Package resource \(path) exceeds its \(maximum)-byte limit"), error.localizedDescription)
            }
        }
    }

    private struct Fixture {
        let directory: URL
        let archive: URL
        init(resources: [String: Data]) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            archive = directory.appending(path: "catalog.book.zip")
            let audio = directory.appending(path: "chapter.wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
            let zip = try Archive(url: archive, accessMode: .create)
            try zip.addEntry(with: "chapter.wav", fileURL: audio)
            let manifest = BookManifest(format: BookManifest.formatIdentifier, schemaVersion: 1, title: "Antek", sourceLanguage: "pl",
                transcript: "transcript.txt", tracks: [.init(id: "one", title: "One", audio: "chapter.wav",
                    alignmentStatus: .untimed, subtitle: nil, textRange: nil)], textMapping: nil)
            let files = resources.merging(["manifest.json": try JSONEncoder().encode(manifest), "transcript.txt": Data("A short story.".utf8)]) { _, new in new }
            for (index, entry) in files.sorted(by: { $0.key < $1.key }).enumerated() {
                let source = directory.appending(path: "file-\(index)")
                try entry.value.write(to: source)
                try zip.addEntry(with: entry.key, fileURL: source, compressionMethod: .none)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
