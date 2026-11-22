import Foundation

/// The person's choice of interface language (FR39): System, or one of the languages the app carries.
///
/// The choice lives in the app domain's own `AppleLanguages`, the key the system's per-app language setting writes
/// (System Settings on the Mac, Settings on the iPhone), so the two always agree: a language writes `[code]`, and System
/// removes the key. A value the app does not carry reads as System.
enum InterfaceLanguageChoice: Hashable, Sendable {
    /// Follow the system: the language Foundation picks from the person's languages among the ones the app carries.
    case system
    /// One of the languages the app carries (`PluralRules.categories`' keys), by its code.
    case language(String)

    /// The choice a stored `AppleLanguages` list stands for: its first entry when the app carries that language,
    /// otherwise System. Only the first entry counts, because the list is in priority order and System's own pick (the
    /// first language the app carries, which Foundation chooses) is what the interface would show for a list whose first
    /// entry the app does not carry.
    init(storedLanguages: [String]?) {
        if let first = storedLanguages?.first, let carried = InterfaceLanguage.carriedLanguage(first) {
            self = .language(carried)
        } else {
            self = .system
        }
    }

    /// What to store for this choice: `[code]` for a language, nil (remove the key) for System.
    var storedLanguages: [String]? {
        switch self {
        case .system: return nil
        case .language(let code): return [code]
        }
    }
}

/// Where the choice is kept: one preferences domain's `AppleLanguages`.
///
/// The domain is injected. The app uses its own domain in the standard preferences; a process hosting tests uses the
/// sandboxed store `TextMouthRuntime` made for it, so no test ever writes the real app domain, whose `AppleLanguages`
/// the person's installed app reads.
///
/// Reads go through `persistentDomain(forName:)` of that one domain, never `object(forKey:)`, which would also answer
/// with the global language list or a launch argument.
struct InterfaceLanguageStore {
    /// The key the system's per-app language setting writes.
    static let key = "AppleLanguages"

    /// The preferences the domain is in.
    let defaults: UserDefaults
    /// The name of the domain: the bundle's identifier for the app, a file path for a sandboxed store.
    let domain: String

    /// The store `runtime` calls for: the app's own domain in the standard preferences, or, under hosted tests, the
    /// sandbox's own store. `bundleIdentifier` is the app's, and is only read for the standard preferences.
    init(runtime: TextMouthRuntime = .current, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        defaults = runtime.preferences
        if let file = runtime.preferencesFile {
            // `TextMouthRuntime.sandboxedPreferences` names its suite by the file's path without the extension.
            domain = file.deletingPathExtension().path
        } else {
            domain = bundleIdentifier ?? ""
        }
    }

    /// A store over `defaults`' domain `domain`, for tests.
    init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults
        self.domain = domain
    }

    /// The stored language list of this domain, nil when it holds none.
    func storedLanguages() -> [String]? {
        defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
    }

    /// The choice stored now.
    func choice() -> InterfaceLanguageChoice {
        InterfaceLanguageChoice(storedLanguages: storedLanguages())
    }

    /// Stores `choice`: a language writes `[code]`, System removes the key.
    func save(_ choice: InterfaceLanguageChoice) {
        if let languages = choice.storedLanguages {
            defaults.set(languages, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
