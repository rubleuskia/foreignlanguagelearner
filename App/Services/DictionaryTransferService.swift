import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryTransferDocument: Codable {
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let entries: [Entry]

    struct Entry: Codable, Identifiable {
        let id: UUID
        let text: String
        let sourceLanguage: String
        let targetLanguage: String
        let translation: Translation
        let learningLevel: Int
        let createdAt: Date
        let source: Source
    }
    struct Translation: Codable { let text: String?; let baseText: String?; let origin: String?; let updatedAt: Date? }
    struct Source: Codable { let id: UUID; let title: String; let context: Context? }
    struct Context: Codable { let text: String; let selectionUTF16: Selection }
    struct Selection: Codable { let location: Int; let length: Int }
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
}

enum DictionaryTransferError: LocalizedError {
    case tooLarge, invalidFormat, unsupportedVersion, tooManyEntries, duplicateID, invalidEntry(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Dictionary file exceeds the 20 MB limit."
        case .invalidFormat: "This is not a Foreign Language Learner dictionary file."
        case .unsupportedVersion: "This dictionary file version is not supported."
        case .tooManyEntries: "Dictionary file contains more than 50,000 entries."
        case .duplicateID: "Dictionary file contains duplicate entry IDs."
        case .invalidEntry(let message): "Invalid dictionary entry: \(message)"
        }
    }
}

enum DictionaryTransferService {
    static func export(entries: [DictionaryEntry], includeContext: Bool) throws -> DictionaryJSONFile {
        let exported = entries.sorted { $0.id.uuidString < $1.id.uuidString }.map { entry in
            let translation = entry.translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let context: DictionaryTransferDocument.Context?
            if includeContext, let text = entry.contextText, let location = entry.contextSelectionLocation,
               let length = entry.contextSelectionLength {
                context = .init(text: text, selectionUTF16: .init(location: location, length: length))
            } else { context = nil }
            return DictionaryTransferDocument.Entry(
                id: entry.id, text: entry.text, sourceLanguage: entry.sourceLanguageCode,
                targetLanguage: entry.targetLanguageCode,
                translation: .init(text: translation, baseText: translation,
                                   origin: entry.translationOriginRaw, updatedAt: entry.translationUpdatedAt),
                learningLevel: entry.learningLevel, createdAt: entry.createdAt,
                source: .init(id: entry.sourceItemID, title: entry.sourceTitle, context: context)
            )
        }
        let document = DictionaryTransferDocument(format: "foreign-language-learner.dictionary", schemaVersion: 1,
                                                   exportedAt: .now, entries: exported)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try DictionaryJSONFile(data: encoder.encode(document))
    }

    static func decode(_ data: Data) throws -> DictionaryTransferDocument {
        guard data.count <= 20 * 1_024 * 1_024 else { throw DictionaryTransferError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DictionaryTransferDocument.self, from: data)
        guard document.format == "foreign-language-learner.dictionary" else { throw DictionaryTransferError.invalidFormat }
        guard document.schemaVersion == 1 else { throw DictionaryTransferError.unsupportedVersion }
        guard document.entries.count <= 50_000 else { throw DictionaryTransferError.tooManyEntries }
        guard Set(document.entries.map(\.id)).count == document.entries.count else { throw DictionaryTransferError.duplicateID }
        for entry in document.entries { try validate(entry) }
        return document
    }

    @MainActor static func preview(document: DictionaryTransferDocument, mode: DictionaryImportMode,
                                   existing: [DictionaryEntry]) -> DictionaryImportPreview {
        let local = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var additions = 0, changes = 0, unchanged = 0, conflicts = 0, skipped = 0
        for incoming in document.entries {
            guard let current = local[incoming.id] else {
                if mode == .merge { additions += 1 } else { skipped += 1 }
                continue
            }
            guard current.text == incoming.text, current.sourceLanguageCode == incoming.sourceLanguage,
                  current.targetLanguageCode == incoming.targetLanguage else { conflicts += 1; continue }
            guard let proposed = clean(incoming.translation.text), proposed != current.translationText else { unchanged += 1; continue }
            if let base = clean(incoming.translation.baseText), base != current.translationText { conflicts += 1 }
            else { changes += 1 }
        }
        return .init(document: document, mode: mode, additions: additions, translationChanges: changes,
                     unchanged: unchanged, conflicts: conflicts, skipped: skipped)
    }

    @MainActor static func apply(_ preview: DictionaryImportPreview, context: ModelContext) throws -> [DictionaryEntry] {
        let existing = try context.fetch(FetchDescriptor<DictionaryEntry>())
        let local = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var pending: [DictionaryEntry] = []
        for incoming in preview.document.entries {
            if let current = local[incoming.id] {
                guard current.text == incoming.text, current.sourceLanguageCode == incoming.sourceLanguage,
                      current.targetLanguageCode == incoming.targetLanguage else { continue }
                guard let proposed = clean(incoming.translation.text), proposed != current.translationText else { continue }
                if let base = clean(incoming.translation.baseText), base != current.translationText { continue }
                current.translationText = proposed
                current.translationOrigin = .imported
                current.translationStatus = .ready
                current.translationUpdatedAt = .now
                current.translationRevision += 1
            } else if preview.mode == .merge {
                let contextValue = incoming.source.context.map {
                    SelectionContext(text: $0.text, selection: NSRange(location: $0.selectionUTF16.location, length: $0.selectionUTF16.length))
                }
                let entry = DictionaryEntry(id: incoming.id, text: incoming.text, sourceItemID: incoming.source.id,
                                            sourceTitle: incoming.source.title, createdAt: incoming.createdAt,
                                            sourceLanguageCode: incoming.sourceLanguage, targetLanguageCode: incoming.targetLanguage,
                                            translationText: clean(incoming.translation.text),
                                            translationUpdatedAt: incoming.translation.updatedAt,
                                            learningLevel: incoming.learningLevel, context: contextValue)
                context.insert(entry)
                if !entry.hasTranslation { pending.append(entry) }
            }
        }
        try context.save()
        return pending
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
        if let context = entry.source.context {
            let count = (context.text as NSString).length
            let range = NSRange(location: context.selectionUTF16.location, length: context.selectionUTF16.length)
            guard count <= 2_000, range.location >= 0, range.length > 0, NSMaxRange(range) <= count,
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
