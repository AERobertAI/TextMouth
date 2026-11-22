import Combine
import Observation
import XCTest
import os
@testable import TextMouth

extension InterfaceLanguageStore {
    /// A store over a sandboxed preferences store of a test.
    init(_ sandbox: SandboxedPreferences) {
        self.init(defaults: sandbox.defaults, domain: sandbox.file.deletingPathExtension().path)
    }
}

/// Tests of the person's choice of interface language (FR39, the picker's phase): the store in `AppleLanguages`, the
/// locale a live switch builds, the state at launch, and the switch itself.
///
/// Every test that switches puts System back when it ends, so no later test runs in another language, and every store
/// is a sandboxed one: no test writes the real app domain, whose `AppleLanguages` the installed app reads.
@MainActor
final class InterfaceLanguageChoiceTests: XCTestCase {
    // MARK: - Support

    /// A new, empty sandboxed store for this test, discarded when the test ends.
    private func makeStore() -> InterfaceLanguageStore {
        let preferences = SandboxedPreferences("languageChoice")
        addTeardownBlock { preferences.discard() }
        return InterfaceLanguageStore(preferences)
    }

    /// A new, empty sandboxed store for a test that switches the language, which puts System back when the test ends,
    /// whatever it switched to, before the store is discarded.
    private func makeStoreRestoringSystem() -> InterfaceLanguageStore {
        let preferences = SandboxedPreferences("languageChoice")
        addTeardownBlock {
            InterfaceLanguage.choose(.system, store: InterfaceLanguageStore(preferences))
            preferences.discard()
        }
        return InterfaceLanguageStore(preferences)
    }

    // MARK: - The store

    func testAnEmptyStoreIsSystem() {
        XCTAssertEqual(makeStore().choice(), .system)
        XCTAssertNil(makeStore().storedLanguages())
    }

    func testALanguageWritesItsCodeAlone() {
        let store = makeStore()
        store.save(.language("es"))
        XCTAssertEqual(store.storedLanguages(), ["es"])
        XCTAssertEqual(store.choice(), .language("es"))
        store.save(.language("zh-Hant"))
        XCTAssertEqual(store.storedLanguages(), ["zh-Hant"])
        XCTAssertEqual(store.choice(), .language("zh-Hant"))
    }

    func testSystemRemovesTheKey() {
        let store = makeStore()
        store.save(.language("ar"))
        store.save(.system)
        XCTAssertNil(store.storedLanguages())
        XCTAssertNil(store.defaults.persistentDomain(forName: store.domain)?[InterfaceLanguageStore.key])
        XCTAssertEqual(store.choice(), .system)
    }

    /// A choice made in System Settings or the iPhone's Settings (the system writes the key itself) shows in the picker.
    func testTheSystemsOwnSettingIsTheChoice() {
        let store = makeStore()
        store.defaults.set(["pt-BR"], forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .language("pt-BR"))
        store.defaults.set(["es-419"], forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .language("es"), "the system writes a region with the language, which the app carries as its language")
    }

    func testAValueTheAppDoesNotCarryIsSystem() {
        let store = makeStore()
        store.defaults.set(["xx"], forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .system)
        store.defaults.set(["nb", "es"], forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .system, "only the first entry counts: the list is in priority order")
        store.defaults.set([] as [String], forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .system)
        store.defaults.set("es", forKey: InterfaceLanguageStore.key)
        XCTAssertEqual(store.choice(), .system, "not a list")
    }

    func testEveryCarriedLanguageRoundTripsThroughTheStore() {
        let store = makeStore()
        for language in PluralRules.categories.keys {
            store.save(.language(language))
            XCTAssertEqual(store.choice(), .language(language))
        }
    }

    /// The store reads its own domain, never the global list or a launch argument: `object(forKey:)` of a standard
    /// store would answer with those.
    func testTheStoreReadsItsOwnDomainOnly() {
        let store = makeStore()
        XCTAssertNotNil(Locale.preferredLanguages.first, "the Mac has languages, which the store must not read")
        XCTAssertEqual(store.choice(), .system)
    }

    // MARK: - The real domain

    /// A hosted run never touches the real domain of the app's bundle identifier: the process's store is a sandboxed
    /// one, and a switch through it leaves the real `AppleLanguages` exactly as it was.
    func testAHostedRunLeavesTheRealDomainUntouched() throws {
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let realKey = InterfaceLanguageStore.key
        let before = UserDefaults.standard.persistentDomain(forName: bundleIdentifier)?[realKey] as? [String]

        let processStore = InterfaceLanguageStore()
        XCTAssertNotEqual(processStore.domain, bundleIdentifier, "the hosted process's store is not the app's domain")
        XCTAssertTrue(processStore.domain.contains(TextMouthRuntime.sandboxNamePrefix), "it is in the sandbox: \(processStore.domain)")
        XCTAssertFalse(processStore.defaults === UserDefaults.standard)

        addTeardownBlock { InterfaceLanguage.choose(.system) }
        InterfaceLanguage.choose(.language("es"))
        XCTAssertEqual(processStore.storedLanguages(), ["es"], "the sandbox took the write")
        InterfaceLanguage.choose(.language("ar"))
        InterfaceLanguage.choose(.system)
        XCTAssertNil(processStore.storedLanguages())

        let after = UserDefaults.standard.persistentDomain(forName: bundleIdentifier)?[realKey] as? [String]
        XCTAssertEqual(after, before, "the real domain's AppleLanguages is as it was")
    }

    // MARK: - The locale of a live switch

    func testTheLocaleKeepsTheLanguageAndTheSystemsRegion() {
        XCTAssertEqual(InterfaceLanguage.locale(for: "es", region: "US").identifier, "es_US")
        XCTAssertEqual(InterfaceLanguage.locale(for: "es", region: "MX").identifier, "es_MX")
        XCTAssertEqual(InterfaceLanguage.locale(for: "de", region: "CH").identifier, "de_CH")
    }

    func testPortugueseLosesItsRegionAndTakesTheSystems() {
        let locale = InterfaceLanguage.locale(for: "pt-BR", region: "PT")
        XCTAssertEqual(locale.identifier, "pt_PT")
        XCTAssertEqual(locale.language.languageCode?.identifier, "pt")
    }

    func testChineseKeepsItsScript() {
        let simplified = InterfaceLanguage.locale(for: "zh-Hans", region: "TW")
        XCTAssertEqual(simplified.language.languageCode?.identifier, "zh")
        XCTAssertTrue(simplified.identifier.hasPrefix("zh-Hans"), simplified.identifier)
        XCTAssertEqual(simplified.region?.identifier, "TW")
        let traditional = InterfaceLanguage.locale(for: "zh-Hant", region: "CN")
        XCTAssertTrue(traditional.identifier.hasPrefix("zh-Hant"), traditional.identifier)
        XCTAssertEqual(traditional.region?.identifier, "CN")
    }

    /// Persian writes Latin digits outside Iran and Afghanistan, as Foundation does for a per-app Persian.
    func testPersianHasLatinDigitsOutsideIranAndAfghanistan() {
        for region in ["US", "GB", "DE", "EG"] {
            XCTAssertEqual(InterfaceLanguage.locale(for: "fa", region: region).numberingSystem.identifier, "latn", region)
        }
        for region in ["IR", "AF", "ir"] {
            XCTAssertNotEqual(InterfaceLanguage.locale(for: "fa", region: region).numberingSystem.identifier, "latn", region)
        }
    }

    /// The two cases the design records as differing from Foundation's own locale until the next launch: this rule's
    /// answer is pinned, so a change to it shows. (Foundation keeps the region's digits for Persian in Saudi Arabia and
    /// Persian digits for Urdu in Iran; from the next launch, Foundation's own locale is used and the difference is gone.)
    func testTheTwoKnownDifferencesFromFoundationAreRecorded() {
        XCTAssertEqual(InterfaceLanguage.locale(for: "fa", region: "SA").numberingSystem.identifier, "latn")
        XCTAssertEqual(InterfaceLanguage.locale(for: "ur", region: "IR").identifier, "ur_IR")
        XCTAssertEqual(InterfaceLanguage.locale(for: "ur", region: "IR").language.languageCode?.identifier, "ur")
    }

    /// A scope's locale is the same rule with the United States as the region, so the tests' own comparisons stand.
    func testAScopesLocaleIsTheRuleWithTheUnitedStates() {
        for language in PluralRules.categories.keys {
            XCTAssertEqual(InterfaceLanguage.locale(forScope: language), InterfaceLanguage.locale(for: language, region: "US"), language)
        }
    }

    // MARK: - Right to left

    func testTheRightToLeftLanguages() {
        let rightToLeft = PluralRules.categories.keys.filter { InterfaceLanguage.state(forScope: $0).isRightToLeft }
        XCTAssertEqual(Set(rightToLeft), ["ar", "fa", "he", "ur"])
    }

    // MARK: - The state a choice gives

    func testALiveSwitchToALanguage() {
        let state = InterfaceLanguage.liveState(for: .language("es"), hostsTestBundle: false, region: "MX", preferredLanguages: ["en-US"])
        XCTAssertEqual(state, InterfaceLanguage.State(language: "es", locale: Locale(identifier: "es_MX")))
    }

    func testALiveSwitchToSystemResolvesTheSystemsLanguages() {
        func language(_ preferred: [String]) -> String {
            InterfaceLanguage.liveState(for: .system, hostsTestBundle: false, region: "US", preferredLanguages: preferred).language
        }
        XCTAssertEqual(language(["es-419", "en"]), "es")
        XCTAssertEqual(language(["zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(language(["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(language(["fr-CA"]), "fr")
        XCTAssertEqual(language(["xx", "ru"]), "ru", "the first language the app carries")
        XCTAssertEqual(language(["xx"]), "en", "none carried gives English")
    }

    /// The design's measured cases of Foundation's own matching among the 25 languages, through `systemLanguage`.
    func testSystemResolvesAsFoundationDoesAmongTheBundlesLanguages() {
        let bundled = ["en"] + PluralRules.categories.keys.filter { $0 != "en" }.sorted()
        func language(_ preferred: [String]) -> String {
            InterfaceLanguage.systemLanguage(preferredLanguages: preferred, localizations: bundled)
        }
        XCTAssertEqual(language(["zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(language(["zh-HK"]), "zh-Hant")
        XCTAssertEqual(language(["zh-CN"]), "zh-Hans")
        XCTAssertEqual(language(["pt-PT"]), "pt-BR")
        XCTAssertEqual(language(["es-419"]), "es")
        XCTAssertEqual(language(["es-MX"]), "es")
        XCTAssertEqual(language(["iw"]), "he")
        XCTAssertEqual(language(["nb"]), "en", "not carried: the development region")
        XCTAssertEqual(language(["nb", "sv"]), "sv")
        XCTAssertEqual(language(["ca", "es"]), "es")
        XCTAssertEqual(language(["hi-Latn"]), "en")
    }

    func testUnderHostedTestsSystemIsEnglishWithTheUnitedStates() {
        let state = InterfaceLanguage.liveState(for: .system, hostsTestBundle: true, region: "FR", preferredLanguages: ["es"])
        XCTAssertEqual(state, InterfaceLanguage.State(language: "en", locale: Locale(identifier: "en_US")))
    }

    func testUnderHostedTestsALanguageUsesTheUnitedStatesUnlessToldOtherwise() {
        let state = InterfaceLanguage.liveState(for: .language("fa"), hostsTestBundle: true, preferredLanguages: [])
        XCTAssertEqual(state, InterfaceLanguage.State(language: "fa", locale: InterfaceLanguage.locale(forScope: "fa")))
    }

    // MARK: - The launch

    /// A chosen language gives its state at once, with Foundation's own locale, which is the per-app language's.
    func testTheLaunchReadsTheChoiceBeforeTheFirstLookup() {
        let store = makeStore()
        store.save(.language("ar"))
        let egypt = Locale(identifier: "ar_EG")
        let state = InterfaceLanguage.launchState(choice: store.choice(), hostsTestBundle: false, preferredLocalizations: ["en"], currentLocale: egypt)
        XCTAssertEqual(state, InterfaceLanguage.State(language: "ar", locale: egypt))
    }

    func testTheLaunchUnderSystemIsTodaysSystemState() {
        let locale = Locale(identifier: "es_US")
        let launch = InterfaceLanguage.launchState(choice: .system, hostsTestBundle: false, preferredLocalizations: ["es", "en"], currentLocale: locale)
        let today = InterfaceLanguage.systemState(hostsTestBundle: false, preferredLocalizations: ["es", "en"], currentLocale: locale)
        XCTAssertEqual(launch, today)
        let hosted = InterfaceLanguage.launchState(choice: .system, hostsTestBundle: true, preferredLocalizations: ["es"], currentLocale: locale)
        XCTAssertEqual(hosted, InterfaceLanguage.State(language: "en", locale: Locale(identifier: "en_US")))
    }

    func testTheLaunchUnderHostedTestsGivesAChosenLanguageTheScopesLocale() {
        let state = InterfaceLanguage.launchState(choice: .language("es"), hostsTestBundle: true, preferredLocalizations: ["en"], currentLocale: Locale(identifier: "en_GB"))
        XCTAssertEqual(state, InterfaceLanguage.state(forScope: "es"))
    }

    // MARK: - The switch

    /// A switch swaps one whole state: language and locale together, and lookups follow at once; back to System, English.
    func testASwitchSwapsOneWholeState() {
        let store = makeStoreRestoringSystem()
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
        XCTAssertEqual(MenuWording.bookmarks, "Bookmarks")

        let spanish = InterfaceLanguage.choose(.language("es"), store: store, region: "US")
        XCTAssertEqual(InterfaceLanguage.current, spanish)
        XCTAssertEqual(spanish, InterfaceLanguage.State(language: "es", locale: Locale(identifier: "es_US")))
        XCTAssertEqual(MenuWording.bookmarks, "Marcadores")
        XCTAssertEqual(store.choice(), .language("es"))

        InterfaceLanguage.choose(.system, store: store)
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
        XCTAssertEqual(MenuWording.bookmarks, "Bookmarks")
        XCTAssertEqual(store.choice(), .system)
    }

    /// Without a choice made, System's behavior is today's: English under hosted tests, and the suite's English
    /// assertions pass unchanged.
    func testNobodyWhoNeverOpensThePickerSeesAChange() {
        XCTAssertEqual(InterfaceLanguage.current, InterfaceLanguage.systemState())
        XCTAssertEqual(InterfaceLanguageStore().choice(), .system, "the hosted process's store holds no choice")
    }

    // MARK: - What a switch tells

    /// A body that looked up a line depends on the language: a switch runs its observer, once.
    func testASwitchRunsTheObserversOfALookup() {
        let store = makeStoreRestoringSystem()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = MenuWording.bookmarks
        } onChange: {
            runs.withLock { $0 += 1 }
        }
        XCTAssertEqual(runs.withLock { $0 }, 0, "nothing changed yet")
        InterfaceLanguage.choose(.language("es"), store: store)
        XCTAssertEqual(runs.withLock { $0 }, 1)
    }

    /// What reads another language for its own scope depends on nothing: a switch runs no observer of it.
    func testAScopedLookupIsNotObserved() {
        let store = makeStoreRestoringSystem()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        InterfaceLanguage.$scopedLanguage.withValue("es") {
            withObservationTracking {
                _ = MenuWording.bookmarks
            } onChange: {
                runs.withLock { $0 += 1 }
            }
        }
        InterfaceLanguage.choose(.language("de"), store: store)
        XCTAssertEqual(runs.withLock { $0 }, 0)
    }

    /// The notification AppKit code listens to is posted on the main thread, after the state is swapped.
    func testASwitchPostsTheNotificationAfterTheSwap() {
        let store = makeStoreRestoringSystem()
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let token = NotificationCenter.default.addObserver(forName: InterfaceLanguage.didChange, object: nil, queue: nil) { _ in
            seen.withLock { $0.append(InterfaceLanguage.current.language) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        InterfaceLanguage.choose(.language("fr"), store: store)
        XCTAssertEqual(seen.withLock { $0 }, ["fr"], "one notification, and the state it announces is already in use")
    }

    /// The `Commands` structs observe an `ObservableObject`: it publishes on a switch.
    func testASwitchPublishesToTheCommandsObserver() {
        let store = makeStoreRestoringSystem()
        let published = OSAllocatedUnfairLock(initialState: 0)
        let subscription = InterfaceLanguage.observer.objectWillChange.sink { published.withLock { $0 += 1 } }
        defer { subscription.cancel() }
        InterfaceLanguage.choose(.language("it"), store: store)
        XCTAssertEqual(published.withLock { $0 }, 1)
    }

    // MARK: - Formatters

    /// A figure is written with the interface language's grouping, not the system's region's.
    func testFiguresFollowTheInterfaceLanguage() {
        let store = makeStoreRestoringSystem()
        XCTAssertEqual(1_234_567.interfaceFormatted(), "1,234,567")
        // After a live switch the locale keeps the system's region, so the region decides the grouping: a German interface
        // on a Mac in Germany groups with points, and on a Mac in the United States with commas, as Foundation does.
        InterfaceLanguage.choose(.language("de"), store: store, region: "DE")
        XCTAssertEqual(1_234_567.interfaceFormatted(), "1.234.567")
        XCTAssertEqual(Int64(12_345).interfaceFormatted(), "12.345")
        XCTAssertEqual(ArchiveFigures.count(12_345), "12.345")
        InterfaceLanguage.choose(.language("de"), store: store, region: "US")
        XCTAssertEqual(1_234_567.interfaceFormatted(), "1,234,567")
    }

    /// A date and a list are written in the interface language: its month names and its "and".
    func testDatesAndListsFollowTheInterfaceLanguage() {
        // Noon UTC in mid-June: the same month and year in every time zone.
        let date = Date(timeIntervalSince1970: 1_781_524_800)
        let english = date.interfaceFormatted(date: .long, time: .omitted)
        XCTAssertTrue(english.contains("June"), english)
        InterfaceLanguage.$scopedLanguage.withValue("es") {
            let spanish = date.interfaceFormatted(date: .long, time: .omitted)
            XCTAssertTrue(spanish.contains("junio"), spanish)
            XCTAssertEqual(CountWording.list(["a", "b", "c"]), "a, b y c")
        }
        XCTAssertEqual(CountWording.list(["a", "b", "c"]), "a, b, and c")
    }
}
