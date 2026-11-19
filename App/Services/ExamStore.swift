import Combine
import Foundation

/// UI state for the exam domain. Answers and delivery intents are durable before publication.
@MainActor final class ExamStore: ObservableObject {
    @Published private(set) var catalog: [ExamCatalogEntry] = []
    @Published private(set) var package: ExamPackage?
    @Published private(set) var currentAttempt: ExamAttempt?
    @Published private(set) var attempts: [ExamAttempt] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSyncing = false
    @Published private(set) var isGrading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var conflictMessage: String?
    @Published private(set) var serverConflictAttempt: ExamAttempt?
    let audio = ExamAudioController()

    private let api: ExamAPIClient
    private let persistence: ExamPersistence
    private let assessment: ExamAssessmentService
    private var identity: ExamIdentity?
    private var local: ExamLocalState?
    private var storageFailed = false
    private var syncTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastTick = Date()
    private var lastAudioSave = Date.distantPast
    private var lastIdentityCheck = Date.distantPast
    private var serverTimeOffset: TimeInterval = 0
    private var autoSubmitting = false

    init(api: ExamAPIClient = ExamAPIClient(), persistence: ExamPersistence? = nil,
         assessment: ExamAssessmentService? = nil) {
        self.api = api; self.persistence = persistence ?? ExamPersistence()
        self.assessment = assessment ?? ExamAssessmentService(api: api)
        audio.onPosition = { [weak self] seconds in self?.recordAudio(seconds) }
        audio.onInterruption = { [weak self] in self?.recordSystemInterruption() }
        audio.onFinished = { [weak self] in self?.checkpoint() }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.tick()
            }
        }
    }

    var hasConflict: Bool { conflictMessage != nil }
    var canEdit: Bool {
        guard !storageFailed, !hasConflict, let a = currentAttempt, identity?.mode == TranslationRequestSettings.current.mode,
              a.state == .inProgress, !a.submittedSectionIDs.contains(a.sectionID),
              !a.submissionRequestedSectionIDs.contains(a.sectionID) else { return false }
        if a.mode == .exam, !a.serverCreated { return false }
        return remainingSeconds.map { $0 > 0 } ?? true
    }
    var remainingSeconds: Int? {
        guard let a = currentAttempt, a.mode == .exam, let deadline = a.deadlineAt else { return nil }
        return max(0, Int(ceil(deadline.timeIntervalSince(Date().addingTimeInterval(serverTimeOffset)))))
    }

    private func ensureIdentity() async throws -> ExamIdentity {
        do {
            let next = try await api.identity()
            if next.scopeID != identity?.scopeID {
                audio.close(); syncTask?.cancel(); syncTask = nil
                package = nil; currentAttempt = nil; catalog = []; attempts = []
                conflictMessage = nil; serverConflictAttempt = nil; local = nil; storageFailed = false
                let saved = try persistence.load(scopeID: next.scopeID)
                identity = next; local = saved; publish()
            }
            return next
        } catch {
            audio.close(); package = nil; currentAttempt = nil; catalog = []; attempts = []
            local = nil; identity = nil; conflictMessage = nil; serverConflictAttempt = nil
            throw error
        }
    }

    private func validateScope(_ scope: String) async throws {
        let next = try await api.identity()
        guard next.scopeID == scope, identity?.scopeID == scope else {
            _ = try await ensureIdentity(); throw ExamAPIError(code: "ACCOUNT_CHANGED")
        }
    }

    private func commit(_ next: ExamLocalState) throws {
        do { try persistence.commit(next); local = next; storageFailed = false; publish() }
        catch { storageFailed = true; errorMessage = ExamAPIError(code: "STORAGE_FAILED").localizedDescription; throw error }
    }
    private func publish() {
        guard let local else { return }
        catalog = local.catalog
        attempts = local.attempts.sorted { $0.updatedAt > $1.updatedAt }
        if let id = currentAttempt?.id { currentAttempt = local.attempts.first { $0.id == id } }
        let conflict = local.conflicts.first { $0.attemptID == currentAttempt?.id }
        conflictMessage = conflict?.message; serverConflictAttempt = conflict?.remote
    }

    func loadCatalog() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let identity = try await ensureIdentity()
            let values = try await api.catalog(expectedScope: identity.scopeID)
            try await validateScope(identity.scopeID)
            guard var next = local else { return }
            next.catalog = values; try commit(next)
            await synchronize()
            try await refreshAttemptList(scope: identity.scopeID)
        } catch {
            if catalog.isEmpty { errorMessage = error.localizedDescription }
            else { syncMessage = "Showing the downloaded catalog. \(error.localizedDescription)" }
        }
    }

    func openExam(_ entry: ExamCatalogEntry) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let identity = try await ensureIdentity()
            checkpoint(); audio.close(); currentAttempt = nil
            package = try await material(examID: entry.id, revision: entry.revision, scope: identity.scopeID)
            conflictMessage = nil; serverConflictAttempt = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func material(examID: String, revision: String, scope: String) async throws -> ExamPackage {
        var cached = try persistence.package(examID: examID, revision: revision, scopeID: scope)
        if cached == nil {
            cached = try await api.package(examID: examID, revision: revision, expectedScope: scope)
            try await validateScope(scope)
            try persistence.savePackage(cached!, scopeID: scope)
        }
        guard let package = cached else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        for source in package.sources {
            let exists = (try? persistence.verifiedSourceURL(source, package: package, scopeID: scope)) != nil
            if !exists {
                let bytes = try await api.download(source, package: package, expectedScope: scope)
                try await validateScope(scope)
                _ = try persistence.saveSource(bytes, source: source, package: package, scopeID: scope)
            }
        }
        return package
    }

    func start(sectionID: String, mode: ExamMode) async {
        errorMessage = nil
        do {
            let identity = try await ensureIdentity()
            guard let package, let section = package.interactiveSections.first(where: { $0.id == sectionID }), let state = local else { return }
            audio.snapshot(); audio.close()
            var attempt = ExamAttempt(examID: package.id, revision: package.revision, mode: mode, sectionID: sectionID, deviceID: state.deviceID)
            attempt.progress.taskID = section.tasks.first?.id
            var next = state; next.attempts.append(attempt)
            next.outbox.append(ExamSyncEvent(attemptID: attempt.id, kind: .create, body: [
                "attempt_id": .string(attempt.id), "exam_id": .string(attempt.examID), "revision": .string(attempt.revision),
                "mode": .string(mode.rawValue), "device_id": .string(next.deviceID), "section_ids": .array([.string(sectionID)])]))
            try commit(next); currentAttempt = attempt; lastTick = Date()
            await synchronize()
            try await validateScope(identity.scopeID)
            if mode == .exam, currentAttempt?.serverCreated != true {
                syncMessage = "Connect to start the exam timer. The attempt is saved and will be retried."; return
            }
            try await configureAudioIfNeeded(scope: identity.scopeID)
        } catch { errorMessage = error.localizedDescription }
    }

    func resume(_ attempt: ExamAttempt) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let identity = try await ensureIdentity()
            checkpoint(); audio.close()
            guard local?.attempts.contains(where: { $0.id == attempt.id }) == true else { return }
            package = try await material(examID: attempt.examID, revision: attempt.revision, scope: identity.scopeID)
            currentAttempt = local?.attempts.first { $0.id == attempt.id }; publish(); lastTick = Date()
            if let a = currentAttempt, a.serverCreated, a.deviceID != local?.deviceID, !a.state.isFinal {
                try recordConflict(attemptID: a.id, message: "This attempt is active on another device. Confirm which answers and audio position to continue.", remote: a)
                return
            }
            await synchronize()
            if let current = currentAttempt, current.state == .interrupted { await resumeAttempt() }
            else { try await configureAudioIfNeeded(scope: identity.scopeID) }
            tick()
        } catch { errorMessage = error.localizedDescription }
    }

    func answer(for itemID: String) -> String { currentAttempt?.responses[itemID]?.text ?? "" }

    func setAnswer(itemID: String, value: String) {
        guard canEdit, let a = currentAttempt, let section = package?.section(a.sectionID),
              let item = section.tasks.flatMap(\.items).first(where: { $0.id == itemID }), value.utf8.count <= 32_768,
              item.responseType != "multi_choice", var next = local,
              let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].responses[itemID] = .text(value)
        next.attempts[index].updatedAt = Date()
        enqueueUpdate(in: &next, attempt: next.attempts[index], responses: [itemID: .string(value)])
        do { try commit(next); scheduleSync() } catch { }
    }

    func selectTask(_ taskID: String) {
        guard let a = currentAttempt, package?.section(a.sectionID)?.tasks.contains(where: { $0.id == taskID }) == true,
              var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].progress.taskID = taskID
        if canEdit { enqueueUpdate(in: &next, attempt: next.attempts[index]) }
        do { try commit(next); if canEdit { scheduleSync() } } catch { }
    }

    func pauseTraining() {
        guard let a = currentAttempt, a.mode == .training, !a.state.isFinal,
              var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        audio.pause(); next.attempts[index].state = .interrupted
        enqueueUpdate(in: &next, attempt: next.attempts[index])
        do { try commit(next); scheduleSync() } catch { }
    }

    func resumeAttempt() async {
        do {
            let identity = try await ensureIdentity()
            guard var next = local, let a = currentAttempt, !a.state.isFinal, !hasConflict,
                  let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
            next.attempts[index].state = .inProgress; enqueueUpdate(in: &next, attempt: next.attempts[index])
            try commit(next); lastTick = Date()
            await synchronize()
            try await configureAudioIfNeeded(scope: identity.scopeID)
            audio.resumeAfterSystem()
        } catch { errorMessage = error.localizedDescription }
    }

    func submit() async {
        guard let a = currentAttempt, !a.submissionRequestedSectionIDs.contains(a.sectionID),
              !a.submittedSectionIDs.contains(a.sectionID), !hasConflict,
              var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].submissionRequestedSectionIDs.append(a.sectionID)
        next.attempts[index].state = .submitted; next.attempts[index].updatedAt = Date()
        next.outbox.append(ExamSyncEvent(attemptID: a.id, kind: .submit, body: ["section_id": .string(a.sectionID)]))
        do { try commit(next); audio.close(); await synchronize() }
        catch { errorMessage = error.localizedDescription }
    }

    private func enqueueUpdate(in state: inout ExamLocalState, attempt: ExamAttempt, responses: [String: ExamJSONValue] = [:]) {
        guard !attempt.submittedSectionIDs.contains(attempt.sectionID), !attempt.submissionRequestedSectionIDs.contains(attempt.sectionID) else { return }
        let progress = (try? ExamJSON.decoder().decode(ExamJSONValue.self, from: ExamJSON.encoder().encode(attempt.progress))) ?? .object([:])
        let body: [String: ExamJSONValue] = ["responses": .object(responses), "progress": progress,
            "state": .string(attempt.state == .interrupted ? "interrupted" : "in_progress")]
        if let last = state.outbox.indices.last, state.outbox[last].attemptID == attempt.id,
           state.outbox[last].kind == .update, state.outbox[last].sentBaseVersion == nil {
            let old = state.outbox[last].body["responses"]?.object ?? [:]
            state.outbox[last].body = body
            state.outbox[last].body["responses"] = .object(old.merging(responses) { _, new in new })
        } else { state.outbox.append(ExamSyncEvent(attemptID: attempt.id, kind: .update, body: body)) }
    }

    private func scheduleSync() {
        guard syncTask == nil, !hasConflict else { return }
        syncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            self?.syncTask = nil; await self?.synchronize()
        }
    }

    func synchronize() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let identity = try await ensureIdentity()
            while var next = local, let first = next.outbox.first {
                if next.conflicts.contains(where: { $0.attemptID == first.attemptID }) { break }
                guard let attemptIndex = next.attempts.firstIndex(where: { $0.id == first.attemptID }) else { throw ExamAPIError(code: "STORAGE_FAILED") }
                var event = first
                if event.kind != .create, event.sentBaseVersion == nil {
                    guard next.attempts[attemptIndex].version > 0 else { throw ExamAPIError(code: "STORAGE_FAILED") }
                    event.sentBaseVersion = next.attempts[attemptIndex].version
                    event.body["base_version"] = .number(Double(event.sentBaseVersion!))
                    event.body["change_id"] = .string(event.id.uuidString.lowercased())
                    event.body["device_id"] = .string(next.deviceID)
                    next.outbox[0] = event; try commit(next) // Freeze the exact payload before the first send.
                }
                let path = "v1/exam-attempts" + (event.kind == .create ? "" : "/\(event.attemptID)" + (event.kind == .submit ? "/submit" : ""))
                let method = event.kind == .update ? "PUT" : "POST"
                do {
                    let bytes = try await api.send(path, method: method, body: ExamJSON.encoder().encode(event.body), idempotencyKey: event.id, expectedScope: identity.scopeID)
                    let server = try ExamJSON.decoder().decode(ExamAttempt.self, from: bytes)
                    try await validateScope(identity.scopeID)
                    guard var saved = local else { return }
                    saved.outbox.removeAll { $0.id == event.id }
                    try merge(server, into: &saved); try commit(saved)
                } catch let error as ExamAPIError where error.isConflict {
                    let remote = try? await remoteAttempt(event.attemptID, scope: identity.scopeID)
                    try await validateScope(identity.scopeID)
                    try recordConflict(attemptID: event.attemptID, message: error.localizedDescription, remote: remote)
                    break
                } catch let error as ExamAPIError where error.isRejectedChange {
                    // A definitive rejection has not applied the event. Keep the draft
                    // and expose recovery instead of permanently blocking newer answers.
                    let remote = try? await remoteAttempt(event.attemptID, scope: identity.scopeID)
                    try await validateScope(identity.scopeID)
                    try recordConflict(attemptID: event.attemptID, message: error.localizedDescription, remote: remote)
                    break
                }
            }
            syncMessage = local?.outbox.isEmpty == true ? "Progress is synchronized." : "Local answers are saved. Synchronization is pending."
        } catch {
            syncMessage = "Local answers are saved. \(error.localizedDescription)"
            if (error as? ExamAPIError)?.code == "ACCOUNT_CHANGED" { errorMessage = error.localizedDescription }
        }
    }

    private func merge(_ server: ExamAttempt, into state: inout ExamLocalState) throws {
        guard server.ownerID == identity?.userID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
        var merged = server; merged.serverCreated = true
        let pending = state.outbox.filter { $0.attemptID == server.id }
        for event in pending {
            if event.kind == .update {
                for (key, value) in event.body["responses"]?.object ?? [:] {
                    if let text = value.string { merged.responses[key] = .text(text) }
                    else if let array = value.array { merged.responses[key] = .choices(array.compactMap(\.string)) }
                }
                if let value = event.body["progress"], let progress = try? ExamJSON.decoder().decode(ExamProgress.self, from: ExamJSON.encoder().encode(value)) { merged.progress = progress }
                if event.body["state"]?.string == "interrupted" { merged.state = .interrupted }
            } else if event.kind == .submit, let sectionID = event.body["section_id"]?.string {
                merged.submissionRequestedSectionIDs.append(sectionID); merged.state = .submitted
            }
        }
        if let i = state.attempts.firstIndex(where: { $0.id == server.id }) { state.attempts[i] = merged }
        else { state.attempts.append(merged) }
    }

    private func remoteAttempt(_ id: String, scope: String) async throws -> ExamAttempt {
        try ExamJSON.decoder().decode(ExamAttempt.self, from: await api.send("v1/exam-attempts/\(id)", expectedScope: scope))
    }
    private func refreshAttemptList(scope: String) async throws {
        struct List: Decodable { let attempts: [ExamAttempt] }
        let list = try ExamJSON.decoder().decode(List.self, from: await api.send("v1/exam-attempts", expectedScope: scope))
        try await validateScope(scope)
        guard var next = local else { return }
        for server in list.attempts where !next.conflicts.contains(where: { $0.attemptID == server.id }) {
            if !next.outbox.contains(where: { $0.attemptID == server.id }) { try merge(server, into: &next) }
        }
        try commit(next)
    }

    private func recordConflict(attemptID: String, message: String, remote: ExamAttempt?) throws {
        guard var next = local else { return }
        next.conflicts.removeAll { $0.attemptID == attemptID }
        next.conflicts.append(ExamSyncConflict(attemptID: attemptID, message: message, remote: remote))
        audio.close(); try commit(next)
    }
    func loadServerVersion() async {
        do {
            let identity = try await ensureIdentity()
            guard let a = currentAttempt else { return }
            let remote = try await remoteAttempt(a.id, scope: identity.scopeID)
            try await validateScope(identity.scopeID)
            try recordConflict(attemptID: a.id, message: conflictMessage ?? "Local answers are saved separately from the server version.", remote: remote)
        } catch { errorMessage = error.localizedDescription }
    }
    func retrySync() async { await synchronize() }
    func exportCurrentDraft() throws -> Data {
        guard let a = currentAttempt else { throw ExamAPIError(code: "STORAGE_FAILED") }
        return try ExamJSON.encoder().encode(a)
    }
    func resolveConflict(useLocal: Bool) async {
        do {
            let identity = try await ensureIdentity()
            guard let localAttempt = currentAttempt else { return }
            let remote = try await remoteAttempt(localAttempt.id, scope: identity.scopeID)
            try await validateScope(identity.scopeID)
            guard var next = local, let index = next.attempts.firstIndex(where: { $0.id == remote.id }) else { return }
            next.outbox.removeAll { $0.attemptID == remote.id }; next.conflicts.removeAll { $0.attemptID == remote.id }
            if useLocal {
                guard !remote.submittedSectionIDs.contains(localAttempt.sectionID), !remote.state.isFinal else {
                    throw ExamAPIError(code: "EXAM_SECTION_SUBMITTED", status: 409)
                }
                var retained = localAttempt; retained.version = remote.version; retained.serverCreated = true
                retained.state = .inProgress; retained.submissionRequestedSectionIDs = []
                next.attempts[index] = retained
                enqueueUpdate(in: &next, attempt: retained, responses: retained.responses.mapValues { value in
                    switch value { case .text(let s): .string(s); case .choices(let a): .array(a.map(ExamJSONValue.string)) }
                })
                if let last = next.outbox.indices.last { next.outbox[last].body["takeover"] = .bool(true) }
            } else { next.attempts[index] = remote }
            try commit(next); await synchronize()
            try await configureAudioIfNeeded(scope: identity.scopeID)
        } catch { errorMessage = error.localizedDescription }
    }

    func gradeAI(sectionID: String) async {
        guard !isGrading else { return }
        isGrading = true; errorMessage = nil
        defer { isGrading = false }
        do {
            let identity = try await ensureIdentity()
            await synchronize()
            guard let a = currentAttempt, a.submittedSectionIDs.contains(sectionID), !hasConflict,
                  let section = a.result?.sections.first(where: { $0.sectionID == sectionID }) else { return }
            let pending = Set(section.items.filter { $0.awardedScoreUnits == nil }.map(\.taskID))
            for taskID in pending.sorted() where a.aiResults?[taskID] == nil {
                let value = try await assessment.assess(examID: a.examID, revision: a.revision, attemptID: a.id, taskID: taskID, responses: a.responseTexts)
                try await validateScope(identity.scopeID)
                guard var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
                if next.attempts[index].aiResults == nil { next.attempts[index].aiResults = [:] }
                next.attempts[index].aiResults?[taskID] = value; try commit(next)
            }
            let server = try await remoteAttempt(a.id, scope: identity.scopeID)
            try await validateScope(identity.scopeID)
            if var next = local { try merge(server, into: &next); try commit(next) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func configureAudioIfNeeded(scope: String) async throws {
        guard let a = currentAttempt, a.sectionID == "listening", !a.state.isFinal, !hasConflict,
              a.mode == .training || a.serverCreated, let package, let manifest = package.audio,
              let source = package.sources.first(where: { $0.id == manifest.source.sourceID }),
              source.sha256 == manifest.source.sha256,
              let url = try persistence.verifiedSourceURL(source, package: package, scopeID: scope) else { return }
        try await audio.configure(url: url, manifest: manifest, mode: a.mode,
                                  position: Double(a.progress.audioCursorMS) / 1000, taskID: a.progress.taskID)
    }
    func audioWindow(for taskID: String) -> ClosedRange<Double>? {
        audio.window(for: taskID) ?? package?.audio?.tasks.first(where: { "listening-" + $0.taskLabel == taskID })?.window
    }
    func playTask(_ taskID: String) async {
        guard canEdit, currentAttempt?.mode == .training else { return }
        selectTask(taskID)
        do { try await audio.play(taskID: taskID) } catch { errorMessage = error.localizedDescription }
    }
    func seekTask(_ taskID: String, seconds: Double) async {
        guard canEdit, currentAttempt?.mode == .training else { return }
        selectTask(taskID)
        do { try await audio.prepare(taskID: taskID); audio.seek(seconds: seconds) }
        catch { errorMessage = error.localizedDescription }
    }
    func playExamAudio() async {
        guard let attempt = currentAttempt, attempt.mode == .exam else { return }
        if attempt.state == .interrupted { await resumeAttempt(); return }
        guard canEdit else { return }
        do { try audio.resumeExam() } catch { errorMessage = error.localizedDescription }
    }

    func sourceURL(_ ref: ExamSourceReference) -> URL? {
        guard let package, let identity, let source = package.sources.first(where: { $0.id == ref.sourceID }),
              let local = try? persistence.sourceURL(source, package: package, scopeID: identity.scopeID),
              FileManager.default.fileExists(atPath: local.path) else { return nil }
        guard let page = ref.page else { return local }
        var components = URLComponents(url: local, resolvingAgainstBaseURL: false)
        components?.fragment = "page=\(page)"
        return components?.url
    }

    private func recordAudio(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0, let a = currentAttempt, !a.state.isFinal,
              var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].progress.audioCursorMS = Int((seconds * 1000).rounded())
        // Save each second, including while the player is running in the background.
        guard Date().timeIntervalSince(lastAudioSave) >= 1 else { return }
        lastAudioSave = Date(); enqueueUpdate(in: &next, attempt: next.attempts[index])
        do { try commit(next); scheduleSync() } catch { }
    }
    private func recordSystemInterruption() {
        guard let a = currentAttempt, !a.state.isFinal, var next = local,
              let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].progress.audioCursorMS = Int((audio.position * 1000).rounded())
        // A forced audio interruption does not pause the examination or disable answers.
        // Training has an explicit paused state; exam deadlines continue unchanged.
        if a.mode == .training { next.attempts[index].state = .interrupted }
        enqueueUpdate(in: &next, attempt: next.attempts[index])
        do { try commit(next); scheduleSync() } catch { }
    }
    func checkpoint() {
        guard let a = currentAttempt, !a.state.isFinal, var next = local,
              let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        if a.sectionID == "listening" { next.attempts[index].progress.audioCursorMS = Int((audio.position * 1000).rounded()) }
        enqueueUpdate(in: &next, attempt: next.attempts[index])
        do { try commit(next); scheduleSync() } catch { }
    }
    func tick(now: Date = Date()) {
        if now.timeIntervalSince(lastIdentityCheck) >= 1 {
            lastIdentityCheck = now
            Task { @MainActor [weak self] in
                do { _ = try await self?.ensureIdentity() }
                catch { self?.errorMessage = error.localizedDescription }
            }
        }
        let delta = max(0, min(now.timeIntervalSince(lastTick), 10)); lastTick = now
        guard let a = currentAttempt else { return }
        if remainingSeconds == 0, !a.submittedSectionIDs.contains(a.sectionID),
           !a.submissionRequestedSectionIDs.contains(a.sectionID), !autoSubmitting, !hasConflict {
            autoSubmitting = true
            Task { @MainActor [weak self] in await self?.submit(); self?.autoSubmitting = false }
            return
        }
        guard canEdit, var next = local, let index = next.attempts.firstIndex(where: { $0.id == a.id }) else { return }
        next.attempts[index].progress.elapsedMS[a.sectionID, default: 0] += Int(delta * 1000)
        if a.sectionID == "listening" { next.attempts[index].progress.audioCursorMS = Int((audio.position * 1000).rounded()) }
        enqueueUpdate(in: &next, attempt: next.attempts[index])
        do { try commit(next); scheduleSync() } catch { }
    }
}
