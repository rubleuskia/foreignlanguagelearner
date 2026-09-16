import Foundation
import Translation

struct SourceLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let polish = SourceLanguage(code: "pl", name: name(for: "pl"))

    static func availableForRussian() async -> [SourceLanguage] {
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: "ru")
        var values: [SourceLanguage] = []
        for language in await availability.supportedLanguages {
            let code = language.minimalIdentifier
            guard code != "ru", await availability.status(from: language, to: target) != .unsupported else { continue }
            values.append(.init(code: code, name: name(for: code)))
        }
        if !values.contains(where: { $0.code == "pl" }) { values.append(polish) }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func name(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code
    }
}
