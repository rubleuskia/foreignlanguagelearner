import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ExamRunnerView: View {
    @ObservedObject var store: ExamStore
    @ObservedObject private var audio: ExamAudioController
    @State private var confirmingSubmit = false
    @State private var grading = false
    @State private var showingServerVersion = false
    @State private var exporting = false
    @State private var draft = ExamDraftDocument(data: Data())
    @State private var uiError: String?

    init(store: ExamStore) { self.store = store; self.audio = store.audio }

    var body: some View {
        Group {
            if let attempt = store.currentAttempt, let package = store.package,
               let section = package.section(attempt.sectionID), ["listening", "reading", "grammar"].contains(section.id) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header(attempt, section: section)
                        if store.hasConflict { conflictBanner }
                        if let error = store.errorMessage { Text(AppLanguage.text(error)).font(.subheadline).foregroundStyle(.red) }
                        if let error = uiError { Text(AppLanguage.text(error)).font(.subheadline).foregroundStyle(.red) }
                        if let error = audio.errorMessage { Text(AppLanguage.text(error)).font(.caption).foregroundStyle(.red) }
                        if let message = store.syncMessage { Text(AppLanguage.text(message)).font(.caption).foregroundStyle(.secondary) }
                        if section.id == "listening", attempt.mode == .exam {
                            ExamLockedTransport(position: audio.position, duration: audio.duration,
                                                started: audio.examStarted, finished: audio.examFinished, playing: audio.isPlaying) {
                                Task { await store.playExamAudio() }
                            }
                        }
                        if let result = attempt.objectiveResult {
                            ExamScoreSummary(objective: result.objectiveScoreUnits ?? 0,
                                             objectiveMaximum: result.autoMaxScoreUnits ?? 0,
                                             pendingMaximum: result.pendingScoreUnits ?? 0,
                                             overallMaximum: result.maxScoreUnits ?? section.maxScoreUnits,
                                             total: result.totalScoreUnits)
                            if (result.pendingScoreUnits ?? 0) > 0 {
                                Button {
                                    grading = true
                                    Task { await store.gradeAI(sectionID: section.id); grading = false }
                                } label: {
                                    HStack { Label(AppLanguage.text("Assess answers with AI"), systemImage: "sparkles"); if grading { ProgressView() } }
                                }.buttonStyle(.borderedProminent).disabled(grading || store.isLoading || store.hasConflict)
                                    .accessibilityIdentifier("exam.assess-ai")
                                Text(AppLanguage.text("AI assessment uses your current translation provider, model and reasoning settings."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if !store.canEdit {
                            Label(AppLanguage.text("Answers are saved. Waiting for the submitted result to synchronize."), systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(section.tasks.sorted { $0.position < $1.position }) { task in
                            ExamTaskView(store: store, audio: audio, task: task)
                        }
                        if store.canEdit {
                            Button {
                                let empty = section.tasks.flatMap(\.items).filter { store.answer(for: $0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                if empty.isEmpty { Task { await store.submit() } }
                                else { confirmingSubmit = true }
                            } label: {
                                HStack { Text(AppLanguage.text("Finish and check")); Spacer(); Image(systemName: "arrow.right") }
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).disabled(store.isLoading || store.hasConflict)
                                .accessibilityIdentifier("exam.submit")
                        }
                        Text(AppLanguage.text("The original wording, examples and source-page references are preserved. Your answers are saved as you work."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
                .confirmationDialog(AppLanguage.text("Finish this part?"), isPresented: $confirmingSubmit, titleVisibility: .visible) {
                    Button(AppLanguage.text("Finish and check")) { Task { await store.submit() } }
                    Button(AppLanguage.text("Continue working"), role: .cancel) { }
                } message: { Text(AppLanguage.text("Some answers are still empty. Submitted exam answers cannot be changed.")) }
            } else {
                ContentUnavailableView(AppLanguage.text("No active exam"), systemImage: "doc.text", description: Text(AppLanguage.text("Choose an exam part from the catalog.")))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(AppLanguage.text("Export answers"), systemImage: "square.and.arrow.up") { exportDraft() }
                    .disabled(store.currentAttempt == nil).accessibilityIdentifier("exam.export")
                NavigationLink { ContextualTranslationSettingsView() } label: { Label(AppLanguage.text("Assessment settings"), systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showingServerVersion) { ExamServerVersionView(store: store, exportLocal: exportDraft) }
        .fileExporter(isPresented: $exporting, document: draft, contentType: .json,
                      defaultFilename: "exam-\(store.currentAttempt?.id ?? "answers").json") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { uiError = error.localizedDescription }
        }
        .onDisappear { if store.currentAttempt?.mode == .training { store.pauseTraining() } }
        .task { store.tick() }
    }

    private func header(_ attempt: ExamAttempt, section: ExamSection) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppLanguage.text(attempt.mode == .training ? "Training" : "Exam")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(section.title).font(.system(.title, design: .serif)).fontWeight(.semibold)
                }
                Spacer(minLength: 8)
                if let seconds = store.remainingSeconds {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(ExamDisplay.clock(Double(seconds))).font(.title2.monospacedDigit()).fontWeight(.medium)
                            .accessibilityIdentifier("exam.remaining-time")
                        Text(AppLanguage.text("Remaining")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            let all = section.tasks.flatMap(\.items)
            let answered = all.filter { !store.answer(for: $0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            ProgressView(value: Double(answered), total: Double(max(1, all.count))) {
                Text(AppLanguage.format("%d / %d answers", answered, all.count)).font(.caption).foregroundStyle(.secondary)
            }
            if attempt.mode == .training, !attempt.state.isFinal {
                if attempt.state == .interrupted {
                    Button(AppLanguage.text("Continue training"), systemImage: "play") { Task { await store.resumeAttempt() } }.buttonStyle(.bordered)
                } else { Button(AppLanguage.text("Pause training"), systemImage: "pause") { store.pauseTraining() }.buttonStyle(.bordered) }
            }
            if attempt.mode == .exam, let deadline = attempt.deadlineAt {
                Text(AppLanguage.format("Deadline: %@. Answers submit automatically when time is up.", deadline.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var conflictBanner: some View {
        ExamSurface {
            VStack(alignment: .leading, spacing: 10) {
                Label(AppLanguage.text("Local answers are saved"), systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline)
                Text(store.conflictMessage ?? "This attempt changed on another device. Review the server version before choosing which answers to keep.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button(AppLanguage.text("Show server version")) { Task { await store.loadServerVersion(); showingServerVersion = true } }
                    Button(AppLanguage.text("Retry")) { Task { await store.retrySync() } }
                }.buttonStyle(.bordered)
                Button(AppLanguage.text("Export local answers"), systemImage: "square.and.arrow.up") { exportDraft() }.font(.caption)
            }
        }
    }
    private func exportDraft() {
        do { draft = ExamDraftDocument(data: try store.exportCurrentDraft()); exporting = true; uiError = nil }
        catch { uiError = error.localizedDescription }
    }
}

private struct ExamDraftDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
private struct ExamServerVersionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ExamStore
    let exportLocal: () -> Void
    @State private var confirmingServer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(AppLanguage.text("Your local answers are still saved"), systemImage: "checkmark.shield")
                    Text(AppLanguage.text("Viewing this version does not replace your local answers.")).font(.caption).foregroundStyle(.secondary)
                }
                if let attempt = store.serverConflictAttempt {
                    Section(AppLanguage.text("Server version")) {
                        Text(attempt.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(attempt.responseTexts.keys.sorted().enumerated()), id: \.element) { index, id in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(answerTitle(id, index: index)).font(.caption).foregroundStyle(.secondary)
                                Text(attempt.responseTexts[id] ?? "").textSelection(.enabled)
                            }
                        }
                    }
                    Section {
                        Button(AppLanguage.text("Keep my local answers")) { Task { await store.resolveConflict(useLocal: true); if !store.hasConflict { dismiss() } } }
                            .disabled(attempt.state.isFinal || attempt.submittedSectionIDs.contains(store.currentAttempt?.sectionID ?? ""))
                        Button(AppLanguage.text("Use server answers")) { confirmingServer = true }
                        Button(AppLanguage.text("Export local answers"), action: exportLocal)
                        if attempt.state.isFinal || attempt.submittedSectionIDs.contains(store.currentAttempt?.sectionID ?? "") {
                            Text(AppLanguage.text("This part has already ended on the server. Late local answers remain available for export, but cannot replace submitted exam answers."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else { ProgressView(AppLanguage.text("Loading server version…")) }
                if let error = store.errorMessage { Text(AppLanguage.text(error)).foregroundStyle(.red) }
            }
            .navigationTitle(AppLanguage.text("Compare versions")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLanguage.text("Done")) { dismiss() } } }
            .confirmationDialog(AppLanguage.text("Replace current answers with the server version?"), isPresented: $confirmingServer, titleVisibility: .visible) {
                Button(AppLanguage.text("Use server answers")) { Task { await store.resolveConflict(useLocal: false); if !store.hasConflict { dismiss() } } }
                Button(AppLanguage.text("Cancel"), role: .cancel) { }
            } message: { Text(AppLanguage.text("Export your local answers first if you want to keep a separate copy.")) }
        }
    }
    private func answerTitle(_ id: String, index: Int) -> String {
        if let package = store.package {
            for section in package.interactiveSections {
                for task in section.tasks {
                    if let item = task.items.first(where: { $0.id == id }) { return "Zadanie \(task.label) · \(item.label)" }
                }
            }
        }
        return "Answer \(index + 1)"
    }
}
