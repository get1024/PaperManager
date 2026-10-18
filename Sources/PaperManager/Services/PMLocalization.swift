import Foundation

/// Application-owned UI only. User titles, names, identifiers, raw enums and
/// exported bibliography fields must never be passed through this lookup.
enum PMLocalization {
    private static let lock = NSLock()
    private static var selectedLanguage = "system"

    static var languageIdentifier: String {
        lock.lock(); defer { lock.unlock() }
        return selectedLanguage
    }

    static func configure(_ identifier: String) {
        lock.lock(); defer { lock.unlock() }
        selectedLanguage = ["system", "en", "zh-Hans"].contains(identifier) ? identifier : "system"
    }

    static func resolvedLanguage(_ identifier: String? = nil) -> String {
        let identifier = identifier ?? languageIdentifier
        if identifier == "en" || identifier == "zh-Hans" { return identifier }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return (system?.first ?? Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }

    /// Called before constructing each app scene, so AppKit menus and SwiftUI
    /// use the same persisted choice without changing macOS language settings.
    static func locale(for identifier: String) -> Locale {
        configure(identifier)
        return Locale(identifier: resolvedLanguage(identifier))
    }

    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, language: String? = nil, bundle: Bundle? = nil) -> String {
        let root = bundle ?? resourceBundle
        let language = resolvedLanguage(language)
        if let path = root.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) {
            return localized.localizedString(forKey: key, value: key, table: "Localizable")
        }
        return root.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: resolvedLanguage()), arguments: arguments)
    }
}
