import AVFoundation
import XCTest
@testable import TextMouth

/// The parts a speech export (FMT43) stands on, each tested on its own: the
/// voice, speed, and pitch a book is read with; what is known of an
/// installed voice; and the words of each refusal.
///
/// Nothing here speaks, plays a sound, or uses a Personal Voice: voices are
/// only looked up by identifier and read for their names and traits, and the
/// one `SpeechService` made is never asked to speak. Preferences are
/// sandboxed, never the user's.
final class SpeechExportSupportTests: XCTestCase {

    // MARK: - The Voice Settings

    /// An identifier no voice has, on any Mac.
    private let missingVoice = "com.textmouth.tests.no-such-voice"

    /// A book, plain text unless `format` says otherwise, with the voice,
    /// speed, and pitch of its own given (none by default).
    private func book(
        voice: String? = nil,
        wordsPerMinute: Double? = nil,
        pitch: Double? = nil,
        format: BookFormat = .txt
    ) -> Book {
        Book(
            title: "Ferry Timetables",
            format: format,
            filePath: "/tmp/ferry-timetables.txt",
            md5Hash: "ferry-timetables",
            localVoiceID: voice,
            localWPM: wordsPerMinute,
            localPitch: pitch
        )
    }

    /// Sandboxed preferences holding the global voice, speed, and pitch
    /// given; a nil leaves its preference unset.
    private func preferences(
        voice: String? = "global.voice",
        wordsPerMinute: Double? = 300,
        pitch: Double? = 1.25
    ) -> UserDefaults {
        let defaults = makeSandboxedPreferences("speech-export-voice")
        if let voice {
            defaults.set(voice, forKey: "selectedVoiceID")
        }
        if let wordsPerMinute {
            defaults.set(wordsPerMinute, forKey: SettingsPolicy.wordsPerMinute.key)
        }
        if let pitch {
            defaults.set(pitch, forKey: SettingsPolicy.pitchMultiplier.key)
        }
        return defaults
    }

    /// The settings `book` is read with under `defaults`, every voice
    /// installed unless `isInstalled` says otherwise, and "fallback.voice"
    /// the fallback unless `fallback` says otherwise.
    private func settings(
        of book: Book,
        _ defaults: UserDefaults,
        isInstalled: (String) -> Bool = { _ in true },
        fallback: () -> String? = { "fallback.voice" }
    ) -> SpeechExportVoiceSettings {
        SpeechExportVoiceSettings.of(book, defaults: defaults, isInstalled: isInstalled, fallback: fallback)
    }

    /// The global voice is kept under the key `SpeechService` and the
    /// Settings model read and write.
    func testTheGlobalVoiceKeyIsTheOneSettingsKeeps() {
        XCTAssertEqual(SpeechExportVoiceSettings.globalVoiceKey, "selectedVoiceID")
    }

    /// A book's own voice, speed, and pitch win over the global ones.
    func testABooksOwnVoiceSpeedAndPitchWin() {
        let read = settings(of: book(voice: "book.voice", wordsPerMinute: 250, pitch: 0.75), preferences())

        XCTAssertEqual(read, SpeechExportVoiceSettings(voiceIdentifier: "book.voice", wordsPerMinute: 250, pitch: 0.75))
    }

    /// A book without settings of its own is read with the global ones.
    func testABookWithoutItsOwnSettingsIsReadWithTheGlobalOnes() {
        let read = settings(of: book(), preferences())

        XCTAssertEqual(read, SpeechExportVoiceSettings(voiceIdentifier: "global.voice", wordsPerMinute: 300, pitch: 1.25))
    }

    /// A book's voice that is not installed gives way to the global voice,
    /// a global voice not installed gives way to the fallback, and with no
    /// fallback either there is no voice.
    func testAVoiceNotInstalledGivesWayToTheNext() {
        let defaults = preferences()
        let ownVoice = book(voice: "book.voice")

        XCTAssertEqual(
            settings(of: ownVoice, defaults, isInstalled: { $0 == "global.voice" }).voiceIdentifier,
            "global.voice"
        )
        XCTAssertEqual(settings(of: ownVoice, defaults, isInstalled: { _ in false }).voiceIdentifier, "fallback.voice")
        XCTAssertNil(settings(of: ownVoice, defaults, isInstalled: { _ in false }, fallback: { nil }).voiceIdentifier)
        // The book's voice still wins when only it is installed.
        XCTAssertEqual(
            settings(of: ownVoice, defaults, isInstalled: { $0 == "book.voice" }).voiceIdentifier,
            "book.voice"
        )
        // With no global voice stored, a book's voice not installed gives
        // way to the fallback at once.
        XCTAssertEqual(
            settings(of: ownVoice, preferences(voice: nil), isInstalled: { _ in false }).voiceIdentifier,
            "fallback.voice"
        )
    }

    /// The fallback is asked for only when neither the book's voice nor the
    /// global one is installed.
    func testTheFallbackIsAskedForOnlyWhenNeeded() {
        var askedForFallback = 0
        let fallback: () -> String? = {
            askedForFallback += 1
            return "fallback.voice"
        }

        _ = settings(of: book(voice: "book.voice"), preferences(), fallback: fallback)
        XCTAssertEqual(askedForFallback, 0)

        _ = settings(of: book(voice: "book.voice"), preferences(), isInstalled: { _ in false }, fallback: fallback)
        XCTAssertEqual(askedForFallback, 1)
    }

    /// A book's speed and pitch are held to the ones Settings offers: 900
    /// words a minute to 650 and a pitch of 3 to 2, and at the other end 10
    /// words a minute to 50 and a pitch of 0.1 to 0.5.
    func testABooksSpeedAndPitchAreHeldToTheirRanges() {
        let fast = settings(of: book(wordsPerMinute: 900, pitch: 3), preferences())
        XCTAssertEqual(fast.wordsPerMinute, 650)
        XCTAssertEqual(fast.pitch, 2)

        let slow = settings(of: book(wordsPerMinute: 10, pitch: 0.1), preferences())
        XCTAssertEqual(slow.wordsPerMinute, 50)
        XCTAssertEqual(slow.pitch, 0.5)
    }

    /// A book's speed or pitch that is not a finite number gives way to the
    /// global one.
    func testABooksSpeedOrPitchThatIsNotANumberGivesWayToTheGlobalOne() {
        let read = settings(of: book(wordsPerMinute: .nan, pitch: .infinity), preferences())

        XCTAssertEqual(read.wordsPerMinute, 300)
        XCTAssertEqual(read.pitch, 1.25)
    }

    /// An audiobook's own speed is a playback rate, never words per minute,
    /// so the global speed is used, as a reader uses it; its own pitch
    /// still wins.
    func testAnAudiobooksOwnRateIsNotReadAsWordsPerMinute() {
        let read = settings(of: book(wordsPerMinute: 1.5, pitch: 0.75, format: .audio), preferences())

        XCTAssertEqual(read.wordsPerMinute, 300)
        XCTAssertEqual(read.pitch, 0.75)
    }

    /// Unset preferences give the policy's defaults, 200 words a minute and
    /// a pitch of 1, and so do the stored zeros that mean "not chosen yet";
    /// a global speed and pitch out of range are held as Settings holds them.
    func testThePreferencesAreReadAsTheSettingsPolicyReadsThem() {
        let unset = settings(of: book(), preferences(voice: nil, wordsPerMinute: nil, pitch: nil))
        XCTAssertEqual(unset, SpeechExportVoiceSettings(voiceIdentifier: "fallback.voice", wordsPerMinute: 200, pitch: 1))
        XCTAssertEqual(unset.wordsPerMinute, SettingsPolicy.wordsPerMinute.defaultValue)
        XCTAssertEqual(unset.pitch, SettingsPolicy.pitchMultiplier.defaultValue)

        let notChosenYet = settings(of: book(), preferences(wordsPerMinute: 0, pitch: 0))
        XCTAssertEqual(notChosenYet.wordsPerMinute, 200)
        XCTAssertEqual(notChosenYet.pitch, 1)

        let outOfRange = settings(of: book(), preferences(wordsPerMinute: 1_000, pitch: 5))
        XCTAssertEqual(outOfRange.wordsPerMinute, 650)
        XCTAssertEqual(outOfRange.pitch, 2)
    }

    /// For a book without settings of its own, the voice, speed, and pitch
    /// are the ones a `SpeechService` reads from the same preferences, the
    /// system's own voices deciding what is installed: with an installed
    /// global voice and a speed and pitch out of range, and with a voice no
    /// Mac has and nothing else stored. Making a `SpeechService` speaks
    /// nothing.
    func testABookWithoutItsOwnSettingsIsReadAsSpeechServiceReadsThem() {
        let installedVoice = VoiceCatalog.installedVoices()
            .first { !$0.voiceTraits.contains(.isPersonalVoice) }?.identifier
        let stores = [
            preferences(voice: installedVoice ?? missingVoice, wordsPerMinute: 900, pitch: 1.5),
            preferences(voice: missingVoice, wordsPerMinute: nil, pitch: nil)
        ]
        for defaults in stores {
            let speech = SpeechService(userDefaults: defaults)

            let read = SpeechExportVoiceSettings.of(book(), defaults: defaults)

            XCTAssertEqual(read.voiceIdentifier, speech.currentVoice?.identifier)
            XCTAssertEqual(read.wordsPerMinute, speech.wordsPerMinute)
            XCTAssertEqual(read.pitch, speech.pitchMultiplier)
        }
    }

    // MARK: - The Voice Info

    /// An identifier no installed voice has gives no voice.
    func testAnIdentifierNoVoiceHasGivesNoVoice() {
        XCTAssertNil(SpeechExportVoiceInfo.installed(missingVoice))
        XCTAssertFalse(SpeechExportVoiceInfo.isInstalled(missingVoice))
        XCTAssertFalse(SpeechExportVoiceInfo.isInstalled(""))
    }

    /// An installed voice that is not a Personal Voice gives its identifier
    /// and name, and says it is not a Personal Voice. It is only read, never
    /// heard.
    func testAnInstalledVoiceGivesItsName() throws {
        guard let voice = VoiceCatalog.installedVoices().first(where: { !$0.voiceTraits.contains(.isPersonalVoice) }) else {
            throw XCTSkip("No voice but a Personal Voice is installed on this Mac.")
        }

        XCTAssertEqual(
            SpeechExportVoiceInfo.installed(voice.identifier),
            SpeechExportVoiceInfo(identifier: voice.identifier, name: voice.name, isPersonalVoice: false)
        )
        XCTAssertTrue(SpeechExportVoiceInfo.isInstalled(voice.identifier))
    }

    /// The fallback is the system's voice for US English, the one
    /// `SpeechService` falls back to.
    func testTheFallbackIsTheSystemsVoiceForUSEnglish() {
        XCTAssertEqual(SpeechExportVoiceInfo.fallbackIdentifier(), AVSpeechSynthesisVoice(language: "en-US")?.identifier)
    }

    // MARK: - The Errors

    /// Every refusal's words, exactly as the Export dialog shows them and
    /// VoiceOver speaks them.
    func testEveryErrorsWords() {
        XCTAssertEqual(
            SpeechExportError.personalVoice(name: "Ottilie").errorDescription,
            "“Ottilie” is a Personal Voice, which macOS can't record to a file. "
                + "Choose another voice for this book with the Voice button in its reader, then export again."
        )
        XCTAssertEqual(
            SpeechExportError.noVoice.errorDescription,
            "No voice is installed to speak it. "
                + "Add a voice in System Settings, Accessibility, Spoken Content, then export again."
        )
        XCTAssertEqual(
            SpeechExportError.busy.errorDescription,
            "Another book is being exported as spoken audio. Export this one once it has finished."
        )
        XCTAssertEqual(
            SpeechExportError.nothingToSpeak.errorDescription,
            "The part of the book chosen has no words to speak."
        )
        XCTAssertEqual(
            SpeechExportError.headingsChanged.errorDescription,
            "The book's headings changed after the Export dialog opened. "
                + "Close it, open it again, and choose the range again."
        )
    }

    /// The words for too little room give the room needed and the room
    /// TextMouth keeps free (1 GB), each as the Finder gives a size.
    func testTheWordsForTooLittleRoomGiveBothSizes() {
        XCTAssertEqual(ArchiveLimits.standard.freeSpaceReserve, 1_000_000_000)
        let needed = ByteCountFormatter.string(fromByteCount: 2_500_000_000, countStyle: .file)
        let reserve = ByteCountFormatter.string(fromByteCount: 1_000_000_000, countStyle: .file)

        XCTAssertEqual(
            SpeechExportError.notEnoughSpace(needed: 2_500_000_000).errorDescription,
            "There isn't room on the disk for it: it needs about \(needed), "
                + "and TextMouth keeps \(reserve) free. Free some space, then export again."
        )
    }

    /// An error's localized description is its words, which is what an
    /// alert made from the error shows.
    func testAnErrorsLocalizedDescriptionIsItsWords() {
        let error: Error = SpeechExportError.nothingToSpeak

        XCTAssertEqual(error.localizedDescription, "The part of the book chosen has no words to speak.")
    }
}
