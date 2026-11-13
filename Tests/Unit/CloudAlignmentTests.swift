import Foundation
import XCTest
import ZIPFoundation
@testable import ForeignLanguageLearner

final class CloudAlignmentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testUnsupportedFormatAndOversizeRejectedBeforeCopy() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsupported = root.appending(path: "text.pdf")
        try Data("text".utf8).write(to: unsupported)
        XCTAssertThrowsError(try CloudAlignmentFiles.stage(unsupported, audio: false, directory: root))
        let audio = root.appending(path: "large.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: nil)
        let handle = try FileHandle(forWritingTo: audio)
        try handle.truncate(atOffset: UInt64(CloudAlignmentFiles.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try CloudAlignmentFiles.stage(audio, audio: true, directory: root))
    }
    func testPackagePreservesNaturalTrackOrderAndTextFormat() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appending(path: "tracks"); try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let source = root.appending(path: "tracks.zip")
        let archive = try Archive(url: source, accessMode: .create)
        for name in ["10.mp3", "2.mp3", "1.mp3"] {
            try Data(name.utf8).write(to: inputs.appending(path: name))
            try archive.addEntry(with: name, relativeTo: inputs)
        }
        try Data("A long book".utf8).write(to: root.appending(path: "book.txt"))
        let package = try CloudAlignmentFiles.package(audio: "tracks.zip", text: "book.txt", directory: root)
        XCTAssertGreaterThan(package.bytes, 0); XCTAssertEqual(package.sha256.count, 64)
        let output = try Archive(url: root.appending(path: "input.zip"), accessMode: .read)
        var data = Data()
        _ = try output.extract(try XCTUnwrap(output["audio-0001.mp3"])) { data.append($0) }
        XCTAssertEqual(String(data: data, encoding: .utf8), "2.mp3")
        data = Data()
        _ = try output.extract(try XCTUnwrap(output["input.json"])) { data.append($0) }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["text"] as? String, "text.txt")
    }
    @MainActor func testDraftAndRemoteStatusSurviveModelRecreation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CloudAlignmentModel(directory: root)
        model.draft.title = "Book"; model.draft.audio = "saved.mp3"; model.draft.text = "saved.txt"
        model.draft.job = CloudAlignmentJob(job_id: "saved-id", title: "Book", language: "en",
            status: "aligning", progress: 35, error_code: nil)
        try model.save()
        let restored = CloudAlignmentModel(directory: root)
        XCTAssertEqual(restored.draft.job?.status, "aligning")
        XCTAssertEqual(restored.draft.audio, "saved.mp3")
        XCTAssertEqual(restored.draft.key, model.draft.key)
        XCTAssertTrue(restored.locked)
    }
}
