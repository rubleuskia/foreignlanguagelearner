import Foundation
import Observation

@MainActor @Observable final class CloudAlignmentModel {
    static let shared = CloudAlignmentModel()
    struct Draft: Codable {
        var title = ""
        var language = "pl"
        var audio: String?
        var audioName: String?
        var text: String?
        var textName: String?
        var key = UUID().uuidString.lowercased()
        var packageBytes: Int?
        var packageSHA256: String?
        var job: CloudAlignmentJob?
    }
    var draft = Draft()
    var working = false
    var activity = ""
    var error: String?
    var statusError: String?
    var jobs: [CloudAlignmentJob] = []
    let service: CloudAlignmentService
    private let directory: URL
    private var stateFile: URL { directory.appending(path: "draft.json") }
    var locked: Bool { draft.packageSHA256 != nil || draft.job != nil }
    var canUpload: Bool { draft.audio != nil && draft.text != nil && (1...200).contains(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count) }

    init(service: CloudAlignmentService = CloudAlignmentService(), directory: URL = CloudAlignmentFiles.root) {
        self.service = service; self.directory = directory
        if FileManager.default.fileExists(atPath: stateFile.path) {
            do { draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: stateFile)) }
            catch { self.error = error.localizedDescription }
        }
    }
    func save() throws {
        try CloudAlignmentFiles.initialize(directory)
        try JSONEncoder().encode(draft).write(to: stateFile, options: .atomic)
    }
    func saveFields() { do { try save() } catch { self.error = error.localizedDescription } }
    func select(_ url: URL, audio: Bool) async {
        guard !working, !locked else { return }
        working = true; activity = "Checking selected file…"; error = nil
        defer { working = false }
        do {
            let directory = directory
            let name = try await Task.detached { try CloudAlignmentFiles.stage(url, audio: audio, directory: directory) }.value
            let previous = audio ? draft.audio : draft.text
            if audio { draft.audio = name; draft.audioName = url.lastPathComponent }
            else {
                draft.text = name; draft.textName = url.lastPathComponent
                if draft.title.isEmpty { draft.title = url.deletingPathExtension().lastPathComponent }
            }
            try save()
            if let previous { try? FileManager.default.removeItem(at: directory.appending(path: previous)) }
        } catch { self.error = error.localizedDescription }
    }
    func upload() async {
        guard !working, canUpload, let audio = draft.audio, let text = draft.text else { return }
        working = true; activity = "Preparing upload ZIP…"; error = nil
        defer { working = false }
        do {
            let package: CloudAlignmentFiles.Package
            if let bytes = draft.packageBytes, let sha = draft.packageSHA256 {
                package = .init(bytes: bytes, sha256: sha)
            } else {
                let directory = directory
                package = try await Task.detached { try CloudAlignmentFiles.package(audio: audio, text: text, directory: directory) }.value
                draft.packageBytes = package.bytes; draft.packageSHA256 = package.sha256
                try save() // Freeze the exact payload before any potentially ambiguous network outcome.
            }
            if draft.job == nil {
                activity = "Creating alignment request…"
                draft.job = try await service.create(title: draft.title, language: draft.language, package: package, key: draft.key)
                try save()
            }
            guard let job = draft.job else { return }
            let current = try await service.status(job.id)
            draft.job = current; try save()
            if current.status == "awaiting_upload" {
                activity = "Uploading artifacts…"
                draft.job = try await service.upload(current.id, file: directory.appending(path: "input.zip"))
                try save()
            }
        } catch { self.error = error.localizedDescription }
    }
    func start() async {
        guard !working, let job = draft.job else { return }
        working = true; activity = "Adding book to queue…"; error = nil
        defer { working = false }
        do { draft.job = try await service.start(job.id); try save() }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !working else { return }
        do {
            if let job = draft.job {
                var latest = try await service.status(job.id)
                if latest.status == "awaiting_upload" {
                    // Recover a PUT that finished just before the app was closed.
                    if let completed = try? await service.complete(job.id) { latest = completed }
                }
                guard !working, draft.job?.id == job.id else { return }
                draft.job = latest; try save()
            }
            jobs = try await service.jobs()
            statusError = nil
        } catch is CancellationError { }
        catch { self.statusError = error.localizedDescription }
    }
    func reset() {
        guard !working else { return }
        do {
            let previous = draft
            draft = Draft(); try save()
            for name in [previous.audio, previous.text, "input.zip"].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
