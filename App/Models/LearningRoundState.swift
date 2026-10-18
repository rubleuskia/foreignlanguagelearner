import Foundation

enum LearningRoundSelection: String, CaseIterable, Identifiable, Sendable {
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

struct LearningRoundState: Equatable, Sendable {
    let selection: LearningRoundSelection
    let selectedIDs: [UUID]
    private(set) var pendingIDs: [UUID]
    private(set) var completedIDs: [UUID]
    private(set) var skippedIDs: [UUID]
    private(set) var wrongAttemptCount: Int
    private(set) var currentPresentationID: UUID

    init(selection: LearningRoundSelection, selectedIDs: [UUID],
         presentationID: UUID = UUID()) {
        var seen = Set<UUID>()
        let unique = selectedIDs.filter { seen.insert($0).inserted }
        self.selection = selection
        self.selectedIDs = unique
        self.pendingIDs = unique
        self.completedIDs = []
        self.skippedIDs = []
        self.wrongAttemptCount = 0
        self.currentPresentationID = presentationID
    }

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
              entry.isLearningEligible else { return false }
        let previousLevel = entry.learningLevel
        entry.learningLevel = LearningLevel.adjusted(previousLevel, correct: right)
        do {
            try save()
            _ = round.recordAnswer(entryID: expectedEntryID,
                                   presentationID: presentationID, right: right)
            return true
        } catch {
            entry.learningLevel = previousLevel
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
    case startLearning, moveToNextLevel, markAsKnown
}

struct LearningPreviewState: Equatable, Sendable {
    let selection: LearningRoundSelection
    let selectedIDs: [UUID]
    private(set) var pendingIDs: [UUID]
    private(set) var learningIDs: [UUID] = []
    private(set) var currentPresentationID: UUID

    init(selection: LearningRoundSelection, selectedIDs: [UUID], presentationID: UUID = UUID()) {
        var seen = Set<UUID>()
        let unique = selectedIDs.filter { seen.insert($0).inserted }
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
              entry.isLearningEligible else { return false }
        let oldLevel = entry.learningLevel
        switch action {
        case .startLearning: break
        case .moveToNextLevel: entry.learningLevel = LearningLevel.adjusted(oldLevel, correct: true)
        case .markAsKnown: entry.learningLevel = 4
        }
        do {
            if entry.learningLevel != oldLevel { try save() }
            return preview.advance(entryID: entry.id, presentationID: presentationID,
                                   learn: action == .startLearning)
        } catch {
            entry.learningLevel = oldLevel
            throw error
        }
    }
}
