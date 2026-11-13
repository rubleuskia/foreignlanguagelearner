import SwiftUI
import UniformTypeIdentifiers

struct CloudAlignmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CloudAlignmentModel.shared
    @State private var choosingAudio = true
    @State private var picking = false
    @State private var confirmingReset = false
    private let languages = ["en", "fr", "es", "de", "it", "pl"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Upload matching book audio and text to create synchronized subtitles and word timings.")
                    Text("TXT or EPUB · MP3, M4A, WAV or audio ZIP · 100 MB maximum prepared ZIP")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("1. Choose files") {
                    TextField("Book title", text: $model.draft.title)
                        .accessibilityIdentifier("alignment.title")
                    Picker("Source language", selection: $model.draft.language) {
                        ForEach(languages, id: \.self) { Text(SourceLanguage.name(for: $0)).tag($0) }
                    }
                    Button(model.draft.audioName ?? AppLanguage.text("Choose audio or audio ZIP")) {
                        choosingAudio = true; picking = true
                    }.accessibilityIdentifier("alignment.audio")
                    Button(model.draft.textName ?? AppLanguage.text("Choose TXT or EPUB")) {
                        choosingAudio = false; picking = true
                    }.accessibilityIdentifier("alignment.text")
                    Text("ZIP tracks are joined in filename order (1, 2, 10). Use matching, complete narration and text.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(model.locked || model.working)
                Section("2. Upload artifacts") {
                    if let bytes = model.draft.packageBytes { Text(AppLanguage.format("Prepared ZIP: %.1f MB", Double(bytes) / 1_000_000)) }
                    if let job = model.draft.job, job.status != "awaiting_upload" {
                        Label("Artifacts uploaded", systemImage: "checkmark.circle")
                    } else {
                        Button("Upload artifacts") { Task { await model.upload() } }
                            .disabled(!model.canUpload || model.working)
                            .accessibilityIdentifier("alignment.upload")
                    }
                }
                Section("3. Generate alignment") {
                    if let job = model.draft.job {
                        if job.status == "uploaded" {
                            Button("Generate alignment") { Task { await model.start() } }
                                .buttonStyle(.borderedProminent).disabled(model.working)
                                .accessibilityIdentifier("alignment.generate")
                        } else if job.status != "awaiting_upload" {
                            CloudAlignmentStatus(job: job, service: model.service)
                        }
                    } else { Text("Upload both artifacts first.").foregroundStyle(.secondary) }
                }
                if model.working { ProgressView(AppLanguage.text(model.activity)) }
                if let error = model.error ?? model.statusError {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("alignment.error")
                        Button("Refresh status") { Task { await model.refresh() } }.disabled(model.working)
                    }
                }
                if !model.jobs.isEmpty {
                    Section("Alignment requests") {
                        ForEach(model.jobs) { job in
                            NavigationLink {
                                CloudAlignmentJobView(initial: job, service: model.service)
                            } label: {
                                VStack(alignment: .leading) { Text(job.title); Text(job.statusText).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    Button("New alignment") { confirmingReset = true }.disabled(model.working)
                } footer: { Text("You can close the app during processing. Reopen this screen to restore the latest status. Cloud artifacts are kept for 30 days.") }
            }
            .nativeForm()
            .navigationTitle("Cloud alignment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: choosingAudio
                ? [.audio, .zip] : [.plainText, UTType(filenameExtension: "epub") ?? .data]) { result in
                    switch result {
                    case .success(let url): let audio = choosingAudio; Task { await model.select(url, audio: audio) }
                    case .failure(let error): model.error = error.localizedDescription
                    }
                }
            .confirmationDialog("Start a new alignment?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("New alignment") { model.reset() }
            } message: { Text("This clears the local draft. Submitted requests stay in the list.") }
            .onChange(of: model.draft.title) { model.saveFields() }
            .onChange(of: model.draft.language) { model.saveFields() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                } while !Task.isCancelled
            }
        }
    }
}

private struct CloudAlignmentStatus: View {
    let job: CloudAlignmentJob
    let service: CloudAlignmentService
    @State private var downloading = false
    @State private var error: String?
    private struct Result: Identifiable { let id = UUID(); let url: URL }
    @State private var result: Result?
    @State private var downloadedURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.statusText).accessibilityIdentifier("alignment.status")
            ProgressView(value: Double(job.progress), total: 100)
                .accessibilityValue("\(job.progress)%")
            if !job.terminal { Text("Progress follows processing stages; the alignment stage may take a while.").font(.footnote).foregroundStyle(.secondary) }
            if job.status == "succeeded_with_review" { Text("Listen to the result and review uncertain word timings.").font(.footnote) }
            if let code = job.error_code { Text(CloudAlignmentService.message(for: code)).foregroundStyle(.red) }
            if job.succeeded {
                Button("Download and import book") {
                    downloading = true; error = nil
                    Task {
                        defer { downloading = false }
                        do {
                            let url = try await service.download(job.id)
                            downloadedURL = url; result = Result(url: url)
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(downloading)
                    .accessibilityIdentifier("alignment.import")
            }
            if downloading { ProgressView("Downloading book…") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .sheet(item: $result, onDismiss: {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            downloadedURL = nil
        }) { BookImportView(suppliedArchive: $0.url) }
    }
}

private struct CloudAlignmentJobView: View {
    let initial: CloudAlignmentJob
    let service: CloudAlignmentService
    @State private var latest: CloudAlignmentJob?
    @State private var error: String?
    @State private var starting = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            if (latest ?? initial).status == "uploaded" {
                Button("Generate alignment") {
                    starting = true
                    Task {
                        defer { starting = false }
                        do { latest = try await service.start(initial.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(starting)
            }
            Section { CloudAlignmentStatus(job: latest ?? initial, service: service) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(initial.title)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                do { latest = try await service.status(initial.id); error = nil }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled && latest?.terminal != true
        }
    }
}
