import Foundation
import os

/// The language the interface speaks, and the locale its numbers and dates are written in (FR39). This phase has one
/// choice, System: the language Foundation picks from the person's languages among the ones the app carries.
///
/// The state is one immutable `Sendable` value behind a lock, so the picker (a later phase) can switch the language
/// with a single swap, and a lookup on any thread reads a whole, consistent state.
enum InterfaceLanguage {
    /// The language and locale the interface uses at one moment.
    struct State: Sendable, Equatable {
        /// One of the languages the app carries (`PluralRules.categories`' keys), `en` when the person's are none.
        let language: String
        /// The locale numbers and dates are formatted with. Under System it is `Locale.current`, which a per-app
        /// language setting leaves as the language with the system's region.
        let locale: Locale
    }

    /// The language a test uses in place of the system's: bound for one test's scope, as
    /// `BraillePreferences.tableForImports` is (`InterfaceLanguage.$testLanguage.withValue("es") { ... }`), so
    /// concurrent tests never see each other's language and nothing global changes.
    @TaskLocal static var testLanguage: String? = nil

    /// The state every lookup reads: the test's language when one is bound, else the app's. Swapped whole by `select`.
    private static let shared = OSAllocatedUnfairLock<State?>(initialState: nil)

    /// The language and locale in use now.
    ///
    /// Live switching (a later phase) adds its observation here: a read through an `ObservationRegistrar` access, so a
    /// SwiftUI body that looked up a line runs again when the language changes.
    static var current: State {
        if let language = testLanguage { return state(forTesting: language) }
        return shared.withLock { state in
            if let known = state { return known }
            let made = systemState()
            state = made
            return made
        }
    }

    /// Switches the language in use to `state` in one swap. The picker calls it; tests that bind `testLanguage` do not.
    static func select(_ state: State) {
        shared.withLock { $0 = state }
    }

    // MARK: - System

    /// The state under System. In a process that hosts tests it is English formatted with `en_US`, so the suite's
    /// interface text does not follow the language of the Mac it runs on; otherwise it is the first language of
    /// `Bundle.main.preferredLocalizations` that the app carries, formatted with `Locale.current`.
    static func systemState(
        isHostedTest: Bool = TextMouthRuntime.current.isHostedTest,
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations,
        currentLocale: Locale = .current
    ) -> State {
        if isHostedTest { return State(language: "en", locale: Locale(identifier: "en_US")) }
        return State(language: resolve(preferredLocalizations.first), locale: currentLocale)
    }

    /// The language the app carries that `identifier` names, `en` when it names none of them. The bundle already
    /// answers with one of its own localizations, so an exact match is the usual case; the rest tolerate the forms
    /// the system sometimes gives (`pt`, `zh`, `iw`, `zh_Hant`).
    static func resolve(_ identifier: String?) -> String {
        guard let identifier else { return "en" }
        let dashed = identifier.replacingOccurrences(of: "_", with: "-")
        let carried = PluralRules.categories.keys
        if let exact = carried.first(where: { $0.lowercased() == dashed.lowercased() }) { return exact }
        let lowered = dashed.lowercased()
        // The language alone, by the bundle's own choices: Portuguese is the Brazilian pack, and Chinese is the
        // simplified one unless the script or region says traditional.
        if lowered.hasPrefix("zh") {
            let traditional = ["hant", "tw", "hk", "mo"].contains { lowered.contains($0) }
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        let base = String(lowered.prefix { $0 != "-" })
        if base == "pt" { return "pt-BR" }
        if base == "iw" { return "he" }
        return carried.first { $0.lowercased() == base } ?? "en"
    }

    // MARK: - Tests

    /// The state a test's language gives: that language, formatted in the language with the United States as its
    /// region, as the hosted tests' own comparisons do (`Locale(identifier: "es_US")`). Under the language the system
    /// already speaks, the same.
    static func state(forTesting language: String) -> State {
        State(language: language, locale: locale(forTesting: language))
    }

    /// The locale a test formats `language` with: the language without its region (`pt-BR` is `pt`; a script such as
    /// `zh-Hans` stays) and the United States as the region; Persian with Latin digits, as the system gives it
    /// outside Iran.
    static func locale(forTesting language: String) -> Locale {
        let base = language == "pt-BR" ? "pt" : language
        return Locale(identifier: base + "_US" + (language == "fa" ? "@numbers=latn" : ""))
    }
}
