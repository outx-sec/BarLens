import Foundation

/// Supported UI languages in BarLens.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en     = "en"
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }
    }

    var resolvedIsEnglish: Bool {
        switch self {
        case .en:
            return true
        case .zhHans:
            return false
        case .system:
            guard let first = Locale.preferredLanguages.first?.lowercased() else {
                return true
            }
            return !first.hasPrefix("zh")
        }
    }
}

/// Lightweight bilingual localization helper (`简体中文` / `English`).
enum L10n {
    static var isEnglish: Bool {
        Defaults.appLanguage.resolvedIsEnglish
    }

    @inline(__always)
    static func tr(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}

@inline(__always)
func tr(_ zh: String, _ en: String) -> String {
    L10n.tr(zh, en)
}
