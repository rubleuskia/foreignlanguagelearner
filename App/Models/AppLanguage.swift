import Foundation

enum AppLanguage {
    static let key = "interface.language.v1"
    static let supported = ["ru", "en"]

    static func resolved(_ value: String?) -> String {
        value == "en" ? "en" : "ru"
    }

    static var current: String {
        if ProcessInfo.processInfo.arguments.contains("--uitesting"),
           !ProcessInfo.processInfo.arguments.contains("--test-russian-ui") {
            return "en"
        }
        return resolved(UserDefaults.standard.string(forKey: key))
    }

    static func text(_ key: String) -> String {
        let language = current
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ values: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: current), arguments: values)
    }
}
