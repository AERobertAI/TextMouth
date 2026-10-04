import XCTest
@testable import TextMouth

/// Playback settings' Transcription group (FR05): the language pop-up,
/// listing the languages the recognizer supports by name, each marked
/// installed or needing a download, and the "Offer to transcribe after
/// importing an audiobook" checkbox, off until turned on; both mirrored in
/// config.json. Every language list here is scripted: nothing asks this
/// Mac's recognizer, and nothing downloads.
@MainActor
final class TranscriptionSettingsTests: XCTestCase {

    // MARK: - The Offer After an Import

    /// The offer is off until it is turned on. Turning it on in settings
    /// announces the change and saves it to config.json; an edit of
    /// config.json turning it off reaches the setting and is announced too.
    func testTheOfferIsOffUntilTurnedOnAndFollowsConfigJSON() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        var announced = 0
        let subscription = settings.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }

        XCTAssertFalse(settings.offerTranscriptionAfterImport, "the offer is on before anyone turned it on")
        XCTAssertEqual(TranscriptionPreferences.offerAfterImport.key, "offerTranscriptionAfterImport")
        settings.offerTranscriptionAfterImport = true
        service.flushScheduledSave()

        XCTAssertGreaterThan(announced, 0, "turning it on announced nothing")
        XCTAssertEqual(defaults.object(forKey: "offerTranscriptionAfterImport") as? Bool, true)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["offerTranscriptionAfterImport"] as? Bool, true)

        let before = announced
        var edit = service.config
        edit.offerTranscriptionAfterImport = false
        settings.applyConfigChanges(edit)

        XCTAssertFalse(settings.offerTranscriptionAfterImport)
        XCTAssertGreaterThan(announced, before, "the edit of config.json announced nothing")
    }

    /// The language chosen in settings is saved to the store and to
    /// config.json; an edit of config.json reaches the pop-up and is
    /// announced; a choice that cannot be a language changes nothing.
    func testTheLanguageFollowsSettingsAndConfigJSON() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        var announced = 0
        let subscription = settings.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }
        let chosen = TranscriptFixtures.languageOtherThanTheDefault

        settings.transcriptionLanguage = chosen
        service.flushScheduledSave()

        XCTAssertEqual(settings.transcriptionLanguage, chosen)
        XCTAssertEqual(defaults.string(forKey: "transcriptionLocale"), chosen)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["transcriptionLocale"] as? String, chosen)

        settings.transcriptionLanguage = "not a language at all"
        XCTAssertEqual(settings.transcriptionLanguage, chosen, "a choice that cannot be a language was taken")

        let before = announced
        var edit = service.config
        edit.transcriptionLocale = "en-ZA"
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.transcriptionLanguage, "en-ZA")
        XCTAssertGreaterThan(announced, before, "the edit of config.json announced nothing")
    }

    // MARK: - The Language Pop-Up

    /// The pop-up lists every language the recognizer supports, by name,
    /// each marked installed or needing a download, in the order of their
    /// names; a setting the recognizer does not support comes first, marked
    /// so, and nothing is said of this Mac.
    func testThePopUpMarksEachLanguageInstalledOrNeedingDownload() async {
        let choices = TranscriptionLanguageChoices(
            systemSupport: { .available },
            supportedLocales: { [Locale(identifier: "fr-FR"), Locale(identifier: "en-US"), Locale(identifier: "en-GB")] },
            installedLocales: { [Locale(identifier: "en-US")] }
        )

        await choices.load()

        XCTAssertNil(choices.unavailableReason)
        let name = TranscriptionLanguage.name(of:)
        let expected = [
            TranscriptionLanguageChoice(identifier: "en-GB", label: "\(name("en-GB")), needs download"),
            TranscriptionLanguageChoice(identifier: "en-US", label: "\(name("en-US")), installed"),
            TranscriptionLanguageChoice(identifier: "fr-FR", label: "\(name("fr-FR")), needs download"),
        ].sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        XCTAssertEqual(choices.choices(including: "en-US"), expected)
        XCTAssertEqual(
            choices.choices(including: "xh-ZA").first,
            TranscriptionLanguageChoice(identifier: "xh-ZA", label: "\(name("xh-ZA")), not supported")
        )
        XCTAssertEqual(choices.choices(including: "xh-ZA").count, 4)
    }

    /// On a system older than macOS 26 the group says that transcription
    /// needs it, and the pop-up shows only the language the setting holds,
    /// by name; no language is asked about.
    func testOlderSystemsSayTranscriptionNeedsMacOS26() async {
        let choices = TranscriptionLanguageChoices(
            systemSupport: { .needsNewerSystem },
            supportedLocales: {
                XCTFail("the recognizer was asked about its languages")
                return []
            },
            installedLocales: { [] }
        )

        await choices.load()

        XCTAssertEqual(choices.unavailableReason, "Transcription needs macOS 26 or later.")
        XCTAssertEqual(
            choices.choices(including: "en-US"),
            [TranscriptionLanguageChoice(identifier: "en-US", label: TranscriptionLanguage.name(of: "en-US"))]
        )
    }

    /// Every word the group shows and speaks.
    func testTheGroupsWords() {
        XCTAssertEqual(TranscriptionWording.settingsSection, "Transcription")
        XCTAssertEqual(TranscriptionWording.languageLabel, "Transcription language")
        XCTAssertEqual(TranscriptionWording.offerTitle, "Offer to transcribe after importing an audiobook")
        XCTAssertEqual(TranscriptionWording.languageChoice(name: "English (United States)", status: "installed"),
                       "English (United States), installed")
        XCTAssertEqual(TranscriptionWording.languageChoice(name: "English (United States)", status: nil),
                       "English (United States)")
    }
}
