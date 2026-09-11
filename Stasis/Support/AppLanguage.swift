import AppKit
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            String(localized: "Follow System")
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .traditionalChinese:
            "繁體中文"
        }
    }

    static var selected: AppLanguage {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let applicationDomain = UserDefaults.standard.persistentDomain(
                forName: bundleIdentifier
              ),
              let language = (applicationDomain["AppleLanguages"] as? [String])?.first
        else {
            return .system
        }

        if language.hasPrefix("zh-Hant") { return .traditionalChinese }
        if language.hasPrefix("zh-Hans") { return .simplifiedChinese }
        if language.hasPrefix("en") { return .english }
        return .system
    }

    static var preferredLanguageIdentifiers: [String] {
        let language = selected
        return language == .system ? Locale.preferredLanguages : [language.rawValue]
    }
}

@MainActor
enum AppLanguageController {
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
        defaults.synchronize()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
