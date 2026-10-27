import Foundation

enum LearningRoundSelection: String, CaseIterable, Identifiable, Codable, Sendable {
    case five
    case ten
    case twenty
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .five: "5"
        case .ten: "10"
        case .twenty: "20"
        case .all: "All available"
        }
    }

    func count(available: Int) -> Int {
        switch self {
        case .five: min(5, available)
        case .ten: min(10, available)
        case .twenty: min(20, available)
        case .all: available
        }
    }
}

struct LearningRoundState: Codable, Equatable, Sendable {
    var sourceLanguage: String? = nil
    var initialLevels: [UUID: Int]? = nil
    private(set) var wrongAttemptsByEntry: [UUID: Int]? = nil
    let selection: LearningRoundSelection
    let selectedIDs: [UUID]
    private(set) var pendingIDs: [UUID]
    private(set) var completedIDs: [UUID]
    private(set) var skippedIDs: [UUID]
    private(set) var wrongAttemptCount: Int
    private(set) var currentPresentationID: UUID

    init(selection: LearningRoundSelection, selectedIDs: [UUID],
         presentationID: UUID = UUID(), sourceLanguage: String? = nil) {
        var seen = Set<UUID>()
        let unique = selectedIDs.filter { seen.insert($0).inserted }
        self.sourceLanguage = sourceLanguage.map(SourceLanguage.canonical)
        self.selection = selection
        self.selectedIDs = unique
        self.pendingIDs = unique
        self.completedIDs = []
        self.skippedIDs = []
        self.wrongAttemptCount = 0
        self.currentPresentationID = presentationID
    }

    var hasAnswers: Bool { rightAttemptCount > 0 || wrongAttemptCount > 0 }
    var canResume: Bool { hasAnswers && !isComplete && hasValidPartition }

    var totalSelectedCount: Int { selectedIDs.count }
    var rightAttemptCount: Int { completedIDs.count }
    var isComplete: Bool { !selectedIDs.isEmpty && pendingIDs.isEmpty }
    var currentID: UUID? { pendingIDs.first }

    @discardableResult
    mutating func recordAnswer(entryID: UUID, presentationID: UUID, right: Bool,
                               nextPresentationID: UUID = UUID()) -> Bool {
        guard currentID == entryID, currentPresentationID == presentationID else { return false }
        pendingIDs.removeFirst()
        if right {
            completedIDs.append(entryID)
        } else {
            wrongAttemptCount += 1
            var attempts = wrongAttemptsByEntry ?? [:]
            attempts[entryID, default: 0] += 1
            wrongAttemptsByEntry = attempts
            pendingIDs.append(entryID)
        }
        currentPresentationID = nextPresentationID
        return true
    }

    @discardableResult
    mutating func skip(entryID: UUID, presentationID: UUID,
                       nextPresentationID: UUID = UUID()) -> Bool {
        guard currentID == entryID, currentPresentationID == presentationID else { return false }
        pendingIDs.removeFirst()
        skippedIDs.append(entryID)
        currentPresentationID = nextPresentationID
        return true
    }

    mutating func renewPresentation() {
        currentPresentationID = UUID()
    }

    var hasValidPartition: Bool {
        let selected = Set(selectedIDs)
        let pending = Set(pendingIDs)
        let completed = Set(completedIDs)
        let skipped = Set(skippedIDs)
        return selected.count == selectedIDs.count
            && pending.count == pendingIDs.count
            && completed.count == completedIDs.count
            && skipped.count == skippedIDs.count
            && pending.isDisjoint(with: completed)
            && pending.isDisjoint(with: skipped)
            && completed.isDisjoint(with: skipped)
            && pending.union(completed).union(skipped) == selected
    }
}

enum LearningAnswerTransaction {
    @discardableResult
    @MainActor
    static func apply(entry: DictionaryEntry, round: inout LearningRoundState,
                      expectedEntryID: UUID, presentationID: UUID, right: Bool,
                      save: () throws -> Void) throws -> Bool {
        guard round.currentID == expectedEntryID,
              round.currentPresentationID == presentationID,
              entry.id == expectedEntryID,
              entry.isLearningEligible,
              round.sourceLanguage == nil || SourceLanguage.canonical(entry.sourceLanguageCode) == round.sourceLanguage else { return false }
        let previousLevel = entry.learningLevel
        let previousDate = entry.levelChangedAt
        let promotionBlocked = right && (round.wrongAttemptsByEntry?[entry.id] ?? 0) >= 4
        entry.learningLevel = promotionBlocked ? previousLevel : LearningLevel.adjusted(previousLevel, correct: right)
        if entry.learningLevel != previousLevel { entry.levelChangedAt = .now }
        do {
            try save()
            _ = round.recordAnswer(entryID: expectedEntryID,
                                   presentationID: presentationID, right: right)
            return true
        } catch {
            entry.learningLevel = previousLevel
            entry.levelChangedAt = previousDate
            throw error
        }
    }
}

enum LearningCompletion {
    @MainActor
    static func learntEntries(from entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter {
            $0.learningLevel == 4
                && $0.targetLanguageCode == "ru"
                && $0.translationStatus == .ready
                && $0.hasTranslation
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum LearningPreviewAction: Equatable, Sendable {
    case startLearning, moveToNextLevel, markAsKnown, skip
}

struct LearningPreviewState: Equatable, Sendable {
    var sourceLanguage: String? = nil
    let selection: LearningRoundSelection
    let selectedIDs: [UUID]
    private(set) var pendingIDs: [UUID]
    private(set) var learningIDs: [UUID] = []
    private(set) var currentPresentationID: UUID

    init(selection: LearningRoundSelection, selectedIDs: [UUID], presentationID: UUID = UUID(), sourceLanguage: String? = nil) {
        var seen = Set<UUID>()
        let unique = selectedIDs.filter { seen.insert($0).inserted }
        self.sourceLanguage = sourceLanguage.map(SourceLanguage.canonical)
        self.selection = selection
        self.selectedIDs = unique
        self.pendingIDs = unique
        self.currentPresentationID = presentationID
    }

    var currentID: UUID? { pendingIDs.first }
    var isComplete: Bool { pendingIDs.isEmpty }
    var reviewedCount: Int { selectedIDs.count - pendingIDs.count }

    @discardableResult
    mutating func advance(entryID: UUID, presentationID: UUID, learn: Bool) -> Bool {
        guard currentID == entryID, currentPresentationID == presentationID else { return false }
        pendingIDs.removeFirst()
        if learn { learningIDs.append(entryID) }
        currentPresentationID = UUID()
        return true
    }
}

enum LearningPreviewTransaction {
    @discardableResult
    @MainActor static func apply(entry: DictionaryEntry, preview: inout LearningPreviewState,
                                 presentationID: UUID, action: LearningPreviewAction,
                                 save: () throws -> Void) throws -> Bool {
        guard preview.currentID == entry.id, preview.currentPresentationID == presentationID,
              entry.isLearningEligible,
              preview.sourceLanguage == nil || SourceLanguage.canonical(entry.sourceLanguageCode) == preview.sourceLanguage else { return false }
        let oldLevel = entry.learningLevel
        let oldDate = entry.levelChangedAt
        switch action {
        case .startLearning, .skip: break
        case .moveToNextLevel: entry.learningLevel = LearningLevel.adjusted(oldLevel, correct: true)
        case .markAsKnown: entry.learningLevel = 4
        }
        do {
            if entry.learningLevel != oldLevel {
                entry.levelChangedAt = .now
                try save()
            }
            return preview.advance(entryID: entry.id, presentationID: presentationID,
                                   learn: action == .startLearning)
        } catch {
            entry.learningLevel = oldLevel
            entry.levelChangedAt = oldDate
            throw error
        }
    }
}

/// Fills a round from lower learning levels first, then uses higher levels as needed.
enum LearningRoundPool {
    @MainActor
    static func entries(from entries: [DictionaryEntry], limit: Int = .max,
                        ignoreCooldown: Bool = false, now: Date = .now,
                        defaults: UserDefaults = .standard) -> [DictionaryEntry] {
        let eligible = entries.filter { $0.isLearningEligible && (ignoreCooldown || LearningCooldown.isReady($0, now: now, defaults: defaults)) }
        var seen = Set<UUID>()
        return (1...3).flatMap { level in
            eligible.filter { $0.learningLevel == level }.shuffled()
        }.filter { seen.insert($0.id).inserted }.prefix(max(0, limit)).map { $0 }
    }
}

struct LearningAnswerUndo {
    let id = UUID()
    let entryID: UUID
    let previousLevel: Int
    let savedLevel: Int
    let previousRound: LearningRoundState
    let answeredRound: LearningRoundState
    let expiresAt: Date
    var previousLevelChangedAt: Date? = nil
    var savedLevelChangedAt: Date? = nil

    @MainActor
    func restore(entry: DictionaryEntry, round: inout LearningRoundState,
                 now: Date = .now, save: () throws -> Void) throws -> Bool {
        guard now < expiresAt, entry.id == entryID,
              entry.learningLevel == savedLevel,
              savedLevelChangedAt == nil || entry.levelChangedAt == savedLevelChangedAt,
              round.sourceLanguage == nil || SourceLanguage.canonical(entry.sourceLanguageCode) == round.sourceLanguage,
              round == answeredRound else { return false }
        let savedDate = entry.levelChangedAt
        entry.learningLevel = previousLevel
        entry.levelChangedAt = previousLevelChangedAt
        do {
            try save()
            round = previousRound
            round.renewPresentation()
            return true
        } catch {
            entry.learningLevel = savedLevel
            entry.levelChangedAt = savedDate
            throw error
        }
    }
}

/// Local checkpoint; word levels are saved separately on every accepted answer.
enum LearningRoundCheckpoint {
    static let key = "learning.unfinished-round.v1"
    static let recoveryKey = "learning.unfinished-round.recovery"

    static func all(defaults: UserDefaults = .standard) -> [String: LearningRoundState] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: LearningRoundState].self, from: data)) ?? [:]
    }

    static func load(defaults: UserDefaults = .standard) -> LearningRoundState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let legacy = try? JSONDecoder().decode(LearningRoundState.self, from: data), legacy.canResume { return legacy }
        return all(defaults: defaults)[defaults.string(forKey: SourceLanguage.activeKey) ?? "pl"]
    }

    @MainActor static func validated(_ round: LearningRoundState, entries: [DictionaryEntry]) -> LearningRoundState? {
        validated(round, languagesByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.sourceLanguageCode) }))
    }

    static func validated(_ round: LearningRoundState, languagesByID: [UUID: String]) -> LearningRoundState? {
        guard round.canResume else { return nil }
        let referenced = round.selectedIDs.compactMap { languagesByID[$0] }
        let languages = Set(referenced.map(SourceLanguage.canonical))
        guard referenced.count == round.selectedIDs.count, languages.count == 1,
              let language = languages.first,
              round.sourceLanguage == nil || round.sourceLanguage == language else { return nil }
        var result = round
        result.sourceLanguage = language
        return result
    }

    /// Pure view query; migration/repair is deferred until session setup.
    @MainActor static func peek(language: String, entries: [DictionaryEntry], defaults: UserDefaults = .standard) -> LearningRoundState? {
        let code = SourceLanguage.canonical(language)
        let candidate: LearningRoundState?
        if let data = defaults.data(forKey: key), let legacy = try? JSONDecoder().decode(LearningRoundState.self, from: data) {
            candidate = legacy
        } else { candidate = all(defaults: defaults)[code] }
        guard let candidate, let valid = validated(candidate, entries: entries), valid.sourceLanguage == code else { return nil }
        return valid
    }

    @MainActor static func load(language: String, entries: [DictionaryEntry], defaults: UserDefaults = .standard) -> LearningRoundState? {
        var rounds = all(defaults: defaults)
        if let data = defaults.data(forKey: key),
           let legacy = try? JSONDecoder().decode(LearningRoundState.self, from: data) {
            if let valid = validated(legacy, entries: entries), let code = valid.sourceLanguage { rounds[code] = valid }
            else { defaults.set("An older unfinished round could not be resumed because its phrases are missing or use different source languages. Your saved learning levels are unchanged.", forKey: recoveryKey) }
            replace(rounds, defaults: defaults)
        }
        if let data = defaults.data(forKey: key), !data.isEmpty,
           (try? JSONDecoder().decode([String: LearningRoundState].self, from: data)) == nil,
           (try? JSONDecoder().decode(LearningRoundState.self, from: data)) == nil {
            defaults.set("The unfinished round was unreadable. Your saved learning levels are unchanged.", forKey: recoveryKey)
            replace(rounds, defaults: defaults)
        }
        let code = SourceLanguage.canonical(language)
        guard let round = rounds[code] else { return nil }
        guard let valid = validated(round, entries: entries), valid.sourceLanguage == code else {
            defaults.set("The unfinished round could not be resumed because its phrases changed. Your saved learning levels are unchanged.", forKey: recoveryKey)
            rounds.removeValue(forKey: code)
            replace(rounds, defaults: defaults)
            return nil
        }
        return valid
    }

    static func replace(_ rounds: [String: LearningRoundState], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(rounds) { defaults.set(data, forKey: key) }
    }

    static func save(_ round: LearningRoundState?, language: String? = nil, defaults: UserDefaults = .standard) {
        var rounds = all(defaults: defaults)
        let code = SourceLanguage.canonical(language ?? round?.sourceLanguage ?? defaults.string(forKey: SourceLanguage.activeKey) ?? "pl")
        if let round, round.canResume { rounds[code] = round }
        else { rounds.removeValue(forKey: code) }
        replace(rounds, defaults: defaults)
    }

}

/// Cooldown applies when selecting a new round, never to retries inside an active round.
enum LearningCooldown {
    static func hours(level: Int, defaults: UserDefaults = .standard) -> Double {
        let fallback: Double = level == 1 ? 24 : level == 2 ? 72 : 96
        guard let value = defaults.object(forKey: "learning.cooldown.level.\(level)") as? Double,
              value.isFinite, value >= 0 else { return fallback }
        return value
    }

    @MainActor static func remainingTime(_ entry: DictionaryEntry, now: Date = .now,
                                         defaults: UserDefaults = .standard) -> TimeInterval? {
        guard let changed = entry.levelChangedAt else { return nil }
        return max(0, changed.addingTimeInterval(hours(level: entry.learningLevel, defaults: defaults) * 3600)
            .timeIntervalSince(now))
    }

    @MainActor static func isReady(_ entry: DictionaryEntry, now: Date = .now,
                                   defaults: UserDefaults = .standard) -> Bool {
        remainingTime(entry, now: now, defaults: defaults) == 0
    }

    static func remainingDescription(seconds: TimeInterval) -> String {
        // Round up so a phrase never displays zero minutes before it is ready.
        let minutes = ceil(max(0, seconds) / 60)
        let days = floor(minutes / 1440)
        let hours = floor(minutes.truncatingRemainder(dividingBy: 1440) / 60)
        let rest = minutes.truncatingRemainder(dividingBy: 60)
        return AppLanguage.format("%dd %dh %dm", Int(days), Int(hours), Int(rest))
    }

    @MainActor static func backfill(_ entries: [DictionaryEntry], now: Date = .now,
                                    save: () throws -> Void) throws {
        let missing = entries.filter { $0.levelChangedAt == nil }
        guard !missing.isEmpty else { return }
        missing.forEach { $0.levelChangedAt = now }
        do { try save() }
        catch { missing.forEach { $0.levelChangedAt = nil }; throw error }
    }
}

// Shared by dictionary counts, filtering and the quick-start pool.
extension DictionaryEntry {
    @MainActor var isReadyForReview: Bool { isLearningEligible && LearningCooldown.isReady(self) }
}
