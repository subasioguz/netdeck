import Foundation

/// Localization. Keys are the English text (development language). Other languages live in
/// `Resources/<code>.lproj/Localizable.strings`. `language` switches instantly, no relaunch needed.
public enum L10n {
    public enum Language: String, CaseIterable, Sendable, Codable, Identifiable {
        case system, en, tr
        // Mac App Store localizations, by code.
        case ar, ca, cs, da, de, el, es, fi, fr, he, hi, hr, hu, indonesian = "id", it, ja, ko, ms, nb, nl, pl, ptBR = "pt-BR", ptPT = "pt-PT", ro, ru, sk, sv, th, uk, vi, zhHans = "zh-Hans", zhHant = "zh-Hant"
        public var id: String { rawValue }

        /// Name shown in the language picker, written in that language.
        public var nativeName: String {
            switch self {
            case .system: return t("System")
            case .en: return "English"
            case .tr: return "T\u{00FC}rk\u{00E7}e"
            default:
                let l = Locale(identifier: rawValue)
                return (l.localizedString(forIdentifier: rawValue) ?? rawValue).capitalized(with: l)
            }
        }
    }

    nonisolated(unsafe) public static var language: Language = .system

    static func bundle(for language: Language = L10n.language) -> Bundle {
        let code: String
        switch language {
        case .system:
            let available = Bundle.module.localizations.filter { $0 != "Base" }
            code = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first ?? "en"
        default: code = language.rawValue
        }
        if let path = Bundle.module.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) { return b }
        return .module
    }

    /// Locale used for number/date formatting that matches the chosen UI language.
    public static var locale: Locale {
        switch language {
        case .system: return .current
        case .en: return Locale(identifier: "en_US")
        case .tr: return Locale(identifier: "tr_TR")
        default: return Locale(identifier: language.rawValue)
        }
    }

    /// Junos commit comments: ASCII only, so they read the same on every console.
    public static func asciiComment(_ s: String) -> String {
        let folded = s
            .replacingOccurrences(of: "\u{0131}", with: "i")   // dotless i
            .replacingOccurrences(of: "\u{0130}", with: "I")   // dotted capital I
            .replacingOccurrences(of: "\u{2192}", with: "->")  // arrow
            .replacingOccurrences(of: "\u{00B7}", with: "-")   // middle dot
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.filter { $0.isASCII })
    }
}

/// Looks up `key` (English text) and formats it with `args` (`%@` for every argument; pass numbers as String).
public func t(_ key: String, _ args: CVarArg...) -> String {
    L10n.translate(key, args, language: L10n.language)
}

extension L10n {
    /// Pure lookup for an explicit language (used by `t` and by tests, which must not touch global state).
    public static func translate(_ key: String, _ args: [CVarArg] = [], language: Language) -> String {
        let format = bundle(for: language).localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? format : String(format: format, locale: locale, arguments: args)
    }
}
