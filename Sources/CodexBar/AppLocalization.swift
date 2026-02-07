import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    static let defaultsKey = "appLanguage"

    var id: String { self.rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system:
            nil
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        }
    }
}

enum AppLocalization {
    static func currentLanguage() -> AppLanguage {
        self.selectedLanguage()
    }

    static func ui(_ key: String) -> String {
        self.string(key, language: self.currentLanguage())
    }

    static func selectedLanguage(userDefaults: UserDefaults = .standard) -> AppLanguage {
        guard let raw = userDefaults.string(forKey: AppLanguage.defaultsKey),
              let language = AppLanguage(rawValue: raw)
        else {
            return .system
        }
        return language
    }

    static func locale(for language: AppLanguage) -> Locale {
        guard let identifier = language.localeIdentifier else {
            return .autoupdatingCurrent
        }
        return Locale(identifier: identifier)
    }

    static func string(_ key: String, language: AppLanguage) -> String {
        guard let bundle = self.bundle(for: language) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, language: AppLanguage, _ args: CVarArg...) -> String {
        let template = self.string(key, language: language)
        return String(format: template, locale: .current, arguments: args)
    }

    static func displayNameKey(for language: AppLanguage) -> String {
        switch language {
        case .system:
            "Language.System"
        case .english:
            "Language.English"
        case .simplifiedChinese:
            "Language.SimplifiedChinese"
        }
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        guard let identifier = language.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return nil
        }
        return bundle
    }
}

extension String {
    var appLocalized: String {
        AppLocalization.ui(self)
    }
}
