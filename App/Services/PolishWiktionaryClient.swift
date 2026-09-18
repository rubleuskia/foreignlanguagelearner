import Foundation

struct PolishDictionaryResult: Codable, Equatable, Sendable {
    var requestedWord: String
    var headword: String
    var resolvedFromForm: String? = nil
    var partOfSpeech: String?
    var meanings: [PolishDictionaryMeaning]
    var sourceURL: String
    var revisionID: Int?
    var fetchedAt: Date
    var formOfLemma: String? = nil
}

struct PolishDictionaryMeaning: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var definition: String
    var examples: [String]
    var usageLabels: [String]
}

protocol PolishDictionaryProviding: Sendable {
    func lookup(_ word: String, preferredLemma: String?) async throws -> PolishDictionaryResult
}

struct PolishWiktionaryClient: PolishDictionaryProviding {
    private let session: URLSession
    private let lemmaResolver: any PolishLemmaResolving
    private let diagnostics: PolishLookupDiagnosticLog

    init(session: URLSession = .shared,
         lemmaResolver: any PolishLemmaResolving = BundledPolishLemmaResolver(),
         diagnostics: PolishLookupDiagnosticLog = .shared) {
        self.session = session
        self.lemmaResolver = lemmaResolver
        self.diagnostics = diagnostics
    }

    func lookup(_ word: String, preferredLemma: String? = nil) async throws -> PolishDictionaryResult {
        if let preferredLemma {
            return try await lookupPage(preferredLemma).resolved(for: word)
        }

        let initial: PolishDictionaryResult
        do {
            initial = try await lookupPage(word)
        } catch let error as PolishWiktionaryError where error.supportsLemmaFallback {
            let lemmas = try await lemmaResolver.lemmas(for: word)
                .filter { Self.comparisonKey($0) != Self.comparisonKey(word) }
            guard !lemmas.isEmpty else { throw error }
            guard lemmas.count == 1, let lemma = lemmas.first else {
                throw PolishWiktionaryError.ambiguousLemmas(lemmas)
            }
            return try await lookupPage(lemma).resolved(for: word)
        }
        guard let lemma = initial.formOfLemma,
              Self.comparisonKey(lemma) != Self.comparisonKey(word) else {
            return initial
        }
        do {
            return try await lookupPage(lemma).resolved(for: word)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.record(error: error, operation: "lookup-derived-lemma",
                               word: word, preferredLemma: lemma)
            return initial
        }
    }

    private func lookupPage(_ word: String) async throws -> PolishDictionaryResult {
        let url = try Self.requestURL(for: word)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ForeignLanguageLearner/0.1 (https://github.com/rubleuskia/foreignlanguagelearner)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PolishWiktionaryError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try PolishWiktionaryParser.parse(data: data, requestedWord: word)
    }

    private static func comparisonKey(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "pl_PL"))
    }

    static func requestURL(for word: String) throws -> URL {
        guard var components = URLComponents(string: "https://pl.wiktionary.org/w/api.php") else {
            throw PolishWiktionaryError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "revisions"),
            URLQueryItem(name: "titles", value: word),
            URLQueryItem(name: "rvprop", value: "ids|timestamp|content"),
            URLQueryItem(name: "rvslots", value: "main"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "redirects", value: "1")
        ]
        guard let url = components.url else { throw PolishWiktionaryError.invalidRequest }
        return url
    }
}

enum PolishWiktionaryError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case serverError(Int)
    case wordNotFound
    case noPolishEntry
    case noDefinitions
    case ambiguousLemmas([String])

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The Wiktionary request could not be created."
        case .invalidResponse: "Wiktionary returned an unreadable response."
        case .serverError(let status): "Wiktionary is currently unavailable (HTTP \(status))."
        case .wordNotFound: "This word was not found in Wiktionary."
        case .noPolishEntry: "No Polish dictionary entry was found for this word."
        case .noDefinitions: "The Polish entry contains no definitions the app can display."
        case .ambiguousLemmas: "Several Polish dictionary forms match this word."
        }
    }

    var supportsLemmaFallback: Bool {
        switch self {
        case .wordNotFound, .noPolishEntry, .noDefinitions: true
        default: false
        }
    }
}

private extension PolishDictionaryResult {
    func resolved(for originalWord: String) -> Self {
        var result = self
        result.requestedWord = originalWord
        let locale = Locale(identifier: "pl_PL")
        let originalKey = originalWord.precomposedStringWithCanonicalMapping.lowercased(with: locale)
        let headwordKey = headword.precomposedStringWithCanonicalMapping.lowercased(with: locale)
        result.resolvedFromForm = originalKey == headwordKey ? nil : originalWord
        return result
    }
}

enum PolishWiktionaryParser {
    private struct Response: Decodable {
        struct Query: Decodable {
            struct Page: Decodable {
                struct Revision: Decodable {
                    struct Slots: Decodable {
                        struct Main: Decodable { let content: String }
                        let main: Main
                    }
                    let revid: Int?
                    let slots: Slots
                }
                let title: String
                let missing: Bool?
                let revisions: [Revision]?
            }
            let pages: [Page]
        }
        let query: Query
    }

    static func parse(data: Data, requestedWord: String, fetchedAt: Date = .now) throws -> PolishDictionaryResult {
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw PolishWiktionaryError.invalidResponse }
        guard let page = decoded.query.pages.first, page.missing != true else {
            throw PolishWiktionaryError.wordNotFound
        }
        guard let revision = page.revisions?.first else { throw PolishWiktionaryError.invalidResponse }
        let polish = try polishSection(in: revision.slots.main.content)
        let meaningsBlock = block(named: "znaczenia", in: polish)
        let examplesBlock = block(named: "przykłady", in: polish)
        let examples = numberedLines(in: examplesBlock)
        let formOfLemma = formOfLemma(in: meaningsBlock)

        var partOfSpeech: String?
        var meanings: [PolishDictionaryMeaning] = []
        for line in meaningsBlock.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("''"), trimmed.hasSuffix("''") {
                partOfSpeech = cleanMarkup(trimmed)
                continue
            }
            guard let numbered = numberedLine(trimmed) else { continue }
            let labels = leadingLabels(in: numbered.text)
            let definition = cleanMarkup(numbered.text)
            guard !definition.isEmpty else { continue }
            meanings.append(.init(id: numbered.id, definition: definition,
                                  examples: examples[numbered.id, default: []], usageLabels: labels))
        }
        guard !meanings.isEmpty else { throw PolishWiktionaryError.noDefinitions }
        let encodedTitle = page.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page.title
        let revisionQuery = revision.revid.map { "?oldid=\($0)" } ?? ""
        return .init(requestedWord: requestedWord, headword: page.title, partOfSpeech: partOfSpeech,
                     meanings: meanings,
                     sourceURL: "https://pl.wiktionary.org/wiki/\(encodedTitle)\(revisionQuery)",
                     revisionID: revision.revid, fetchedAt: fetchedAt, formOfLemma: formOfLemma)
    }

    private static func polishSection(in source: String) throws -> String {
        let pattern = #"(?ms)^==[^\n]*\{\{język polski\}\}[^\n]*==\s*$(.*?)(?=^==[^=\n]|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let sectionRange = Range(match.range(at: 1), in: source) else {
            throw PolishWiktionaryError.noPolishEntry
        }
        return String(source[sectionRange])
    }

    private static func block(named name: String, in section: String) -> String {
        let marker = "{{\(name)}}"
        guard let markerRange = section.range(of: marker) else { return "" }
        let start = markerRange.upperBound
        let remainder = String(section[start...])
        let headingPattern = #"(?m)^\{\{[^\n}]+\}\}.*$"#
        guard let regex = try? NSRegularExpression(pattern: headingPattern),
              let match = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
              let range = Range(match.range, in: remainder) else { return remainder }
        return String(remainder[..<range.lowerBound])
    }

    private static func numberedLines(in block: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in block.components(separatedBy: .newlines) {
            guard let item = numberedLine(line.trimmingCharacters(in: .whitespaces)) else { continue }
            let value = cleanMarkup(item.text)
            if !value.isEmpty { result[item.id, default: []].append(value) }
        }
        return result
    }

    private static func formOfLemma(in meanings: String) -> String? {
        let pattern = #"''od:''\s*\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: meanings, range: NSRange(meanings.startIndex..., in: meanings)),
              let range = Range(match.range(at: 1), in: meanings) else { return nil }
        return String(meanings[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numberedLine(_ line: String) -> (id: String, text: String)? {
        let pattern = #"^:\s*\(([^)]+)\)\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let idRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[idRange]), String(line[textRange]))
    }

    private static func leadingLabels(in text: String) -> [String] {
        let pattern = #"^\s*\{\{([^}|]+)(?:\|[^}]*)?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var labels: [String] = []
        var remainder = text
        while let match = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
              let valueRange = Range(match.range(at: 1), in: remainder),
              let wholeRange = Range(match.range, in: remainder) {
            let key = String(remainder[valueRange])
            labels.append(labelNames[key] ?? key)
            remainder.removeSubrange(wholeRange)
        }
        return labels
    }

    private static func cleanMarkup(_ source: String) -> String {
        var value = source
        value = replacing(#"<ref\b[^>]*>.*?</ref>"#, in: value, with: "")
        value = replacing(#"<ref\b[^>]*/>"#, in: value, with: "")
        value = replacing(#"\[\[[^\]|]+\|([^\]]+)\]\]"#, in: value, with: "$1")
        value = replacing(#"\[\[([^\]]+)\]\]"#, in: value, with: "$1")
        value = replacing(#"\{\{[^{}]*\}\}"#, in: value, with: "")
        value = value.replacingOccurrences(of: "'''", with: "")
            .replacingOccurrences(of: "''", with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                              withTemplate: replacement)
    }

    private static let labelNames = [
        "archit": "architektura", "urb": "urbanistyka", "urz": "urzędowe",
        "herald": "heraldyka", "pot": "potocznie", "przest": "przestarzałe",
        "daw": "dawne", "książk": "książkowe", "żart": "żartobliwe"
    ]
}
