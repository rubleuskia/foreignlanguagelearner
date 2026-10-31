import CryptoKit
import Foundation
import SwiftData

struct LibraryBackupDocument: Codable {
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let dictionary: Data
    let books: [Book]
    let settings: Settings
    let round: LearningRoundState?
    var rounds: [String: LearningRoundState]? = nil
    var activity: [ActivityRecord]? = nil
    let wordExplanations: [WordExplanationCache.Record]

    struct Book: Codable {
        let id: UUID
        let fingerprint: String
        let title: String
        let createdAt: Date
        let sourceLanguage: String
        let lastPosition: Double
        let lastTrackID: String?
        let isCompleted: Bool
        let migrationVersion: Int
        let parts: [LearningPart]
        let tracks: [Track]
        var readingCharacterOffset: Int? = nil
        var sourceLanguageLockedByHistory: Bool? = nil
        var lastPlayedAt: Date? = nil
        var bundledCoverName: String? = nil
    }
    struct Track: Codable {
        let id: String
        let lastPosition: Double
        let isCompleted: Bool
    }
    struct Settings: Codable {
        var interfaceLanguage: String? = nil
        var activeSourceLanguage: String? = nil
        var newBookSourceLanguage: String? = nil
        var reasoningEffort: String? = nil
        let model: String
        let cloudEnabled: Bool
        let translationPrompt: String
        let wordPrompt: String
        let cooldowns: [Double]

        init(defaults: UserDefaults) {
            interfaceLanguage = AppLanguage.resolved(defaults.string(forKey: AppLanguage.key))
            activeSourceLanguage = defaults.string(forKey: SourceLanguage.activeKey)
            newBookSourceLanguage = defaults.string(forKey: SourceLanguage.importKey)
            model = ContextAnalysisSettings.selectedModel(in: defaults).rawValue
            reasoningEffort = ContextAnalysisSettings.reasoningEffort(for: ContextAnalysisSettings.selectedModel(in: defaults), in: defaults)
            cloudEnabled = ContextAnalysisSettings.isCloudAnalysisEnabled(in: defaults)
            translationPrompt = ContextAnalysisSettings.prompt(in: defaults)
            wordPrompt = ContextAnalysisSettings.wordExplanationPrompt(in: defaults)
            cooldowns = (1...3).map { LearningCooldown.hours(level: $0, defaults: defaults) }
        }

        func apply(to defaults: UserDefaults) throws {
            if let interfaceLanguage, AppLanguage.supported.contains(interfaceLanguage) {
                defaults.set(interfaceLanguage, forKey: AppLanguage.key)
            }
            if let activeSourceLanguage { defaults.set(SourceLanguage.canonical(activeSourceLanguage), forKey: SourceLanguage.activeKey) }
            if let newBookSourceLanguage, SourceLanguage.isSupported(newBookSourceLanguage) { defaults.set(SourceLanguage.canonical(newBookSourceLanguage), forKey: SourceLanguage.importKey) }
            try ContextAnalysisSettings.setPrompt(translationPrompt, in: defaults)
            try ContextAnalysisSettings.setWordExplanationPrompt(wordPrompt, in: defaults)
            defaults.set(model, forKey: ContextAnalysisSettings.modelKey)
            defaults.set(reasoningEffort, forKey: ContextAnalysisSettings.reasoningEffortKey)
            defaults.set(cloudEnabled, forKey: ContextAnalysisSettings.cloudAnalysisEnabledKey)
            for (index, hours) in cooldowns.enumerated() {
                defaults.set(hours, forKey: "learning.cooldown.level.\(index + 1)")
            }
        }
    }
}

struct LibraryBackupPreview: Identifiable {
    let id = UUID()
    let document: LibraryBackupDocument
    let dictionary: DictionaryTransferDocument
    let matches: [UUID: UUID]
    let issues: [String]
    var canRestore: Bool { issues.isEmpty }
}

enum LibraryBackupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

@MainActor enum LibraryBackupService {
    static let format = "foreign-language-learner.library"
    static let maximumBytes = 128 * 1_024 * 1_024

    /// Titles and UUIDs can change on reimport. Match normalized source text and the ordered
    /// audio layout; no source text, subtitle, audio or word-timing file is exported here.
    static func fingerprint(_ item: LearningItem) throws -> String {
        let text: String
        if !item.hasText {
            let root = MediaImportService.directory(for: item.id)
            let files = item.tracks.isEmpty ? [item.mediaFilename] : item.tracks.map(\.mediaFilename)
            text = "audio-only:" + (try files.map { name in
                try BookManifestValidator.validatePath(name)
                return try WordAudioTimingFile.audioHash(root.appending(path: name))
            }).joined(separator: ":")
        } else if item.tracks.isEmpty {
            text = item.segments.map(\.text).joined(separator: " ")
        } else {
            let root = MediaImportService.directory(for: item.id)
            let url = root.appending(path: item.transcriptFilename).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw LibraryBackupError.invalid("Invalid transcript path for \(item.title).")
            }
            text = try String(contentsOf: url, encoding: .utf8)
        }
        struct Identity: Encodable {
            let text: String
            let durations: [Double]
            let trackIDs: [String]
        }
        let identity = Identity(text: try BookTextNormalization.normalize(text),
            durations: (item.tracks.isEmpty ? [item.duration] : item.tracks.map(\.duration))
                .map { ($0 * 1_000).rounded() / 1_000 }, trackIDs: item.tracks.map(\.id))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    static func export(context: ModelContext, defaults: UserDefaults = .standard,
                       cacheURL: URL? = WordExplanationCache.defaultFile) throws -> DictionaryJSONFile {
        try context.save()
        let items = try context.fetch(FetchDescriptor<LearningItem>())
        let entries = try context.fetch(FetchDescriptor<DictionaryEntry>())
        let dictionary = try DictionaryTransferService.export(entries: entries, includeContext: true,
            readingWords: ReadingKnowledge.words(context: context))
        let books = try items.map { item in
            LibraryBackupDocument.Book(id: item.id, fingerprint: try fingerprint(item), title: item.title,
                createdAt: item.createdAt, sourceLanguage: item.sourceLanguageCode,
                lastPosition: item.lastPosition, lastTrackID: item.lastTrackID,
                isCompleted: item.isBookCompleted, migrationVersion: item.readingVocabularyMigrationVersion,
                parts: item.parts, tracks: item.tracks.map {
                    .init(id: $0.id, lastPosition: $0.lastPosition, isCompleted: $0.isCompleted)
                }, readingCharacterOffset: item.readingCharacterOffset,
                sourceLanguageLockedByHistory: item.sourceLanguageLockedByHistory,
                lastPlayedAt: item.lastPlayedAt, bundledCoverName: item.bundledCoverName)
        }
        let savedRound = LearningRoundCheckpoint.load(defaults: defaults)
        let round = savedRound.flatMap { LearningRoundCheckpoint.validated($0, entries: entries) }
        var document = LibraryBackupDocument(format: format, schemaVersion: 1, exportedAt: .now,
            dictionary: dictionary.data, books: books, settings: .init(defaults: defaults), round: round,
            wordExplanations: try WordExplanationCache.backupRecords(at: cacheURL))
        document.rounds = LearningRoundCheckpoint.all(defaults: defaults).compactMapValues {
            LearningRoundCheckpoint.validated($0, entries: entries)
        }
        if let legacy = savedRound.flatMap({ LearningRoundCheckpoint.validated($0, entries: entries) }), let code = legacy.sourceLanguage {
            document.rounds?[code] = legacy
        }
        document.activity = try context.fetch(FetchDescriptor<UserActivityEvent>()).map(\.record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        _ = try decode(data)
        return .init(data: data)
    }

    static func decode(_ data: Data) throws -> LibraryBackupDocument {
        guard data.count <= maximumBytes else { throw LibraryBackupError.invalid("Library backup exceeds 128 MiB.") }
        let document = try JSONDecoder().decode(LibraryBackupDocument.self, from: data)
        guard document.format == format, document.schemaVersion == 1 else {
            throw LibraryBackupError.invalid("Unsupported library backup format or version.")
        }
        _ = try DictionaryTransferService.decode(document.dictionary)
        guard document.books.count <= 10_000,
              Set(document.books.map(\.id)).count == document.books.count,
              OpenAITranslationModel(rawValue: document.settings.model) != nil,
              (document.settings.reasoningEffort == nil || OpenAITranslationModel(rawValue: document.settings.model)?.supportedReasoningEfforts.contains(document.settings.reasoningEffort!) == true),
              document.settings.cooldowns.count == 3,
              document.settings.cooldowns.allSatisfy({ $0.isFinite && $0 >= 0 }),
              validPrompt(document.settings.translationPrompt), validPrompt(document.settings.wordPrompt),
              document.wordExplanations.count <= 200,
              Set(document.wordExplanations.map(\.key)).count == document.wordExplanations.count else {
            throw LibraryBackupError.invalid("Invalid library backup settings or identities.")
        }
        if let language = document.settings.activeSourceLanguage,
           (try? VocabularyTokenizer.language(language)) == nil {
            throw LibraryBackupError.invalid("Invalid active source language preference.")
        }
        if let language = document.settings.interfaceLanguage, !AppLanguage.supported.contains(language) {
            throw LibraryBackupError.invalid("Invalid interface language preference.")
        }
        if let language = document.settings.newBookSourceLanguage, !SourceLanguage.isSupported(language) {
            throw LibraryBackupError.invalid("Invalid new-book source language preference.")
        }
        if let activity = document.activity {
            guard activity.count <= 500_000, Set(activity.map(\.id)).count == activity.count,
                  activity.allSatisfy({ $0.isValid && SourceLanguage.canonical($0.language) == $0.language }) else {
                throw LibraryBackupError.invalid("Invalid activity history.")
            }
        }
        for record in document.wordExplanations {
            guard validHash(record.key) else { throw LibraryBackupError.invalid("Invalid word explanation key.") }
            _ = try record.value.validated()
        }
        // Checkpoints are disposable; invalid or mixed-language legacy rounds are dropped on restore.
        // Dictionary levels and the rest of a compatible backup remain recoverable.
        if let rounds = document.rounds, rounds.count > 256 {
            throw LibraryBackupError.invalid("Too many language training checkpoints.")
        }
        for book in document.books {
            guard validHash(book.fingerprint), !book.title.isEmpty, !book.sourceLanguage.isEmpty,
                  book.lastPosition.isFinite, book.lastPosition >= 0,
                  book.lastPlayedAt.map { $0.timeIntervalSince1970.isFinite } ?? true,
                  (book.readingCharacterOffset ?? 0) >= 0,
                  book.bundledCoverName.map { BookCoverService.bundled.contains($0) } ?? true,
                  (0...1).contains(book.migrationVersion),
                  Set(book.tracks.map(\.id)).count == book.tracks.count,
                  book.lastTrackID == nil || book.tracks.contains(where: { $0.id == book.lastTrackID }),
                  book.tracks.allSatisfy({ !$0.id.isEmpty && $0.lastPosition.isFinite && $0.lastPosition >= 0 }),
                  Set(book.parts.map(\.id)).count == book.parts.count,
                  book.parts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                      && $0.lastPosition.isFinite && $0.lastPosition >= $0.start && $0.lastPosition <= $0.end }) else {
                throw LibraryBackupError.invalid("Invalid book progress: \(book.title).")
            }
        }
        return document
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validPrompt(_ prompt: String) -> Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prompt.utf16.count <= ContextAnalysisSettings.maximumPromptUTF16
    }

    static func preview(_ document: LibraryBackupDocument, context: ModelContext) throws -> LibraryBackupPreview {
        let items = try context.fetch(FetchDescriptor<LearningItem>())
        var indexed: [String: [LearningItem]] = [:]
        for item in items {
            if let key = try? fingerprint(item) { indexed[key, default: []].append(item) }
        }
        var matches: [UUID: UUID] = [:]
        var issues: [String] = []
        var used = Set<UUID>()
        for book in document.books {
            let candidates = (indexed[book.fingerprint] ?? []).filter { SourceLanguage.canonical($0.sourceLanguageCode) == SourceLanguage.canonical(book.sourceLanguage) }
            let exact = candidates.first { $0.id == book.id }
            guard let match = exact ?? (candidates.count == 1 ? candidates.first : nil),
                  used.insert(match.id).inserted else {
                issues.append("\(book.title): \(candidates.isEmpty ? "import this book first" : "multiple copies; keep one matching copy")")
                continue
            }
            guard book.lastPosition <= match.duration,
                  book.tracks.map(\.id) == match.tracks.map(\.id),
                  book.tracks.allSatisfy({ saved in
                      match.tracks.contains { $0.id == saved.id && saved.lastPosition <= $0.duration }
                  }), book.parts.allSatisfy({ $0.end <= match.duration }) else {
                issues.append("\(book.title): saved positions do not match this edition")
                continue
            }
            matches[book.id] = match.id
        }
        let dictionary = try DictionaryTransferService.decode(document.dictionary)
        let local = Dictionary(grouping: try context.fetch(FetchDescriptor<DictionaryEntry>()), by: \.id)
        for entry in dictionary.entries {
            if let candidates = local[entry.id], candidates.count != 1 || candidates.contains(where: {
                $0.text != entry.text || $0.sourceLanguageCode != entry.sourceLanguage || $0.targetLanguageCode != entry.targetLanguage
            }) { issues.append("Conflicting dictionary identity: \(entry.text)") }
        }
        return .init(document: document, dictionary: dictionary, matches: matches, issues: issues)
    }

    static func restore(_ preview: LibraryBackupPreview, context: ModelContext,
                        defaults: UserDefaults = .standard, cacheURL: URL? = WordExplanationCache.defaultFile,
                        save: (ModelContext) throws -> Void = { try $0.save() }) throws -> [DictionaryEntry] {
        // Revalidate portable data and current identities at Apply time.
        let document = try decode(JSONEncoder().encode(preview.document))
        let fresh = try self.preview(document, context: context)
        guard fresh.canRestore, fresh.matches == preview.matches else {
            throw LibraryBackupError.invalid("Library changed. Import the matching books and review the backup again.")
        }
        try context.save()
        let existingActivity = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<UserActivityEvent>()).map { ($0.id, $0.record) })
        for incoming in document.activity ?? [] {
            if var existing = existingActivity[incoming.id] {
                var normalized = incoming
                existing.reverted = false; normalized.reverted = false
                if existing.kind == "time" { existing.seconds = 0; normalized.seconds = 0 }
                guard existing == normalized else { throw LibraryBackupError.invalid("Conflicting activity identity.") }
            }
        }
        let items = try context.fetch(FetchDescriptor<LearningItem>())
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let rollback = items.map { item in
            (item, item.title, item.createdAt, item.sourceLanguageCode, item.lastPosition, item.lastTrackID,
             item.isBookCompleted, item.readingVocabularyMigrationVersion, item.parts, item.tracks,
             item.readingCharacterOffset, item.sourceLanguageLockedByHistory, item.lastPlayedAt, item.bundledCoverName)
        }
        let oldCache = try cacheURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil }
        let incomingIDs = Set(fresh.dictionary.entries.map(\.id))
        let dictionaryPreview = DictionaryTransferService.preview(document: fresh.dictionary, mode: .restore,
            existing: try context.fetch(FetchDescriptor<DictionaryEntry>()), existingVocabulary: try ReadingKnowledge.words(context: context))
        let incomingLanguages = Dictionary(uniqueKeysWithValues: fresh.dictionary.entries.map { ($0.id, $0.sourceLanguage) })
        var rounds = LearningRoundCheckpoint.all(defaults: defaults)
        let incomingRounds = (document.rounds.map { Array($0.values) } ?? []) + (document.round.map { [$0] } ?? [])
        var discardedCheckpoint = false
        for incoming in incomingRounds {
            if let valid = LearningRoundCheckpoint.validated(incoming, languagesByID: incomingLanguages), let code = valid.sourceLanguage {
                rounds[code] = valid
            } else { discardedCheckpoint = true }
        }
        do {
            try WordExplanationCache.restoreRecords(document.wordExplanations, at: cacheURL)
            let pending = try DictionaryTransferService.apply(dictionaryPreview, context: context, commitSave: { context in
                for book in document.books {
                    guard let id = fresh.matches[book.id], let item = byID[id] else { continue }
                    item.title = book.title; item.createdAt = book.createdAt
                    item.sourceLanguageCode = book.sourceLanguage; item.lastPosition = book.lastPosition
                    item.lastTrackID = book.lastTrackID; item.isBookCompleted = book.isCompleted
                    item.readingVocabularyMigrationVersion = book.migrationVersion
                    if let offset = book.readingCharacterOffset { item.readingCharacterOffset = offset }
                    if let locked = book.sourceLanguageLockedByHistory { item.sourceLanguageLockedByHistory = locked }
                    if let lastPlayedAt = book.lastPlayedAt { item.lastPlayedAt = lastPlayedAt }
                    if let cover = book.bundledCoverName { item.bundledCoverName = cover }
                    item.parts = book.parts
                    item.tracks = item.tracks.map { track in
                        var value = track
                        if let saved = book.tracks.first(where: { $0.id == track.id }) {
                            value.lastPosition = saved.lastPosition; value.isCompleted = saved.isCompleted
                        }
                        return value
                    }
                }
                for entry in try context.fetch(FetchDescriptor<DictionaryEntry>()) where incomingIDs.contains(entry.id) {
                    if let id = fresh.matches[entry.sourceItemID] { entry.sourceItemID = id }
                    if let old = entry.localSourceItemID, let id = fresh.matches[old] { entry.localSourceItemID = id }
                }
                // Merge growing time records and undo tombstones without duplicating history.
                let localEvents = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<UserActivityEvent>()).map { ($0.id, $0) })
                for record in document.activity ?? [] {
                    if let local = localEvents[record.id] {
                        local.reverted = local.reverted || record.reverted
                        if record.kind == "time" { local.seconds = max(local.seconds, record.seconds) }
                    } else {
                        context.insert(UserActivityEvent(record))
                    }
                }
                try save(context)
            })
            try document.settings.apply(to: defaults)
            LearningRoundCheckpoint.replace(rounds, defaults: defaults)
            if discardedCheckpoint {
                defaults.set("An imported unfinished round could not be resumed because its phrases are missing or use different source languages. Restored learning levels are preserved.", forKey: LearningRoundCheckpoint.recoveryKey)
            }
            return pending
        } catch {
            context.rollback()
            for (item, title, created, language, position, track, complete, migration, parts, tracks, offset, locked, lastPlayedAt, cover) in rollback {
                item.title = title; item.createdAt = created; item.sourceLanguageCode = language
                item.lastPosition = position; item.lastTrackID = track; item.isBookCompleted = complete
                item.readingVocabularyMigrationVersion = migration; item.parts = parts; item.tracks = tracks
                item.readingCharacterOffset = offset; item.sourceLanguageLockedByHistory = locked
                item.lastPlayedAt = lastPlayedAt; item.bundledCoverName = cover
            }
            if let cacheURL {
                if let oldCache { try? oldCache.write(to: cacheURL, options: .atomic) }
                else { try? FileManager.default.removeItem(at: cacheURL) }
            }
            throw error
        }
    }
}
