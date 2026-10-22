import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryTransferDocument: Codable {
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let entries: [Entry]
    let diagnostics: Diagnostics?
    var readingVocabulary: ReadingVocabulary? = nil

    struct ReadingVocabulary: Codable {
        let tokenizerVersion: Int
        let words: [Word]
        struct Word: Codable {
            let languageCode: String
            let normalizedForm: String
            let firstLearnedAt: Date
        }
    }

    init(format: String, schemaVersion: Int, exportedAt: Date, entries: [Entry], diagnostics: Diagnostics? = nil) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.entries = entries
        self.diagnostics = diagnostics
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        let text: String
        let sourceLanguage: String
        let targetLanguage: String
        let translation: Translation
        let learningLevel: Int
        let createdAt: Date
        let source: Source
        var details: Details? = nil
        var levelChangedAt: Date? = nil
    }
    struct Details: Codable {
        var contextSelectedTranslationText: String?
        var contextTranslationText: String?
        var contextAnalysisUpdatedAt: Date?
        var wordHelpItems: [WordHelpItem]
        var wordHelpUpdatedAt: Date?
        var selectedSenseText: String?
        var userNote: String?
        var localSourceItemID: UUID?
        var segmentIndex: Int?
        var sourceTrackID: String?
        var audioStart: Double?
        var audioEnd: Double?
        var manualAudioStart: Double? = nil
        var manualAudioEnd: Double? = nil
        var translationStatus: TranslationStatus
        var translationErrorCode: String?
    }
    struct Translation: Codable { let text: String?; let baseText: String?; let origin: String?; let updatedAt: Date? }
    struct Source: Codable { let id: UUID; let title: String; let context: Context? }
    struct Context: Codable { let text: String; let selectionUTF16: Selection }
    struct Selection: Codable { let location: Int; let length: Int }
    struct Diagnostics: Codable {
        let appVersion: String
        let operatingSystem: String
        let polishDefinitionErrors: [PolishLookupDiagnosticEvent]
    }
}

extension DictionaryTransferDocument.Translation {
    private enum CodingKeys: String, CodingKey { case text, baseText, origin, updatedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        baseText = try values.decodeIfPresent(String.self, forKey: .baseText)
        origin = try values.decodeIfPresent(String.self, forKey: .origin)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        try values.encode(baseText, forKey: .baseText)
        try values.encode(origin, forKey: .origin)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

extension DictionaryTransferDocument.Source {
    private enum CodingKeys: String, CodingKey { case id, title, context }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        context = try values.decodeIfPresent(DictionaryTransferDocument.Context.self, forKey: .context)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(context, forKey: .context)
    }
}

struct DictionaryJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum DictionaryImportMode: String, CaseIterable, Identifiable {
    case merge = "Merge dictionary"
    case restore = "Restore backup"
    case translations = "Update translations only"
    var id: String { rawValue }
}

struct DictionaryImportPreview: Identifiable {
    let id = UUID()
    let document: DictionaryTransferDocument
    let mode: DictionaryImportMode
    let additions: Int
    let translationChanges: Int
    let unchanged: Int
    let conflicts: Int
    let skipped: Int
    var restorations: Int = 0
    var vocabularyAdditions: Int = 0
    var vocabularyDuplicates: Int = 0
    var vocabularySnapshot: [String: Date]? = nil
}

enum DictionaryTransferError: LocalizedError {
    case tooLarge, invalidFormat, unsupportedVersion, tooManyEntries, duplicateID, invalidEntry(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Backup exceeds the size limit (20 MiB for v1/v2; 64 MiB for v3)."
        case .invalidFormat: "This is not a Foreign Language Learner dictionary file."
        case .unsupportedVersion: "This dictionary file version is not supported."
        case .tooManyEntries: "Dictionary file contains more than 50,000 entries."
        case .duplicateID: "Dictionary file contains duplicate entry IDs."
        case .invalidEntry(let message): "Invalid dictionary entry: \(message)"
        }
    }
}

enum DictionaryTransferService {
    static func export(entries: [DictionaryEntry], includeContext: Bool, readingWords: [ReadVocabularyWord] = [],
                       diagnosticEvents: [PolishLookupDiagnosticEvent] = PolishLookupDiagnosticLog.shared.events()) throws -> DictionaryJSONFile {
        let exported = entries.sorted { $0.id.uuidString < $1.id.uuidString }.map { entry in
            let translation = clean(entry.translationText)
            let context: DictionaryTransferDocument.Context?
            if includeContext, let text = entry.contextText, let location = entry.contextSelectionLocation,
               let length = entry.contextSelectionLength {
                context = .init(text: text, selectionUTF16: .init(location: location, length: length))
            } else { context = nil }
            return DictionaryTransferDocument.Entry(
                id: entry.id, text: entry.text, sourceLanguage: entry.sourceLanguageCode,
                targetLanguage: entry.targetLanguageCode,
                translation: .init(text: translation, baseText: translation,
                                   origin: translation == nil ? nil : entry.translationOriginRaw,
                                   updatedAt: translation == nil ? nil : entry.translationUpdatedAt),
                learningLevel: entry.learningLevel, createdAt: entry.createdAt,
                source: .init(id: entry.sourceItemID, title: entry.sourceTitle, context: context),
                details: .init(
                    contextSelectedTranslationText: entry.contextSelectedTranslationText,
                    contextTranslationText: entry.contextTranslationText,
                    contextAnalysisUpdatedAt: entry.contextAnalysisUpdatedAt,
                    wordHelpItems: entry.wordHelpItems, wordHelpUpdatedAt: entry.wordHelpUpdatedAt,
                    selectedSenseText: entry.selectedSenseText, userNote: entry.userNote,
                    localSourceItemID: entry.localSourceItemID, segmentIndex: entry.segmentIndex,
                    sourceTrackID: entry.sourceTrackID, audioStart: entry.audioStart, audioEnd: entry.audioEnd,
                    manualAudioStart: entry.manualAudioStart, manualAudioEnd: entry.manualAudioEnd,
                    translationStatus: entry.translationStatus, translationErrorCode: entry.translationErrorCode),
                levelChangedAt: entry.levelChangedAt
            )
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let diagnostics = DictionaryTransferDocument.Diagnostics(
            appVersion: "\(version) (\(build))",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            polishDefinitionErrors: diagnosticEvents
        )
        var document = DictionaryTransferDocument(format: "foreign-language-learner.dictionary", schemaVersion: 3,
                                                   exportedAt: .now, entries: exported, diagnostics: diagnostics)
        document.readingVocabulary = .init(tokenizerVersion: VocabularyTokenizer.version, words: readingWords
            .sorted { ($0.languageCode, $0.normalizedForm) < ($1.languageCode, $1.normalizedForm) }
            .map { .init(languageCode: $0.languageCode, normalizedForm: $0.normalizedForm, firstLearnedAt: $0.firstLearnedAt) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let exportDateFormatter = ISO8601DateFormatter()
        exportDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(exportDateFormatter.string(from: date))
        }
        let data = try encoder.encode(document)
        // Never produce a backup that our own importer would reject.
        _ = try decode(data)
        return DictionaryJSONFile(data: data)
    }

    static func decode(_ data: Data) throws -> DictionaryTransferDocument {
        guard data.count <= 64 * 1_024 * 1_024 else { throw DictionaryTransferError.tooLarge }
        let decoder = JSONDecoder()
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDateFormatter = ISO8601DateFormatter()
        wholeDateFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractionalDateFormatter.date(from: value) ?? wholeDateFormatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
        }
        let document = try decoder.decode(DictionaryTransferDocument.self, from: data)
        guard document.format == "foreign-language-learner.dictionary" else { throw DictionaryTransferError.invalidFormat }
        guard (1...3).contains(document.schemaVersion) else { throw DictionaryTransferError.unsupportedVersion }
        if document.schemaVersion < 3, data.count > 20 * 1_024 * 1_024 { throw DictionaryTransferError.tooLarge }
        if document.schemaVersion == 3 {
            guard let vocabulary = document.readingVocabulary, vocabulary.tokenizerVersion == VocabularyTokenizer.version,
                  vocabulary.words.count <= 500_000 else { throw DictionaryTransferError.invalidEntry("Invalid reading vocabulary version or count") }
            var keys = Set<String>()
            var bytes = 0
            for word in vocabulary.words {
                bytes += word.languageCode.utf8.count + word.normalizedForm.utf8.count
                guard bytes <= 32 * 1_024 * 1_024 else { throw DictionaryTransferError.tooLarge }
                guard (try? VocabularyTokenizer.language(word.languageCode)) == word.languageCode,
                      VocabularyTokenizer.normalized(word.normalizedForm) == word.normalizedForm,
                      word.firstLearnedAt.timeIntervalSince1970.isFinite else {
                    throw DictionaryTransferError.invalidEntry("Invalid reading vocabulary language, form or date")
                }
                let tokens = try VocabularyTokenizer.occurrences(in: word.normalizedForm)
                guard tokens.count == 1, tokens[0].rangeUTF16 == NSRange(location: 0, length: (word.normalizedForm as NSString).length),
                      keys.insert(ReadVocabularyWord.key(word.languageCode, word.normalizedForm)).inserted else {
                    throw DictionaryTransferError.invalidEntry("Invalid or duplicate reading vocabulary form")
                }
            }
        } else if document.readingVocabulary != nil {
            throw DictionaryTransferError.invalidEntry("Reading vocabulary requires backup v3")
        }
        guard document.entries.count <= 50_000 else { throw DictionaryTransferError.tooManyEntries }
        guard Set(document.entries.map(\.id)).count == document.entries.count else { throw DictionaryTransferError.duplicateID }
        for entry in document.entries {
            if document.schemaVersion >= 2, entry.details == nil {
                throw DictionaryTransferError.invalidEntry("\(entry.id): missing backup details")
            }
            try validate(entry)
        }
        return document
    }

    @MainActor static func preview(document: DictionaryTransferDocument, mode: DictionaryImportMode,
                                   existing: [DictionaryEntry], existingVocabulary: [ReadVocabularyWord]? = nil) -> DictionaryImportPreview {
        let local = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var additions = 0, changes = 0, unchanged = 0, conflicts = 0, skipped = 0, restorations = 0
        for incoming in document.entries {
            guard let current = local[incoming.id] else {
                if mode != .translations { additions += 1 } else { skipped += 1 }
                continue
            }
            guard current.text == incoming.text, current.sourceLanguageCode == incoming.sourceLanguage,
                  current.targetLanguageCode == incoming.targetLanguage else { conflicts += 1; continue }
            if mode == .restore { restorations += 1; continue }
            guard let proposed = clean(incoming.translation.text), proposed != current.translationText else { unchanged += 1; continue }
            if let base = clean(incoming.translation.baseText), base != current.translationText { conflicts += 1 }
            else { changes += 1 }
        }
        var result = DictionaryImportPreview(document: document, mode: mode, additions: additions, translationChanges: changes,
                     unchanged: unchanged, conflicts: conflicts, skipped: skipped, restorations: restorations)
        if let existingVocabulary {
            let snapshot = Dictionary(uniqueKeysWithValues: existingVocabulary.map { ($0.key, $0.firstLearnedAt) })
            result.vocabularySnapshot = snapshot
            if mode != .translations, let words = document.readingVocabulary?.words {
                result.vocabularyAdditions = words.filter { snapshot[ReadVocabularyWord.key($0.languageCode, $0.normalizedForm)] == nil }.count
                result.vocabularyDuplicates = words.count - result.vocabularyAdditions
            }
        }
        return result
    }

    @MainActor static func apply(_ preview: DictionaryImportPreview, context: ModelContext, commitSave: (ModelContext) throws -> Void = { try $0.save() }) throws -> [DictionaryEntry] {
        let readingWords = preview.document.schemaVersion == 3 && preview.mode != .translations ? preview.document.readingVocabulary?.words : nil
        let vocabulary = readingWords == nil ? [] : try ReadingKnowledge.words(context: context)
        if readingWords != nil, let expected = preview.vocabularySnapshot,
           expected != Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.key, $0.firstLearnedAt) }) {
            throw ReadingVocabularyError.changed
        }
        // Flush unrelated edits before starting this synchronous atomic transaction.
        try context.save()
        let existing = try context.fetch(FetchDescriptor<DictionaryEntry>())
        let local = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let incomingIDs = Set(preview.document.entries.map(\.id))
        let rollbackEntries = existing.filter { incomingIDs.contains($0.id) }.map { ($0, DictionaryEntryRollbackSnapshot($0)) }
        let persistedWords = readingWords == nil ? [] : try context.fetch(FetchDescriptor<ReadVocabularyWord>())
        let persistedByKey = Dictionary(uniqueKeysWithValues: persistedWords.map { ($0.key, $0) })
        let rollbackWordDates = persistedWords.map { ($0, $0.firstLearnedAt) }
        struct KnowledgeGroup: Hashable { let language: String; let date: Date }
        let localWords = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.key, $0) })
        var additions: [KnowledgeGroup: Set<String>] = [:]
        var dateUpdates: [(ReadVocabularyWord, Date)] = []
        for word in readingWords ?? [] {
            let key = ReadVocabularyWord.key(word.languageCode, word.normalizedForm)
            if let current = localWords[key], current.firstLearnedAt <= word.firstLearnedAt { continue }
            if let persistent = persistedByKey[key] {
                dateUpdates.append((persistent, word.firstLearnedAt))
            } else {
                additions[KnowledgeGroup(language: word.languageCode, date: word.firstLearnedAt), default: []].insert(word.normalizedForm)
            }
        }
        // Encode before changing any model, so a preparation failure cannot leave partial edits.
        let encoded = try additions.map { (group: $0.key, data: try ReadingKnowledge.encode($0.value)) }
        var pending: [DictionaryEntry] = []
        for incoming in preview.document.entries {
            if let current = local[incoming.id] {
                guard current.text == incoming.text, current.sourceLanguageCode == incoming.sourceLanguage,
                      current.targetLanguageCode == incoming.targetLanguage else { continue }
                if preview.mode == .restore {
                    restore(incoming, to: current)
                    if current.translationStatus == .pending { pending.append(current) }
                    continue
                }
                guard let proposed = clean(incoming.translation.text), proposed != current.translationText else { continue }
                if let base = clean(incoming.translation.baseText), base != current.translationText { continue }
                current.translationText = proposed
                current.translationOrigin = .imported
                current.translationStatus = .ready
                current.translationUpdatedAt = .now
                current.translationRevision += 1
            } else if preview.mode != .translations {
                let contextValue = incoming.source.context.map {
                    SelectionContext(text: $0.text, selection: NSRange(location: $0.selectionUTF16.location, length: $0.selectionUTF16.length))
                }
                let entry = DictionaryEntry(id: incoming.id, text: incoming.text, sourceItemID: incoming.source.id,
                                            sourceTitle: incoming.source.title, createdAt: incoming.createdAt,
                                            sourceLanguageCode: incoming.sourceLanguage, targetLanguageCode: incoming.targetLanguage,
                                            translationText: clean(incoming.translation.text),
                                            translationUpdatedAt: incoming.translation.updatedAt,
                                            learningLevel: incoming.learningLevel, context: contextValue)
                restore(incoming, to: entry)
                context.insert(entry)
                if entry.translationStatus == .pending { pending.append(entry) }
            }
        }
        for (word, date) in dateUpdates { word.firstLearnedAt = date }
        for batch in encoded {
            ReadingKnowledge.insert(batch.data, language: batch.group.language, date: batch.group.date, context: context)
        }
        context.processPendingChanges()
        do { try commitSave(context) }
        catch {
            context.rollback()
            for (entry, snapshot) in rollbackEntries { snapshot.restore(entry) }
            for (word, date) in rollbackWordDates { word.firstLearnedAt = date }
            throw error
        }
        return pending
    }

    @MainActor private static func restore(_ incoming: DictionaryTransferDocument.Entry, to entry: DictionaryEntry) {
        entry.translationRevision += 1
        entry.contextAnalysisRevision += 1
        entry.text = DictionaryEntry.normalized(incoming.text)
        entry.sourceLanguageCode = incoming.sourceLanguage
        entry.targetLanguageCode = incoming.targetLanguage
        entry.sourceItemID = incoming.source.id
        entry.sourceTitle = incoming.source.title
        entry.createdAt = incoming.createdAt
        entry.translationText = clean(incoming.translation.text)
        entry.translationOriginRaw = incoming.translation.origin
        entry.translationUpdatedAt = incoming.translation.updatedAt
        entry.learningLevel = incoming.learningLevel
        entry.levelChangedAt = incoming.levelChangedAt ?? .now
        entry.contextText = incoming.source.context?.text
        entry.contextSelectionLocation = incoming.source.context?.selectionUTF16.location
        entry.contextSelectionLength = incoming.source.context?.selectionUTF16.length
        if let details = incoming.details {
            entry.contextSelectedTranslationText = details.contextSelectedTranslationText
            entry.contextTranslationText = details.contextTranslationText
            entry.contextAnalysisUpdatedAt = details.contextAnalysisUpdatedAt
            entry.wordHelpItems = details.wordHelpItems
            entry.wordHelpUpdatedAt = details.wordHelpUpdatedAt
            entry.selectedSenseText = details.selectedSenseText
            entry.userNote = details.userNote
            entry.localSourceItemID = details.localSourceItemID
            entry.segmentIndex = details.segmentIndex
            entry.sourceTrackID = details.sourceTrackID
            entry.audioStart = details.audioStart
            entry.audioEnd = details.audioEnd
            entry.manualAudioStart = details.manualAudioStart
            entry.manualAudioEnd = details.manualAudioEnd
            entry.translationStatus = details.translationStatus
            entry.translationErrorCode = details.translationErrorCode
        } else {
            entry.manualAudioStart = nil
            entry.manualAudioEnd = nil
            entry.translationStatus = entry.hasTranslation ? .ready : .pending
        }
        // Requests cannot survive a restore; usable translations are immediately ready.
        if entry.hasTranslation {
            entry.translationStatus = .ready
            entry.translationErrorCode = nil
        } else if entry.translationStatus == .translating || entry.translationStatus == .ready {
            entry.translationStatus = .pending
            entry.translationErrorCode = nil
        }
    }

    private static func validate(_ entry: DictionaryTransferDocument.Entry) throws {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.text.utf8.count <= 65_536 else {
            throw DictionaryTransferError.invalidEntry("\(entry.id): invalid original text")
        }
        guard (1...4).contains(entry.learningLevel) else { throw DictionaryTransferError.invalidEntry("\(entry.id): invalid level") }
        guard !entry.sourceLanguage.isEmpty, entry.sourceLanguage.count <= 64,
              !entry.targetLanguage.isEmpty, entry.targetLanguage.count <= 64 else {
            throw DictionaryTransferError.invalidEntry("\(entry.id): invalid language")
        }
        guard entry.source.title.count <= 500 else { throw DictionaryTransferError.invalidEntry("\(entry.id): source title too long") }
        if let value = entry.translation.text,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.utf8.count > 65_536 {
            throw DictionaryTransferError.invalidEntry("\(entry.id): invalid translation")
        }
        if let value = entry.translation.baseText,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.utf8.count > 65_536 {
            throw DictionaryTransferError.invalidEntry("\(entry.id): invalid base translation")
        }
        if let origin = entry.translation.origin,
           TranslationOrigin(rawValue: origin) == nil { throw DictionaryTransferError.invalidEntry("\(entry.id): invalid translation origin") }
        if entry.translation.text == nil,
           entry.translation.baseText != nil || entry.translation.origin != nil || entry.translation.updatedAt != nil {
            throw DictionaryTransferError.invalidEntry("\(entry.id): untranslated entry has translation metadata")
        }
        if let details = entry.details {
            let values = [details.contextSelectedTranslationText, details.contextTranslationText,
                          details.selectedSenseText, details.userNote, details.translationErrorCode]
            guard values.allSatisfy({ ($0?.utf8.count ?? 0) <= 65_536 }),
                  details.wordHelpItems.count <= 2_000,
                  details.wordHelpItems.allSatisfy({
                      !$0.sourceText.isEmpty && !$0.translationText.isEmpty
                          && $0.sourceText.utf8.count <= 65_536 && $0.translationText.utf8.count <= 65_536
                  }),
                  details.segmentIndex.map({ $0 >= 0 }) ?? true,
                  details.sourceTrackID.map({ !$0.isEmpty && $0.utf8.count <= 500 }) ?? true else {
                throw DictionaryTransferError.invalidEntry("\(entry.id): invalid backup details")
            }
            switch (details.manualAudioStart, details.manualAudioEnd) {
            case (nil, nil): break
            case let (start?, end?) where start.isFinite && end.isFinite && start >= 0 && end > start: break
            default: throw DictionaryTransferError.invalidEntry("\(entry.id): invalid manual audio range")
            }
            switch (details.audioStart, details.audioEnd) {
            case (nil, nil): break
            case let (start?, end?) where start.isFinite && end.isFinite && start >= 0 && end > start: break
            default: throw DictionaryTransferError.invalidEntry("\(entry.id): invalid audio range")
            }
        }
        if let context = entry.source.context {
            let count = (context.text as NSString).length
            let range = NSRange(location: context.selectionUTF16.location, length: context.selectionUTF16.length)
            guard count <= 2_000, range.location >= 0, range.location <= count,
                  range.length > 0, range.length <= count - range.location,
                  Range(range, in: context.text) != nil,
                  DictionaryEntry.normalized((context.text as NSString).substring(with: range)) == DictionaryEntry.normalized(entry.text) else {
                throw DictionaryTransferError.invalidEntry("\(entry.id): invalid context selection")
            }
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
