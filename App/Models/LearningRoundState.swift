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
