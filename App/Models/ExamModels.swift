import Foundation

/// A lossless value for source metadata and evolving, non-secret presentation fields.
enum ExamJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([ExamJSONValue]), object([String: ExamJSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([ExamJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ExamJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var object: [String: ExamJSONValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [ExamJSONValue]? { if case .array(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) { Int(v) } else { nil } }
}

enum ExamJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

struct ExamSourceReference: Codable, Equatable, Hashable, Sendable {
    let sourceID: String
    var page: Int? = nil
    var startMS: Int? = nil
    var endMS: Int? = nil
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", page, startMS = "start_ms", endMS = "end_ms"
    }
}

struct ExamSource: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let path: String
    let sha256: String
    let bytes: Int64
    let mediaType: String
    var pageCount: Int? = nil
    var downloadPath: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, url, path, sha256, bytes, mediaType = "media_type", pageCount = "page_count", downloadPath = "download_path"
    }
}

struct ExamSession: Codable, Equatable, Sendable {
    let label: String
    let startDate: String
    let endDate: String
    enum CodingKeys: String, CodingKey { case label, startDate = "start_date", endDate = "end_date" }
}

struct ExamCatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let revision: String
    let title: String
    let language: String
    let level: String
    let audience: String
    let session: ExamSession
    var interactiveSectionIDs: [String]? = nil
    var sections: [ExamCatalogSection]? = nil
    var downloadBytes: Int64? = nil
    var status: String? = nil
    var availableSectionIDs: [String] { interactiveSectionIDs ?? sections?.map(\.id).filter { ["listening", "reading", "grammar"].contains($0) } ?? [] }
    var sessionLabel: String { session.label }
    enum CodingKeys: String, CodingKey {
        case id, revision, title, language, level, audience, session, sections, status
        case interactiveSectionIDs = "interactive_section_ids", downloadBytes = "download_bytes"
    }
}

struct ExamCatalogSection: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    var status: String? = nil
    let maxScoreUnits: Int
    var timeLimitSeconds: Int? = nil
    enum CodingKeys: String, CodingKey { case id, title, status, maxScoreUnits = "max_score_units", timeLimitSeconds = "time_limit_seconds" }
}

struct ExamCatalogEnvelope: Decodable, Sendable {
    let schemaVersion: String
    let exams: [ExamCatalogEntry]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", exams }
}

/// The student projection deliberately has no grading keys or private assessment contracts.
struct ExamPackage: Codable, Identifiable, Sendable {
    let schemaVersion: String
    let id: String
    let revision: String
    let title: String
    let language: String
    let level: String
    let audience: String
    let session: ExamSession
    let sources: [ExamSource]
    let sections: [ExamSection]
    var provenance: ExamJSONValue? = nil
    var sourceOutline: ExamJSONValue? = nil
    var audio: ExamAudioManifest? = nil
    var interactiveSections: [ExamSection] { sections.filter { ["listening", "reading", "grammar"].contains($0.id) && $0.status != "source_missing" } }
    func section(_ id: String) -> ExamSection? { sections.first { $0.id == id } }
    func task(_ id: String) -> ExamTask? { sections.lazy.flatMap(\.tasks).first { $0.id == id } }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, revision, title, language, level, audience, session, sources, sections, provenance, audio
        case sourceOutline = "source_outline"
    }
}

struct ExamPackageEnvelope: Decodable, Sendable {
    var schemaVersion: String? = nil
    var exam: ExamPackage
    var audio: ExamAudioManifest? = nil
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", exam, audio }
}

struct ExamSection: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let position: Int
    var timeLimitSeconds: Int? = nil
    let maxScoreUnits: Int
    let sourceRefs: [ExamSourceReference]
    var status: String? = nil
    let tasks: [ExamTask]
    var selection: ExamJSONValue? = nil
    var instruction: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, title, position, status, tasks, selection, instruction
        case timeLimitSeconds = "time_limit_seconds", maxScoreUnits = "max_score_units", sourceRefs = "source_refs"
    }
}

struct ExamTask: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let position: Int
    var title: String? = nil
    let instruction: String
    let interactionType: String
    let maxScoreUnits: Int
    let sourceRefs: [ExamSourceReference]
    let blocks: [ExamBlock]
    let options: [ExamOption]
    let items: [ExamItem]
    var presentation: ExamPresentation? = nil
    enum CodingKeys: String, CodingKey {
        case id, label, position, title, instruction, blocks, options, items, presentation
        case interactionType = "interaction_type", maxScoreUnits = "max_score_units", sourceRefs = "source_refs"
    }
}

struct ExamBlock: Codable, Identifiable, Sendable {
    let id: String
    let type: String
    let text: String
    let sourceRefs: [ExamSourceReference]
    var answer: String? = nil
    var underlinedText: String? = nil
    var role: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, type, text, answer, role, sourceRefs = "source_refs", underlinedText = "underlined_text"
    }
}

struct ExamOption: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let text: String
    let sourceRefs: [ExamSourceReference]
    enum CodingKeys: String, CodingKey { case id, label, text, sourceRefs = "source_refs" }
}

struct ExamItem: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let position: Int
    let prompt: String
    var context: String? = nil
    var underlinedText: String? = nil
    var requiredWord: String? = nil
    let responseType: String
    let optionIDs: [String]
    var maxScoreUnits: Int? = nil
    let sourceRefs: [ExamSourceReference]
    var input: ExamJSONValue? = nil
    enum CodingKeys: String, CodingKey {
        case id, label, position, prompt, context, input
        case underlinedText = "underlined_text", requiredWord = "required_word", responseType = "response_type"
        case optionIDs = "option_ids", maxScoreUnits = "max_score_units", sourceRefs = "source_refs"
    }
}

struct ExamPresentation: Codable, Sendable {
    let layout: String
    var rows: [ExamPresentationRow]? = nil
    var displayCodes: [String: String]? = nil
    var bankPosition: String? = nil
    var optionBank: String? = nil
    var inputFormat: String? = nil
    var exampleAnswer: String? = nil
    var exampleOptionIDs: [String]? = nil
    var suppressExampleBlocks: Bool? = nil
    var showExampleInTable: Bool? = nil
    var answerLabel: String? = nil
    var promptHeader: String? = nil
    var answerHeader: String? = nil
    var columns: [String]? = nil
    var sourceRefs: [ExamSourceReference]? = nil
    enum CodingKeys: String, CodingKey {
        case layout, rows, columns, displayCodes = "display_codes", bankPosition = "bank_position", optionBank = "option_bank"
        case inputFormat = "input_format", exampleAnswer = "example_answer", exampleOptionIDs = "example_option_ids"
        case suppressExampleBlocks = "suppress_example_blocks", showExampleInTable = "show_example_in_table", answerLabel = "answer_label", sourceRefs = "source_refs"
        case promptHeader = "prompt_header", answerHeader = "answer_header"
    }
}

struct ExamPresentationRow: Codable, Sendable {
    var label: String? = nil
    var left: String? = nil
    var right: String? = nil
    var rightLabel: String? = nil
    var itemID: String? = nil
    var leftItemID: String? = nil
    var statement: String? = nil
    var underlinedText: String? = nil
    var questionTemplate: String? = nil
    var answerLine: String? = nil
    var requiredWord: String? = nil
    var sourceRefs: [ExamSourceReference]? = nil
    enum CodingKeys: String, CodingKey {
        case label, left, right, statement, rightLabel = "right_label", itemID = "item_id", leftItemID = "left_item_id"
        case underlinedText = "underlined_text", questionTemplate = "question_template", answerLine = "answer_line", requiredWord = "required_word", sourceRefs = "source_refs"
    }
}

struct ExamAudioManifest: Codable, Sendable {
    let schemaVersion: Int
    let source: ExamAudioSource
    let timestampUnit: String
    var reviewStatus: String? = nil
    let tasks: [ExamAudioTask]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", source, timestampUnit = "timestamp_unit", reviewStatus = "review_status", tasks
    }
}
struct ExamAudioSource: Codable, Sendable {
    let sourceID: String
    let sha256: String
    let durationMS: Int
    enum CodingKeys: String, CodingKey { case sourceID = "source_id", sha256, durationMS = "duration_ms" }
}
struct ExamAudioTask: Codable, Sendable {
    let taskLabel: String
    let occurrences: [ExamAudioOccurrence]
    var window: ClosedRange<Double>? {
        guard let first = occurrences.map(\.startMS).min(), let last = occurrences.map(\.endMS).max(), last > first else { return nil }
        return Double(first) / 1000...Double(last) / 1000
    }
    enum CodingKeys: String, CodingKey { case taskLabel = "task_label", occurrences }
}
struct ExamAudioOccurrence: Codable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let startMS: Int
    let endMS: Int
    let role: String
    var reviewStatus: String? = nil
    enum CodingKeys: String, CodingKey { case id, sourceID = "source_id", startMS = "start_ms", endMS = "end_ms", role, reviewStatus = "review_status" }
}

enum ExamAnswer: Codable, Equatable, Sendable {
    case text(String), choices([String])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .choices(try c.decode([String].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .text(let s): try c.encode(s); case .choices(let a): try c.encode(a) }
    }
    var text: String { switch self { case .text(let s): s; case .choices(let a): a.joined(separator: ", ") } }
}

enum ExamMode: String, Codable, CaseIterable, Sendable { case exam, training }
enum ExamAttemptState: String, Codable, Sendable {
    case inProgress = "in_progress", interrupted, submitted, gradingPending = "grading_pending", graded
    var isFinal: Bool { self == .submitted || self == .gradingPending || self == .graded }
}

struct ExamProgress: Codable, Equatable, Sendable {
    var sectionID: String?
    var taskID: String?
    var audioCursorMS: Int = 0
    var elapsedMS: [String: Int] = [:]
    enum CodingKeys: String, CodingKey { case sectionID = "section_id", taskID = "task_id", audioCursorMS = "audio_cursor_ms", elapsedMS = "elapsed_ms" }
}

struct ExamAttempt: Codable, Identifiable, Sendable {
    let id: String
    let examID: String
    let revision: String
    let mode: ExamMode
    var sectionIDs: [String]
    var state: ExamAttemptState
    var responses: [String: ExamAnswer]
    var progress: ExamProgress
    var version: Int
    var ownerID: String?
    var deviceID: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date
    var sectionStartedAt: [String: Date] = [:]
    var sectionDeadlines: [String: Date] = [:]
    var submittedSectionIDs: [String] = []
    var result: ExamAttemptResult? = nil
    var aiResults: [String: ExamAssessmentResult]? = nil
    // Local flags are never accepted as authority by the server.
    var serverCreated: Bool = false
    var submissionRequestedSectionIDs: [String] = []
    var sectionID: String { progress.sectionID ?? sectionIDs.first ?? "" }
    var deadlineAt: Date? { sectionDeadlines[sectionID] }
    var responseTexts: [String: String] { responses.mapValues(\.text) }
    var objectiveResult: ExamObjectiveResult? { result?.summary(for: sectionID, assessments: aiResults ?? [:]) }
    enum CodingKeys: String, CodingKey {
        case id, examID = "exam_id", revision, mode, sectionIDs = "section_ids", state, responses, progress, version
        case ownerID = "owner_id", deviceID = "device_id", createdAt = "created_at", updatedAt = "updated_at", startedAt = "started_at"
        case sectionStartedAt = "section_started_at", sectionDeadlines = "section_deadlines", submittedSectionIDs = "submitted_section_ids"
        case result, assessments, aiResults = "local_ai_results", serverCreated = "local_server_created", submissionRequestedSectionIDs = "local_submission_requested_section_ids"
    }
    init(id: String = UUID().uuidString.lowercased(), examID: String, revision: String, mode: ExamMode, sectionID: String, deviceID: String, now: Date = Date()) {
        self.id = id; self.examID = examID; self.revision = revision; self.mode = mode; sectionIDs = [sectionID]
        state = .inProgress; responses = [:]; progress = ExamProgress(sectionID: sectionID)
        version = 0; self.deviceID = deviceID; createdAt = now; updatedAt = now; startedAt = now
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); examID = try c.decode(String.self, forKey: .examID)
        revision = try c.decode(String.self, forKey: .revision); mode = try c.decode(ExamMode.self, forKey: .mode)
        sectionIDs = try c.decode([String].self, forKey: .sectionIDs); state = try c.decode(ExamAttemptState.self, forKey: .state)
        responses = try c.decode([String: ExamAnswer].self, forKey: .responses); progress = try c.decode(ExamProgress.self, forKey: .progress)
        version = try c.decode(Int.self, forKey: .version); ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        sectionStartedAt = try c.decodeIfPresent([String: Date].self, forKey: .sectionStartedAt) ?? [:]
        sectionDeadlines = try c.decodeIfPresent([String: Date].self, forKey: .sectionDeadlines) ?? [:]
        submittedSectionIDs = try c.decodeIfPresent([String].self, forKey: .submittedSectionIDs) ?? []
        result = try c.decodeIfPresent(ExamAttemptResult.self, forKey: .result)
        aiResults = try c.decodeIfPresent([String: ExamAssessmentResult].self, forKey: .aiResults)
        if let records = try c.decodeIfPresent([String: ExamJSONValue].self, forKey: .assessments) {
            for (taskID, record) in records {
                let value = record.object?["result"]?.object ?? record.object
                if let score = value?["score_units"]?.int, let rationale = value?["rationale"]?.string {
                    if aiResults == nil { aiResults = [:] }
                    aiResults?[taskID] = ExamAssessmentResult(scoreUnits: score, rationale: rationale)
                }
            }
        }
        serverCreated = try c.decodeIfPresent(Bool.self, forKey: .serverCreated) ?? true
        submissionRequestedSectionIDs = try c.decodeIfPresent([String].self, forKey: .submissionRequestedSectionIDs) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(examID, forKey: .examID); try c.encode(revision, forKey: .revision)
        try c.encode(mode, forKey: .mode); try c.encode(sectionIDs, forKey: .sectionIDs); try c.encode(state, forKey: .state)
        try c.encode(responses, forKey: .responses); try c.encode(progress, forKey: .progress); try c.encode(version, forKey: .version)
        try c.encodeIfPresent(ownerID, forKey: .ownerID); try c.encode(deviceID, forKey: .deviceID)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt); try c.encode(startedAt, forKey: .startedAt)
        try c.encode(sectionStartedAt, forKey: .sectionStartedAt); try c.encode(sectionDeadlines, forKey: .sectionDeadlines)
        try c.encode(submittedSectionIDs, forKey: .submittedSectionIDs); try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(aiResults, forKey: .aiResults); try c.encode(serverCreated, forKey: .serverCreated)
        try c.encode(submissionRequestedSectionIDs, forKey: .submissionRequestedSectionIDs)
    }
}

struct ExamObjectiveResult: Codable, Sendable {
    var objectiveScoreUnits: Int?
    var autoMaxScoreUnits: Int?
    var maxScoreUnits: Int?
    var pendingScoreUnits: Int?
    var totalScoreUnits: Int?
    var items: [String: ExamJSONValue]? = nil
    enum CodingKeys: String, CodingKey {
        case objectiveScoreUnits = "objective_score_units", autoMaxScoreUnits = "auto_max_score_units", maxScoreUnits = "max_score_units"
        case pendingScoreUnits = "pending_score_units", totalScoreUnits = "total_score_units", items
    }
}

struct ExamAttemptResult: Codable, Sendable {
    let examID: String
    let revision: String
    let sections: [ExamSectionResult]
    enum CodingKeys: String, CodingKey { case examID = "exam_id", revision, sections }
    func summary(for sectionID: String, assessments: [String: ExamAssessmentResult]) -> ExamObjectiveResult? {
        guard let s = sections.first(where: { $0.sectionID == sectionID }) else { return nil }
        let pendingItems = s.items.filter { $0.awardedScoreUnits == nil }
        let objectiveMax = s.items.filter { $0.awardedScoreUnits != nil }.reduce(0) { $0 + $1.maxScoreUnits }
        let taskResults = Dictionary(s.taskAssessments.map { ($0.taskID, $0.scoreUnits) }, uniquingKeysWith: { _, b in b })
            .merging(assessments.mapValues(\.scoreUnits)) { _, local in local }
        let aiTaskIDs = Set(pendingItems.filter { ["pending_ai", "assessed_at_task_level"].contains($0.status) }.map(\.taskID))
        let relevantAI = taskResults.filter { aiTaskIDs.contains($0.key) }
        let remaining = pendingItems.filter { $0.status == "pending_manual" || relevantAI[$0.taskID] == nil }
        let pendingMax = remaining.reduce(0) { $0 + $1.maxScoreUnits }
        let total = remaining.isEmpty ? s.objectiveScoreUnits + relevantAI.values.reduce(0, +) : nil
        return ExamObjectiveResult(objectiveScoreUnits: s.objectiveScoreUnits, autoMaxScoreUnits: objectiveMax,
            maxScoreUnits: s.maxScoreUnits, pendingScoreUnits: pendingMax, totalScoreUnits: total)
    }
}
struct ExamSectionResult: Codable, Sendable {
    let sectionID: String
    let status: String
    let scoreUnits: Int?
    let objectiveScoreUnits: Int
    let maxScoreUnits: Int
    let items: [ExamItemResult]
    let taskAssessments: [ExamTaskAssessment]
    enum CodingKeys: String, CodingKey {
        case sectionID = "section_id", status, scoreUnits = "score_units", objectiveScoreUnits = "objective_score_units"
        case maxScoreUnits = "max_score_units", items, taskAssessments = "task_assessments"
    }
}
struct ExamItemResult: Codable, Sendable {
    let itemID: String
    let taskID: String
    let status: String
    let awardedScoreUnits: Int?
    let maxScoreUnits: Int
    enum CodingKeys: String, CodingKey { case itemID = "item_id", taskID = "task_id", status, awardedScoreUnits = "awarded_score_units", maxScoreUnits = "max_score_units" }
}
struct ExamTaskAssessment: Codable, Sendable {
    let taskID: String
    let scoreUnits: Int
    let rationale: String
    var origin: String? = nil
    var provenance: ExamJSONValue? = nil
    enum CodingKeys: String, CodingKey { case taskID = "task_id", scoreUnits = "score_units", rationale, origin, provenance }
}
