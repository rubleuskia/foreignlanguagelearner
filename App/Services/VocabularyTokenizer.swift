import Foundation

enum VocabularyTokenizer {
    static let version = 1
    private static let expression = try! NSRegularExpression(
        pattern: #"\p{L}[\p{L}\p{M}]*(?:['’]\p{L}[\p{L}\p{M}]*)*"#)

    static func language(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard value.count <= 64,
              value.range(of: #"^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$"#, options: .regularExpression) != nil else {
            throw ReadingVocabularyError.invalidLanguage
        }
        return value
    }

    static func groupLanguage(_ input: String) throws -> String {
        SourceLanguage.canonical(try language(input))
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
            .lowercased(with: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }

    static func occurrences(in text: String) throws -> [VocabularyOccurrence] {
        var output: [VocabularyOccurrence] = []
        var cancelled = false
        let source = text as NSString
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Task<Never, Never>.isCancelled { cancelled = true; stop.pointee = true; return }
            if let match { output.append(.init(normalizedForm: normalized(source.substring(with: match.range)), rangeUTF16: match.range)) }
        }
        if cancelled { throw CancellationError() }
        return output
    }

    static func textIndex(in text: String) throws -> VocabularyTextIndex {
        var ids: [String: Int] = [:]
        var forms: [String] = []
        var positions: [VocabularyTextIndex.Position] = []
        var cancelled = false
        let source = text as NSString
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Task<Never, Never>.isCancelled { cancelled = true; stop.pointee = true; return }
            guard let match else { return }
            let form = normalized(source.substring(with: match.range))
            let id: Int
            if let existing = ids[form] { id = existing }
            else { id = forms.count; forms.append(form); ids[form] = id }
            positions.append(.init(start: match.range.location, length: match.range.length, formID: id))
        }
        if cancelled { throw CancellationError() }
        return .init(forms: forms, positions: positions, utf16Length: source.length)
    }

    static func forms(in text: String) throws -> Set<String> {
        var output = Set<String>()
        var cancelled = false
        let source = text as NSString
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Task<Never, Never>.isCancelled { cancelled = true; stop.pointee = true; return }
            if let match { output.insert(normalized(source.substring(with: match.range))) }
        }
        if cancelled { throw CancellationError() }
        return output
    }
}

enum ReadingVocabularyError: LocalizedError {
    case invalidLanguage, notReady, changed, missingItem
    var errorDescription: String? {
        switch self {
        case .invalidLanguage: "Enter a valid source language tag."
        case .notReady: "Reading vocabulary is still updating. Retry when it is ready."
        case .changed: "The text or known words changed. Review the completion again."
        case .missingItem: "This book or chapter is no longer available."
        }
    }
}
