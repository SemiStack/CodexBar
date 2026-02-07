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
        let bundle = self.bundle(for: language) ?? self.localizationBundle
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
        guard let identifier = language.localeIdentifier else {
            return self.localizationBundle
        }
        let resourceNames = self.candidateResourceNames(for: identifier)
        for base in self.candidateBundles {
            for resource in resourceNames {
                if let path = base.path(forResource: resource, ofType: "lproj"),
                   let bundle = Bundle(path: path)
                {
                    return bundle
                }
            }
        }
        return nil
    }

    private static var localizationBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    private static var candidateBundles: [Bundle] {
        let primary = self.localizationBundle
        if primary.bundleURL == Bundle.main.bundleURL {
            return [primary]
        }
        return [primary, .main]
    }

    private static func candidateResourceNames(for identifier: String) -> [String] {
        var names: [String] = [identifier]
        let lower = identifier.lowercased()
        if !names.contains(lower) { names.append(lower) }
        let underscore = identifier.replacingOccurrences(of: "-", with: "_")
        if !names.contains(underscore) { names.append(underscore) }
        let underscoreLower = underscore.lowercased()
        if !names.contains(underscoreLower) { names.append(underscoreLower) }
        return names
    }
}

extension String {
    var appLocalized: String {
        AppLocalization.ui(self)
    }
}
