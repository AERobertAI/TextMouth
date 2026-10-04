import Foundation

/// The language transcription uses (FR05), a setting of each user of the
/// app: a BCP 47 locale identifier such as "en-US", kept in the preferences
/// store and mirrored in config.json as `transcriptionLocale`.
///
/// Until one is chosen it is the system's English: English as the system's
/// region writes it, such as "en-GB" on a Mac set to the United Kingdom, so
/// the recognizer spells "colour" as its listener does. A language the
/// recognizer does not support, or whose model is not installed, is
/// reported when a transcription starts (`TranscriptionError`), never
/// replaced by another behind the user's back.
enum TranscriptionLanguage {
    /// The setting in the preferences store, read as a usable identifier:
    /// a stored value that cannot be one, or none at all, reads as the
    /// system's English (`defaultIdentifier`). The settings model mirrors it
    /// in config.json through this definition.
    static let preference = StoredPreference<String>(
        key: "transcriptionLocale",
        read: { store, key in validated(store.object(forKey: key) as? String) ?? defaultIdentifier },
        write: { identifier, store, key in store.set(identifier, forKey: key) }
    )

    /// The language transcription uses until one is chosen: the system's
    /// English (`defaultIdentifier(for:)` of the current locale).
    static var defaultIdentifier: String {
        defaultIdentifier(for: Locale.current)
    }

    /// The English of `system`, a system locale: English as its region
    /// writes it when the system speaks English ("en-AU" for a Mac set to
    /// English in Australia), and otherwise US English, which the recognizer
    /// supports wherever it runs. A region whose English the recognizer does
    /// not support gives way to US English as a transcription starts
    /// (`languagesToTry(in:)`), since nobody chose it.
    static func defaultIdentifier(for system: Locale) -> String {
        guard system.language.languageCode == .english,
              let region = system.region?.identifier,
              validated("en-\(region)") != nil else {
            return "en-US"
        }
        return "en-\(region)"
    }

    /// The languages a transcription asked for in no particular language
    /// tries, in order, given the setting in `store`: the language chosen,
    /// alone, when one was; otherwise the system's English, then US
    /// English when they differ, since nobody chose that region's English
    /// and the recognizer may not support it.
    static func languagesToTry(in store: UserDefaults) -> [String] {
        if let chosen = validated(store.object(forKey: preference.key) as? String) {
            return [chosen]
        }
        let systems = defaultIdentifier
        return systems == "en-US" ? [systems] : [systems, "en-US"]
    }

    /// `raw` as an identifier the setting can hold, or nil when it cannot
    /// be one: a language subtag of two or three letters, then any number
    /// of subtags of letters and digits, one to eight long, each after a
    /// hyphen, as BCP 47 spells them. An underscore, as Foundation spells
    /// "en_GB", is taken for a hyphen; spaces around it are dropped.
    static func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let identifier = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        let subtags = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first, (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count) && subtag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
              })
        else { return nil }
        return identifier
    }

    /// The name of the language `identifier` names, as the system words it
    /// in the user's own language ("English (United Kingdom)"), for the
    /// messages a transcription gives; the identifier itself when the
    /// system has no name for it.
    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
