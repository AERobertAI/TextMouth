import Foundation
import Observation
import os

/// The language the interface speaks, and the locale its numbers and dates are written in (FR39). The person chooses
/// System, the language Foundation picks from their languages among the ones the app carries, or one of the languages
/// themselves (`InterfaceLanguageChoice`, kept in the app domain's `AppleLanguages`).
///
/// The state is one immutable `Sendable` value behind a lock, so the picker switches the language with a single swap,
/// and a lookup on any thread reads a whole, consistent state.
///
/// Which locale is in use when: at launch, a chosen language is the system's own per-app language, so Foundation's
/// `Locale.current` already is the language with the system's region, and the state uses it (`launchState`). After a
/// live switch, `Locale.current` still holds the launch's language, so the state builds the locale Foundation would
/// from the next launch on (`locale(for:region:)`); from the next launch Foundation's own is used again.
enum InterfaceLanguage {
    /// The language and locale the interface uses at one moment.
    struct State: Sendable, Equatable {
        /// One of the languages the app carries (`PluralRules.categories`' keys), `en` when the person's are none.
        let language: String
        /// The locale numbers and dates are formatted with. Under System at launch it is `Locale.autoupdatingCurrent`,
        /// which a per-app language setting leaves as the language with the system's region.
        let locale: Locale

        /// Whether the language is written from right to left (Arabic, Hebrew, Persian, Urdu), so that a window's
        /// layout direction and the iPhone's bars follow it.
        var isRightToLeft: Bool {
            Locale.Language(identifier: language).characterDirection == .rightToLeft
        }
    }

    /// The language one task's scope reads in, in place of the app's: bound by tests and by title sets that must read a
    /// text in another language, as `BraillePreferences.tableForImports` is
    /// (`InterfaceLanguage.$scopedLanguage.withValue("es") { ... }`), so concurrent scopes never see each other's
    /// language and nothing global changes.
    @TaskLocal static var scopedLanguage: String? = nil

    /// The state every lookup reads: the scope's language when one is bound, else the app's. Swapped whole by `select`.
    private static let shared = OSAllocatedUnfairLock<State?>(initialState: nil)

    /// What a lookup registers a dependency on, so that a switch runs again every SwiftUI body that looked up a line.
    private static let observation = InterfaceLanguageObservation()

    /// Publishes a switch to the `Commands` structs, which observe it as they observe the front window's kind.
    @MainActor static let observer = InterfaceLanguageObserver()

    /// Posted (on the main thread) after the language in use changed. AppKit code that sets a title once observes it
    /// and sets the title again, so every open window is worded again; only an alert or a file panel already open
    /// keeps its words until it closes.
    static let didChange = Notification.Name("TextMouthInterfaceLanguageDidChange")

    /// The language and locale in use now.
    ///
    /// The read registers a dependency through an `ObservationRegistrar` access, so a SwiftUI body that looked up a
    /// line runs again when the language changes, and nothing else does: focus, selection, and scroll position stay.
    /// A scope's language (tests, title sets) registers nothing, since it never changes.
    static var current: State {
        if let language = scopedLanguage { return state(forScope: language) }
        observation.access()
        return shared.withLock { state in
            if let known = state { return known }
            let made = launchState()
            state = made
            return made
        }
    }

    /// Switches the language in use to `state` in one swap, and tells everything that shows a line: SwiftUI bodies that
    /// looked one up, the menu bar's `Commands`, and AppKit code listening to `didChange`. The picker calls it through
    /// `choose`; scopes that bind `scopedLanguage` do not. Call it on the main thread.
    static func select(_ state: State) {
        // The swap happens between the observation's "will change" and "did change", so a body that re-runs on the
        // first already finds the new state.
        observation.swap { shared.withLock { $0 = state } }
        publishChange()
    }

    /// Tells everything that shows a line to read its text again, with the language unchanged: the person's own lines
    /// changed (FR39). SwiftUI bodies that looked a line up run again, the `Commands` and the windows titled from code
    /// follow, exactly as for a switch of language. Call it on the main thread.
    static func refresh() {
        observation.swap {}
        publishChange()
    }

    /// Tells the observers (the `Commands`' object and `didChange`'s listeners) on the main thread, whichever thread
    /// switched.
    private static func publishChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { observer.publish() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { observer.publish() } }
        }
    }

    // MARK: - Choosing

    /// The picker's call: makes `choice` the person's, in the system's per-app language setting, and switches the
    /// interface to it at once.
    ///
    /// - Parameters:
    ///   - choice: System, or a language the app carries.
    ///   - store: Where the choice is kept: the app's own domain, or the sandbox under hosted tests.
    ///   - region: The region to format numbers and dates in; the system's when nil (and the United States under hosted
    ///     tests, as the scopes do).
    ///   - preferredLanguages: The system's languages after the choice is saved, which System resolves; the system's own
    ///     when nil.
    /// - Returns: The state now in use.
    @discardableResult
    static func choose(
        _ choice: InterfaceLanguageChoice,
        store: InterfaceLanguageStore = InterfaceLanguageStore(),
        region: String? = nil,
        preferredLanguages: [String]? = nil
    ) -> State {
        // Saved first: System's language is read from the system's list once this app's own entry is gone.
        store.save(choice)
        let state = liveState(for: choice, region: region, preferredLanguages: preferredLanguages ?? globalLanguages())
        select(state)
        return state
    }

    /// The state a live switch to `choice` gives: the language, and the locale Foundation would build from the next
    /// launch (`locale(for:region:)`). Under hosted tests System is English with `en_US`, as `systemState` has it.
    static func liveState(
        for choice: InterfaceLanguageChoice,
        hostsTestBundle: Bool = TextMouthRuntime.current.hostsTestBundle,
        region: String? = nil,
        preferredLanguages: [String]
    ) -> State {
        let language: String
        switch choice {
        case .language(let code):
            language = code
        case .system:
            if hostsTestBundle { return State(language: "en", locale: Locale(identifier: "en_US")) }
            language = systemLanguage(preferredLanguages: preferredLanguages)
        }
        let regionCode = region ?? (hostsTestBundle ? "US" : systemRegion())
        return State(language: language, locale: locale(for: language, region: regionCode))
    }

    /// The person's languages as the system keeps them, for System to resolve: the global `AppleLanguages` (this app's own
    /// entry, which the picker writes, is in another domain and never part of it), else `Locale.preferredLanguages`,
    /// where the platform keeps no global list in the app's reach.
    static func globalLanguages() -> [String] {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[InterfaceLanguageStore.key]
        if let list = global as? [String], !list.isEmpty { return list }
        return Locale.preferredLanguages
    }

    /// The language System gives for `preferredLanguages`: Foundation's own choice among the bundle's languages
    /// (`localizations`, the bundle's own when nil), the same matching `Bundle.main.preferredLocalizations` makes at launch,
    /// from an explicit list because the bundle keeps its answer from launch. English when none matches: English leads the
    /// list when the bundle's languages are not given, so it is what no match falls back to.
    static func systemLanguage(preferredLanguages: [String], localizations: [String]? = nil) -> String {
        let bundled = (localizations ?? Bundle.main.localizations).filter { $0 != "Base" } // l10n: no (the bundle's name for its language-neutral resources)
        let carried = bundled.isEmpty ? ["en"] + PluralRules.categories.keys.filter { $0 != "en" }.sorted() : bundled
        return resolve(Bundle.preferredLocalizations(from: carried, forPreferences: preferredLanguages).first)
    }

    /// The system's region code (`US`), the United States when the system has none.
    static func systemRegion(locale: Locale = .autoupdatingCurrent) -> String {
        locale.region?.identifier ?? "US"
    }

    // MARK: - Launch

    /// The state at the first lookup: the stored choice's language, else System's. A chosen language is the system's
    /// per-app language from this launch, so Foundation's own locale (`currentLocale`) already is that language with the
    /// system's region; under hosted tests, where nothing follows the Mac, a scope's locale stands in for it.
    static func launchState(
        choice: InterfaceLanguageChoice = InterfaceLanguageStore().choice(),
        hostsTestBundle: Bool = TextMouthRuntime.current.hostsTestBundle,
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations,
        currentLocale: Locale = .autoupdatingCurrent
    ) -> State {
        switch choice {
        case .system:
            return systemState(hostsTestBundle: hostsTestBundle, preferredLocalizations: preferredLocalizations, currentLocale: currentLocale)
        case .language(let code):
            return hostsTestBundle ? state(forScope: code) : State(language: code, locale: currentLocale)
        }
    }

    // MARK: - System

    /// The state under System. In a process where XCTest runs a test bundle it is English formatted with `en_US`, so the
    /// suite's interface text does not follow the language of the Mac it runs on. The iPhone app a UI test launched is
    /// sandboxed but not such a process: it follows its launch language as the app does. Otherwise it is the first language of
    /// `Bundle.main.preferredLocalizations` that the app carries, formatted with `Locale.autoupdatingCurrent`: it follows
    /// a change of region while the app runs, as Apple's `String(localized:)` does by reading `Locale.current` at every
    /// call, so a number is written the same way by both.
    static func systemState(
        hostsTestBundle: Bool = TextMouthRuntime.current.hostsTestBundle,
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations,
        currentLocale: Locale = .autoupdatingCurrent
    ) -> State {
        if hostsTestBundle { return State(language: "en", locale: Locale(identifier: "en_US")) }
        return State(language: resolve(preferredLocalizations.first), locale: currentLocale)
    }

    /// The language the app carries that `identifier` names, `en` when it names none of them. The bundle already
    /// answers with one of its own localizations, so an exact match is the usual case; the rest tolerate the forms
    /// the system sometimes gives (`pt`, `zh`, `iw`, `zh_Hant`).
    static func resolve(_ identifier: String?) -> String {
        guard let identifier else { return "en" }
        return carriedLanguage(identifier) ?? "en"
    }

    /// The language the app carries that `identifier` names, nil when it names none of them: the rules of `resolve`
    /// without its English default, so a stored value the app does not carry can read as System.
    static func carriedLanguage(_ identifier: String) -> String? {
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
        return carried.first { $0.lowercased() == base }
    }

    // MARK: - Scopes

    /// The state a scope's language gives: that language, formatted in the language with the United States as its
    /// region, as the hosted tests' own comparisons do (`Locale(identifier: "es_US")`). Under the language the system
    /// already speaks, the same.
    static func state(forScope language: String) -> State {
        State(language: language, locale: locale(forScope: language))
    }

    /// The locale a scope formats `language` with: the rule of a live switch, with the United States as the region, as
    /// the hosted tests' own comparisons do (`Locale(identifier: "es_US")`).
    static func locale(forScope language: String) -> Locale {
        locale(for: language, region: "US")
    }

    /// The locale Foundation builds for `language` with the system's `region`, which a live switch uses until the next
    /// launch (from then on Foundation's own is used): the language without its region (`pt-BR` is `pt`; a script such
    /// as `zh-Hans` stays), the region, and Latin digits for Persian outside Iran and Afghanistan.
    ///
    /// Two cases differ from Foundation's own until the next launch: Persian in Saudi Arabia keeps the region's
    /// digits there, and Urdu in Iran keeps Persian digits there. This rule writes Latin digits for the first, and
    /// leaves the second to ICU's default for `ur_IR`.
    static func locale(for language: String, region: String) -> Locale {
        let base = language == "pt-BR" ? "pt" : language
        let persianRegions: Set<String> = ["IR", "AF"]
        let latinDigits = language == "fa" && !persianRegions.contains(region.uppercased())
        return Locale(identifier: base + "_" + region + (latinDigits ? "@numbers=latn" : ""))
    }
}

// MARK: - Observation

/// What a lookup registers a dependency on: one value that changes when the language does. Hand-written rather than
/// `@Observable`, since nothing is stored: the registrar alone carries the reads and the change.
final class InterfaceLanguageObservation: Observable, Sendable {
    private let registrar = ObservationRegistrar()

    /// The key path the reads and the change name. It holds nothing; only the registration matters.
    var revision: Int { 0 }

    /// Registers the running SwiftUI body's (or any observation's) dependency on the language. Cheap when nothing is
    /// observing.
    func access() {
        registrar.access(self, keyPath: \.revision)
    }

    /// Runs `change` between the "will change" and "did change" of every dependency.
    func swap(_ change: () -> Void) {
        registrar.withMutation(of: self, keyPath: \.revision, change)
    }
}

/// Publishes a switch of language to what observes an `ObservableObject`: the menu bar's `Commands`, as they observe the
/// front window's kind. It also posts `InterfaceLanguage.didChange`.
@MainActor
final class InterfaceLanguageObserver: ObservableObject {
    /// Tells the observers that the language changed.
    func publish() {
        objectWillChange.send()
        NotificationCenter.default.post(name: InterfaceLanguage.didChange, object: nil)
    }
}
