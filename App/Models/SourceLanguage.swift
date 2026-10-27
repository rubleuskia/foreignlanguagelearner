import Foundation

struct SourceLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let supportedCodes = ["en", "fr", "es", "de", "it", "pl"]
    static let supported = supportedCodes.map { SourceLanguage(code: $0, name: name(for: $0)) }
    static let polish = SourceLanguage(code: "pl", name: name(for: "pl"))
    static let activeKey = "source-language.active.v1"
    static let importKey = "source-language.new-book.v1"

    private static let flagRegions = ["en": "GB", "fr": "FR", "es": "ES", "de": "DE", "it": "IT", "pl": "PL"]

    var flag: String {
        guard let region = Self.flagRegions[code] else { return "🌐" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
        }))
    }

    var flaggedName: String { "\(flag) \(name)" }

    /// Only supported base languages are collapsed. Historical unrelated tags keep their identity.
    static func canonical(_ input: String) -> String {
        let tag = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
        guard tag.range(of: #"^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$"#, options: .regularExpression) != nil else { return tag }
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        return supportedCodes.contains(base) ? base : tag
    }

    static func isSupported(_ input: String) -> Bool { supportedCodes.contains(canonical(input)) }
    static func availableForRussian() async -> [SourceLanguage] { supported }

    static func groups(_ codes: [String]) -> [SourceLanguage] {
        let historical = Set(codes.map(canonical)).subtracting(supportedCodes).filter { !$0.isEmpty }.sorted()
        return supported + historical.map { .init(code: $0, name: name(for: $0)) }
    }

    /// Filter choices come from books, including books without dictionary entries.
    /// Orphan entries remain accessible when the library has no books at all.
    static func filterGroups(bookCodes: [String], entryCodes: [String]) -> [SourceLanguage] {
        let codes = bookCodes.isEmpty ? entryCodes : bookCodes
        let present = Set(codes.map(canonical).filter { !$0.isEmpty })
        return present.map { .init(code: $0, name: name(for: $0)) }
            .sorted { lhs, rhs in
                let left = supportedCodes.firstIndex(of: lhs.code) ?? supportedCodes.count
                let right = supportedCodes.firstIndex(of: rhs.code) ?? supportedCodes.count
                return left == right ? lhs.code < rhs.code : left < right
            }
    }

    static func resolvedActive(_ current: String, available: [SourceLanguage]) -> String {
        let code = canonical(current)
        return available.contains(where: { $0.code == code }) ? code : available.first?.code ?? "pl"
    }

    @MainActor static func entries(_ entries: [DictionaryEntry], language: String) -> [DictionaryEntry] {
        let code = canonical(language)
        return entries.filter { canonical($0.sourceLanguageCode) == code }
    }

    static func initializeActive(codes: [String], defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: activeKey) == nil else { return }
        defaults.set(codes.first.map(canonical) ?? defaults.string(forKey: importKey) ?? "pl", forKey: activeKey)
    }

    static func name(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}
