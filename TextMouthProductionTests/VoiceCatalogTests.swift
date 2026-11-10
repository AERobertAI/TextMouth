import AVFoundation
import Combine
import os
import XCTest
@testable import TextMouth

/// The shared voice list (TODO PERF07): the installed voices are listed once,
/// off the main thread, and again only when the system says they changed;
/// Settings and the voice sheet read the list instead of listing voices
/// themselves.
@MainActor
final class VoiceCatalogTests: XCTestCase {

    // MARK: - Listing

    /// Asking for the list twice lists the voices once, off the main thread,
    /// and publishes them with their languages.
    func testTheVoicesAreListedOnceOffTheMainThread() async {
        let lister = CountingVoiceLister(Self.sampleVoices)
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: lister.list)

        catalog.loadIfNeeded()
        catalog.loadIfNeeded()
        await catalog.waitUntilListed()
        catalog.loadIfNeeded()

        XCTAssertEqual(lister.calls, 1)
        XCTAssertEqual(lister.callsOnTheMainThread, 0)
        XCTAssertEqual(catalog.listingCount, 1)
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertEqual(catalog.voices.map(\.identifier), Self.sampleVoices.map(\.identifier))
        XCTAssertEqual(catalog.languages, Set(Self.sampleVoices.map { String($0.language.prefix(2)) }).sorted())
    }

    /// When the system says the installed voices changed, the catalog lists
    /// them again and publishes the new list.
    func testAChangeOfTheInstalledVoicesListsThemAgain() async {
        let center = NotificationCenter()
        let lister = CountingVoiceLister(Self.sampleVoices)
        let catalog = VoiceCatalog(notificationCenter: center, listVoices: lister.list)
        catalog.loadIfNeeded()
        await catalog.waitUntilListed()
        let relisted = expectation(description: "The voices were listed again")
        let watcher = catalog.didList.prefix(1).sink { relisted.fulfill() }
        defer { watcher.cancel() }
        lister.voices = Array(Self.sampleVoices.prefix(1))

        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await fulfillment(of: [relisted], timeout: 5)

        XCTAssertEqual(lister.calls, 2)
        XCTAssertEqual(catalog.listingCount, 2)
        XCTAssertEqual(catalog.voices.map(\.identifier), lister.voices.map(\.identifier))
    }

    /// A listing that never comes back, as the system's does on a machine whose speech service does
    /// not answer (a GitHub runner), must not hold a thread of Swift's concurrency pool: the pool has
    /// one thread for each core, so a listing in it for each core stops every task of the process,
    /// which hung tests in the full suites on GitHub. Here more catalogs than cores each ask
    /// for a listing that waits for the test to let it go, and a task of the pool must still run.
    func testListingsThatNeverComeBackLeaveTheConcurrencyPoolFree() {
        let gate = DispatchSemaphore(value: 0)
        // Each blocked listing is let go (below), and gives up by itself after a minute if the test dies.
        let blocked: @Sendable () -> [AVSpeechSynthesisVoice] = {
            _ = gate.wait(timeout: .now() + 60)
            return []
        }
        let catalogs = (0..<ProcessInfo.processInfo.activeProcessorCount + 2).map { _ in
            VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: blocked)
        }
        defer { for _ in catalogs { gate.signal() } }
        catalogs.forEach { $0.reload() }
        // Give the listings time to start (the run loop turns, so the catalogs' tasks can begin).
        let settle = expectation(description: "The listings had time to start")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.5)

        // A task of the pool, with up to ten seconds to run (the run loop turns while it waits).
        let probeRan = OSAllocatedUnfairLock(initialState: false)
        Task.detached { probeRan.withLock { $0 = true } }
        let deadline = Date().addingTimeInterval(10)
        while !probeRan.withLock({ $0 }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(probeRan.withLock { $0 }, "a task could not run on the concurrency pool while listings were held")
    }

    /// The voices for a language are those whose language starts with its
    /// code; no language, or an empty one, gives every voice.
    func testTheVoicesForALanguageAreThoseOfThatLanguage() async throws {
        let voices = Self.sampleVoices
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: { voices })
        catalog.loadIfNeeded()
        await catalog.waitUntilListed()
        let language = try XCTUnwrap(catalog.languages.first)

        XCTAssertEqual(catalog.voices(forLanguage: nil).count, catalog.voices.count)
        XCTAssertEqual(catalog.voices(forLanguage: "").count, catalog.voices.count)
        XCTAssertFalse(catalog.voices(forLanguage: language).isEmpty)
        XCTAssertTrue(catalog.voices(forLanguage: language).allSatisfy { $0.language.hasPrefix(language) })
        XCTAssertEqual(catalog.voices(forLanguage: "zz"), [])
    }

    /// The installed voices the app offers leave out novelty voices and run
    /// by name, as the voice pickers always listed them.
    func testTheInstalledVoicesLeaveOutNoveltyVoicesAndRunByName() {
        let voices = VoiceCatalog.installedVoices()

        XCTAssertFalse(voices.isEmpty)
        XCTAssertFalse(voices.contains { $0.voiceTraits.contains(.isNoveltyVoice) })
        XCTAssertEqual(voices.map(\.name), voices.map(\.name).sorted())
    }

    // MARK: - Settings

    /// Settings offers the catalog's voices for the language chosen, and a
    /// change of language filters that list without listing voices again.
    func testSettingsOffersTheCatalogsVoicesWithoutListingThem() async throws {
        let lister = CountingVoiceLister(Self.sampleVoices)
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: lister.list)
        catalog.loadIfNeeded()
        await catalog.waitUntilListed()
        let settings = try makeSettings(catalog: catalog)
        let language = try XCTUnwrap(catalog.languages.first)

        settings.selectedLanguage = language
        settings.refreshVoices()
        XCTAssertEqual(settings.availableVoices, catalog.voices(forLanguage: language))
        XCTAssertEqual(settings.availableLanguages, catalog.languages)
        settings.selectedLanguage = ""
        settings.refreshVoices()

        XCTAssertEqual(settings.availableVoices, catalog.voices)
        XCTAssertEqual(lister.calls, 1, "Settings listed the voices")
    }

    /// When the catalog's list arrives after Settings started, as it does at
    /// launch, Settings offers it, and chooses its first voice when no voice
    /// is chosen yet.
    func testSettingsTakesTheListWhenItArrivesAndChoosesADefaultVoice() async throws {
        let voices = Self.sampleVoices
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: { voices })
        let settings = try makeSettings(catalog: catalog)
        settings.selectedLanguage = ""
        settings.observeVoiceCatalog()
        XCTAssertEqual(settings.availableVoices, [])
        XCTAssertEqual(settings.selectedVoiceID, "")

        catalog.loadIfNeeded()
        await catalog.waitUntilListed()

        XCTAssertEqual(settings.availableVoices, catalog.voices)
        XCTAssertEqual(settings.selectedVoiceID, catalog.voices.first?.identifier)
    }

    // MARK: - Launch

    /// A launch whose preferences and config.json name no voice, the
    /// first, lists the voices at once and chooses the first as the
    /// default, saving it, as every launch used to.
    func testTheFirstLaunchListsTheVoicesAtOnceToChooseADefault() throws {
        let lister = CountingVoiceLister(Self.sampleVoices)
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: lister.list)
        let configURL = try makeConfigFileURL()
        let defaults = try isolatedDefaults()
        // Every language, so the first voice listed is the one offered first.
        defaults.set("", forKey: "selectedLanguage")

        let settings = try launchSettings(defaults: defaults, configURL: configURL, catalog: catalog)

        XCTAssertEqual(lister.calls, 1)
        XCTAssertEqual(settings.selectedVoiceID, Self.sampleVoices.first?.identifier)
        XCTAssertEqual(ConfigService(fileURL: configURL).config.selectedVoiceID, Self.sampleVoices.first?.identifier)
    }

    /// Any other launch lists no voices: the catalog lists them later, off
    /// the main thread, and Settings offers them when they arrive, keeping
    /// the voice the preferences name.
    func testALaunchThatNamesAVoiceListsNone() async throws {
        let lister = CountingVoiceLister(Self.sampleVoices)
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: lister.list)
        let defaults = try isolatedDefaults()
        defaults.set("com.example.voice.named", forKey: "selectedVoiceID")
        defaults.set("", forKey: "selectedLanguage")

        let settings = try launchSettings(defaults: defaults, configURL: try makeConfigFileURL(), catalog: catalog)
        XCTAssertEqual(lister.calls, 0, "the launch listed the voices")
        XCTAssertEqual(settings.availableVoices, [])

        catalog.loadIfNeeded()
        await catalog.waitUntilListed()

        XCTAssertEqual(lister.calls, 1)
        XCTAssertEqual(settings.availableVoices, catalog.voices)
        XCTAssertEqual(settings.selectedVoiceID, "com.example.voice.named")
    }

    // MARK: - Fixtures

    /// A Settings model launched the way the app launches it, on `defaults`
    /// and a config.json of its own at `configURL`; its file watcher stops
    /// when the test ends.
    private func launchSettings(defaults: UserDefaults, configURL: URL, catalog: VoiceCatalog) throws -> SettingsViewModel {
        let service = ConfigService(fileURL: configURL)
        addTeardownBlock { service.shutdown() }
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: true,
            userDefaults: defaults,
            configService: service,
            voiceCatalog: catalog
        )
    }

    /// A few of this Mac's own voices, in the catalog's order.
    private static let sampleVoices: [AVSpeechSynthesisVoice] = Array(VoiceCatalog.installedVoices().prefix(4))

    /// A Settings model of this test's own: isolated preferences and
    /// config.json, and `catalog` for its voices.
    private func makeSettings(catalog: VoiceCatalog) throws -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: try isolatedDefaults(),
            configService: ConfigService(fileURL: try makeConfigFileURL()),
            voiceCatalog: catalog
        )
    }
}

/// Lists a fixed set of voices for a catalog and counts the listings, and
/// how many ran on the main thread. Every field is accessed under the lock,
/// so the catalog's background listing and the test can share it.
private final class CountingVoiceLister: @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [AVSpeechSynthesisVoice]
    private var callCount = 0
    private var mainThreadCallCount = 0

    /// A lister of `voices`.
    init(_ voices: [AVSpeechSynthesisVoice]) {
        listed = voices
    }

    /// The voices the next listing gives.
    var voices: [AVSpeechSynthesisVoice] {
        get { lock.withLock { listed } }
        set { lock.withLock { listed = newValue } }
    }

    /// How many listings ran.
    var calls: Int {
        lock.withLock { callCount }
    }

    /// How many listings ran on the main thread.
    var callsOnTheMainThread: Int {
        lock.withLock { mainThreadCallCount }
    }

    /// Lists the voices, as `VoiceCatalog` asks off the main thread.
    var list: @Sendable () -> [AVSpeechSynthesisVoice] {
        { [self] in
            lock.withLock {
                callCount += 1
                if Thread.isMainThread { mainThreadCallCount += 1 }
                return listed
            }
        }
    }
}
