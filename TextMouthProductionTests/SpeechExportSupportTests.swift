import AVFoundation
import CryptoKit
import IOKit.pwr_mgt
import os
import XCTest
@testable import TextMouth

/// The parts a speech export (FMT43) stands on, each tested on its own: the
/// voice, speed, and pitch a book is read with; what is known of an
/// installed voice; the words of each refusal; the chapters kept between
/// runs of an export; the disk check; and the power assertion that keeps
/// the Mac awake.
///
/// Nothing here speaks, plays a sound, or uses a Personal Voice: voices are
/// only looked up by identifier and read for their names and traits, and the
/// one `SpeechService` made is never asked to speak. Preferences and
/// files are sandboxed, never the user's, and the one power assertion
/// taken is let go at once.
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

    // MARK: - The Kept Chapters

    /// A store under the key `key`, whose root is a folder not yet made in
    /// a new sandbox folder.
    private func makeStore(key: String = "export-key") throws -> SpeechExportStore {
        let sandbox = try makeSandboxDirectory("speech-export-store")
        return SpeechExportStore(root: sandbox.appendingPathComponent("Speech Export", isDirectory: true), key: key)
    }

    /// Writes a whole chapter at `url`: a tenth of a second of 16-bit mono
    /// silence in a CAF file.
    private func writeChapter(at url: URL) throws {
        try AudioTestFixtures.writeSilence(to: url, duration: 0.1)
    }

    /// The names of the items in `folder`, hidden ones too, sorted.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Whether anything is at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The key as the brief describes it, made here byte by byte apart
    /// from the store's own code: SHA-256 over the version, the book ID, the
    /// voice, the speed, the pitch, and the sections, each string as its
    /// UTF-8 length and then its bytes, each length and count in 8 bytes,
    /// least significant first; the first 16 bytes, in lowercase hex.
    private func keyMadeByHand(
        bookID: UUID,
        voice: String?,
        wordsPerMinute: Double,
        pitch: Double,
        sections: [[String]]
    ) -> String {
        var bytes: [UInt8] = []
        func number(_ value: Int) {
            bytes += (0..<8).map { UInt8(truncatingIfNeeded: UInt64(value) >> (8 * UInt64($0))) }
        }
        func string(_ text: String) {
            number(text.utf8.count)
            bytes += Array(text.utf8)
        }
        string("TextMouth speech export 1")
        string(bookID.uuidString)
        string(voice ?? "")
        string(String(wordsPerMinute))
        string(String(pitch))
        number(sections.count)
        for section in sections {
            number(section.count)
            section.forEach(string)
        }
        return SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The key is 32 lowercase hexadecimal digits: the first 16 bytes of the
    /// digest the brief describes, the same for the same inputs.
    func testTheKeyIsTheDigestOfItsInputs() {
        let bookID = UUID()
        let sections = [["Departures", "The ferry leaves at six."], ["Crossing", "Gulls.", "Rain on the deck."]]

        let key = SpeechExportStore.key(
            bookID: bookID, voiceIdentifier: "voice.a", wordsPerMinute: 215, pitch: 1.1, sections: sections
        )

        XCTAssertEqual(key.count, 32)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) }, key)
        XCTAssertEqual(
            key,
            SpeechExportStore.key(bookID: bookID, voiceIdentifier: "voice.a", wordsPerMinute: 215, pitch: 1.1, sections: sections)
        )
        XCTAssertEqual(
            key,
            keyMadeByHand(bookID: bookID, voice: "voice.a", wordsPerMinute: 215, pitch: 1.1, sections: sections)
        )
        XCTAssertEqual(
            SpeechExportStore.key(bookID: bookID, voiceIdentifier: nil, wordsPerMinute: 200, pitch: 1, sections: []),
            keyMadeByHand(bookID: bookID, voice: nil, wordsPerMinute: 200, pitch: 1, sections: [])
        )
    }

    /// Changing any one input changes the key, so chapters are only used
    /// again for the same book, voice, speed, pitch, and words; and inputs
    /// never run together: ["a", "bc"] is not ["ab", "c"], and a section
    /// split in two is not the section whole.
    func testTheKeyChangesWithEachInput() {
        let bookID = UUID()
        let sections = [["Departures", "a", "bc"]]
        let key = { (bookID: UUID, voice: String?, wordsPerMinute: Double, pitch: Double, sections: [[String]]) in
            SpeechExportStore.key(
                bookID: bookID, voiceIdentifier: voice, wordsPerMinute: wordsPerMinute, pitch: pitch, sections: sections
            )
        }
        let original = key(bookID, "voice.a", 200, 1, sections)

        let changed = [
            "another book": key(UUID(), "voice.a", 200, 1, sections),
            "another voice": key(bookID, "voice.b", 200, 1, sections),
            "no voice": key(bookID, nil, 200, 1, sections),
            "another speed": key(bookID, "voice.a", 201, 1, sections),
            "another pitch": key(bookID, "voice.a", 200, 1.05, sections),
            "another title": key(bookID, "voice.a", 200, 1, [["Arrivals", "a", "bc"]]),
            "another text": key(bookID, "voice.a", 200, 1, [["Departures", "a", "bd"]]),
            "a text more": key(bookID, "voice.a", 200, 1, [["Departures", "a", "bc", ""]]),
            "the texts run together": key(bookID, "voice.a", 200, 1, [["Departures", "ab", "c"]]),
            "the section split in two": key(bookID, "voice.a", 200, 1, [["Departures", "a"], ["bc"]]),
            "no sections": key(bookID, "voice.a", 200, 1, []),
            "an empty section": key(bookID, "voice.a", 200, 1, [[]])
        ]

        for (change, changedKey) in changed {
            XCTAssertNotEqual(changedKey, original, change)
        }
        XCTAssertEqual(Set(changed.values).count, changed.count, "Two different changes made one key")
        XCTAssertNotEqual(key(bookID, nil, 200, 1, [["a", "bc"]]), key(bookID, nil, 200, 1, [["ab", "c"]]))
    }

    /// The chapter files' names: four digits at least, counted from 1, the
    /// part file keeping the `caf` extension, all in the key's folder.
    func testTheChapterFilesNames() {
        let root = URL(fileURLWithPath: "/Volumes/Spoken/Speech Export", isDirectory: true)
        let store = SpeechExportStore(root: root, key: "0123abcd")

        XCTAssertEqual(store.folder.path, "/Volumes/Spoken/Speech Export/0123abcd")
        XCTAssertEqual(store.chapterName(0), "0001.caf")
        XCTAssertEqual(store.chapterName(41), "0042.caf")
        XCTAssertEqual(store.chapterName(9_999), "10000.caf")
        XCTAssertEqual(store.chapterURL(0).path, "/Volumes/Spoken/Speech Export/0123abcd/0001.caf")
        XCTAssertEqual(store.partURL(0).path, "/Volumes/Spoken/Speech Export/0123abcd/0001.partial.caf")
        XCTAssertEqual(store.partURL(0).pathExtension, "caf")
        XCTAssertEqual(store.partURL(41).lastPathComponent, "0042.partial.caf")
    }

    /// The app keeps exports' chapters in "Speech Export" in this Mac's
    /// Caches folder, which is in the sandbox under hosted tests.
    func testTheLiveRootIsInThisMacsCachesFolder() {
        XCTAssertEqual(
            SpeechExportStore.liveRoot,
            MachineLocalPaths.caches.appendingPathComponent("Speech Export", isDirectory: true)
        )
        XCTAssertTrue(SpeechExportStore.liveRoot.path.hasPrefix(HostedTestSandbox.home.path))
    }

    /// A store opened for the first time makes its root and its folder,
    /// and keeps no chapters.
    func testAStoreOpenedForTheFirstTimeKeepsNoChapters() throws {
        let store = try makeStore()
        XCTAssertFalse(exists(store.root))

        XCTAssertEqual(try store.open(), 0)

        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertEqual(try names(in: store.root), [store.key])
    }

    /// Opening removes every other export's folder and anything else in the
    /// root, hidden files too, and every part file, even a readable one;
    /// the whole chapters are counted and kept.
    func testOpeningRemovesOtherExportsAndPartFiles() throws {
        let store = try makeStore()
        let other = SpeechExportStore(root: store.root, key: "another-export")
        try writeChapter(at: other.chapterURL(0))
        try writeChapter(at: store.chapterURL(0))
        try writeChapter(at: store.chapterURL(1))
        try writeChapter(at: store.partURL(2))
        try AudioTestFixtures.writeNonAudioBytes(to: store.partURL(3))
        try Data("left by the Finder".utf8).write(to: store.root.appendingPathComponent(".DS_Store"))
        try Data("a stray note".utf8).write(to: store.root.appendingPathComponent("stray.txt"))

        XCTAssertEqual(try store.open(), 2)

        XCTAssertEqual(try names(in: store.root), [store.key])
        XCTAssertEqual(try names(in: store.folder), ["0001.caf", "0002.caf"])
    }

    /// The count stops at the first chapter missing, and every chapter
    /// after it is removed, to be spoken again in order.
    func testTheCountStopsAtAMissingChapter() throws {
        let store = try makeStore()
        try writeChapter(at: store.chapterURL(0))
        try writeChapter(at: store.chapterURL(1))
        try writeChapter(at: store.chapterURL(3))
        try writeChapter(at: store.chapterURL(4))

        XCTAssertEqual(try store.open(), 2)

        XCTAssertEqual(try names(in: store.folder), ["0001.caf", "0002.caf"])
    }

    /// The count stops at the first chapter that is not audio, which is
    /// removed with every chapter after it.
    func testTheCountStopsAtAnUnreadableChapter() throws {
        let store = try makeStore()
        try writeChapter(at: store.chapterURL(0))
        try AudioTestFixtures.writeNonAudioBytes(to: store.chapterURL(1))
        try writeChapter(at: store.chapterURL(2))

        XCTAssertEqual(try store.open(), 1)

        XCTAssertEqual(try names(in: store.folder), ["0001.caf"])
    }

    /// A chapter file holding no audio frames is not a whole chapter.
    func testAChapterWithoutFramesIsNotKept() throws {
        let store = try makeStore()
        try writeChapter(at: store.chapterURL(0))
        try AudioTestFixtures.writeSilence(to: store.chapterURL(1), duration: 0)

        XCTAssertEqual(try store.open(), 1)

        XCTAssertEqual(try names(in: store.folder), ["0001.caf"])
    }

    /// A chapter file whose bytes are Ogg is refused by its first four bytes
    /// before Apple's decoder could see it, and is spoken again.
    func testAChapterWhoseBytesAreOggIsNeverOpened() throws {
        let store = try makeStore()
        try writeChapter(at: store.chapterURL(0))
        try Data(Array("OggS".utf8) + [UInt8](repeating: 0, count: 60)).write(to: store.chapterURL(1))

        XCTAssertEqual(try store.open(), 1)

        XCTAssertEqual(try names(in: store.folder), ["0001.caf"])
    }

    /// Files in the folder that are neither a chapter nor a part, and
    /// chapter-like names that are not a chapter's own, are left alone.
    func testOpeningLeavesFilesThatAreNotChapters() throws {
        let store = try makeStore()
        try writeChapter(at: store.chapterURL(0))
        try writeChapter(at: store.folder.appendingPathComponent("00002.caf"))
        try Data("a note".utf8).write(to: store.folder.appendingPathComponent("notes.txt"))

        XCTAssertEqual(try store.open(), 1)

        XCTAssertEqual(try names(in: store.folder), ["00002.caf", "0001.caf", "notes.txt"])
    }

    /// Finishing a chapter gives its part file the chapter's name, replacing
    /// a file already there, and the next opening keeps it.
    func testFinishingAChapterMovesItsPartIntoPlace() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.open(), 0)

        try writeChapter(at: store.partURL(0))
        try store.finishChapter(0)
        XCTAssertTrue(exists(store.chapterURL(0)))
        XCTAssertFalse(exists(store.partURL(0)))

        try AudioTestFixtures.writeNonAudioBytes(to: store.chapterURL(1))
        try writeChapter(at: store.partURL(1))
        try store.finishChapter(1)
        XCTAssertFalse(exists(store.partURL(1)))
        XCTAssertGreaterThan(try AVAudioFile(forReading: store.chapterURL(1)).length, 0)

        XCTAssertEqual(try store.open(), 2)
    }

    /// Finishing a chapter that was never spoken throws, and leaves nothing.
    func testFinishingAChapterNeverSpokenThrows() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.open(), 0)

        XCTAssertThrowsError(try store.finishChapter(0))

        XCTAssertEqual(try names(in: store.folder), [])
    }

    /// Removing all removes the root and everything in it; doing it again,
    /// with nothing there, is harmless.
    func testRemovingAllRemovesTheRoot() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.open(), 0)
        try writeChapter(at: store.chapterURL(0))

        store.removeAll()
        XCTAssertFalse(exists(store.root))

        store.removeAll()
        XCTAssertFalse(exists(store.root))
    }

    /// One export at a time: a claim is refused until the export that holds
    /// the store releases it.
    func testAClaimIsExclusiveUntilReleased() {
        guard SpeechExportStore.claim() else {
            return XCTFail("The store was already claimed")
        }
        defer { SpeechExportStore.release() }

        XCTAssertFalse(SpeechExportStore.claim())
        XCTAssertFalse(SpeechExportStore.claim())
        SpeechExportStore.release()
        XCTAssertTrue(SpeechExportStore.claim())
    }

    /// The launch sweep removes every export's kept chapters, but not while
    /// an export holds the store, and never lets go of a claim it did not
    /// make.
    func testTheSweepRemovesTheRootUnlessAnExportHoldsTheStore() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.open(), 0)
        try writeChapter(at: store.chapterURL(0))

        guard SpeechExportStore.claim() else {
            return XCTFail("The store was already claimed")
        }
        SpeechExportStore.sweep(root: store.root)
        let stillClaimed = !SpeechExportStore.claim()
        SpeechExportStore.release()
        XCTAssertTrue(exists(store.chapterURL(0)), "The sweep removed the chapters of an export that holds the store")
        XCTAssertTrue(stillClaimed, "The sweep let go of a claim it did not make")

        SpeechExportStore.sweep(root: store.root)
        let claimedAfterSweep = SpeechExportStore.claim()
        if claimedAfterSweep {
            SpeechExportStore.release()
        }
        XCTAssertFalse(exists(store.root))
        XCTAssertTrue(claimedAfterSweep, "The sweep kept the store claimed")
    }

    /// At launch the sweep does nothing under a hosted test, and otherwise
    /// removes the live root off the main thread (in the sandbox here).
    func testTheBackgroundSweepRunsOnlyOutsideHostedTests() throws {
        let live = SpeechExportStore(root: SpeechExportStore.liveRoot, key: "launch-sweep")
        guard live.root.path.hasPrefix(HostedTestSandbox.home.path) else {
            return XCTFail("The live root is not in the sandbox: \(live.root.path)")
        }
        XCTAssertEqual(try live.open(), 0)
        try writeChapter(at: live.chapterURL(0))
        addTeardownBlock { live.removeAll() }

        let hosted = expectation(description: "a hosted sweep ran")
        hosted.isInverted = true
        hosted.assertForOverFulfill = false
        SpeechExportStore.sweepInBackground(isHostedTest: true) { hosted.fulfill() }
        wait(for: [hosted], timeout: 0.3)
        XCTAssertTrue(exists(live.chapterURL(0)))

        let ran = expectation(description: "the sweep ran")
        ran.assertForOverFulfill = false
        SpeechExportStore.sweepInBackground(isHostedTest: false) { ran.fulfill() }
        wait(for: [ran], timeout: 10)
        XCTAssertFalse(exists(live.root))
    }

    // MARK: - The Disk Check

    /// Where kept speech goes in the disk check's tests, which never look
    /// at a real disk.
    private static let speechFolder = URL(fileURLWithPath: "/Volumes/Spoken/Speech Export", isDirectory: true)
    /// Where the exported file goes in those tests.
    private static let fileFolder = URL(fileURLWithPath: "/Volumes/Shelf/Exports", isDirectory: true)
    /// The bytes those tests keep free on every volume: few, so the sums
    /// stay readable.
    private static let reserve: Int64 = 1_000
    /// Ten seconds of kept speech, in bytes.
    private static let speechNeed: Int64 = 441_000
    /// Ten seconds of the exported file, in bytes.
    private static let fileNeed: Int64 = 80_000

    /// Checks ten seconds of speech and ten of the file (unless told
    /// otherwise) against the free space `free` gives each folder, the two
    /// folders on one volume or on two.
    private func checkSpace(
        sameVolume: Bool,
        speechSeconds: TimeInterval = 10,
        fileSeconds: TimeInterval = 10,
        free: (URL) -> Int64?
    ) throws {
        try SpeechExportSpace.check(
            speechSeconds: speechSeconds,
            fileSeconds: fileSeconds,
            speechFolder: Self.speechFolder,
            fileFolder: Self.fileFolder,
            freeSpace: free,
            sameVolume: { _, _ in sameVolume },
            reserve: Self.reserve
        )
    }

    /// What `check` throws, or nil when it passes.
    private func refusal(_ check: () throws -> Void) -> Error? {
        do {
            try check()
            return nil
        } catch {
            return error
        }
    }

    /// A second of kept speech takes 44,100 bytes (16-bit mono at
    /// 22,050 Hz), and a second of the file 8,000 (64 kbit/s).
    func testWhatASecondTakes() {
        XCTAssertEqual(SpeechExportSpace.speechBytesPerSecond, 44_100)
        XCTAssertEqual(SpeechExportSpace.fileBytesPerSecond, 8_000)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 10, at: SpeechExportSpace.speechBytesPerSecond), Self.speechNeed)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 10, at: SpeechExportSpace.fileBytesPerSecond), Self.fileNeed)
    }

    /// On one volume the speech's need and the file's add up: free space
    /// exactly the reserve above their sum passes, and a byte less throws
    /// with the sum.
    func testOnOneVolumeTheTwoNeedsAddUp() {
        let need = Self.speechNeed + Self.fileNeed

        XCTAssertNil(refusal { try checkSpace(sameVolume: true) { _ in Self.reserve + need } })
        XCTAssertEqual(
            refusal { try checkSpace(sameVolume: true) { _ in Self.reserve + need - 1 } } as? SpeechExportError,
            .notEnoughSpace(needed: need)
        )
    }

    /// On two volumes each is checked apart, for its own need: each with
    /// exactly the reserve above its need passes, though the two needs
    /// together would not fit on either; either a byte short throws with
    /// its own need.
    func testOnTwoVolumesEachIsCheckedApart() {
        /// Free space `speechSpare` bytes beyond the reserve and the
        /// speech's need on the speech's volume, and `fileSpare` beyond the
        /// reserve and the file's need on the file's.
        func free(speechSpare: Int64, fileSpare: Int64) -> (URL) -> Int64? {
            return { folder in
                folder == Self.speechFolder
                    ? Self.reserve + Self.speechNeed + speechSpare
                    : Self.reserve + Self.fileNeed + fileSpare
            }
        }

        XCTAssertNil(refusal { try checkSpace(sameVolume: false, free: free(speechSpare: 0, fileSpare: 0)) })
        XCTAssertEqual(
            refusal { try checkSpace(sameVolume: false, free: free(speechSpare: -1, fileSpare: 0)) } as? SpeechExportError,
            .notEnoughSpace(needed: Self.speechNeed)
        )
        XCTAssertEqual(
            refusal { try checkSpace(sameVolume: false, free: free(speechSpare: 0, fileSpare: -1)) } as? SpeechExportError,
            .notEnoughSpace(needed: Self.fileNeed)
        )
        XCTAssertEqual(
            refusal { try checkSpace(sameVolume: true, free: free(speechSpare: 0, fileSpare: 0)) } as? SpeechExportError,
            .notEnoughSpace(needed: Self.speechNeed + Self.fileNeed)
        )
    }

    /// A volume whose free space is unknown is not checked, however much is
    /// needed; the other volume still is.
    func testUnknownFreeSpaceIsNotChecked() {
        XCTAssertNil(refusal { try checkSpace(sameVolume: true, speechSeconds: 1e9, fileSeconds: 1e9) { _ in nil } })
        XCTAssertNil(refusal {
            try checkSpace(sameVolume: false) { $0 == Self.speechFolder ? nil : Self.reserve + Self.fileNeed }
        })
        XCTAssertEqual(
            refusal { try checkSpace(sameVolume: false) { $0 == Self.speechFolder ? nil : Self.reserve } } as? SpeechExportError,
            .notEnoughSpace(needed: Self.fileNeed)
        )
    }

    /// Every second begun is counted whole; a time not above 0, or not a
    /// number, needs nothing; and a time beyond any count of bytes needs
    /// the most there can be, which no disk has, rather than stopping the
    /// app.
    func testEverySecondBegunIsCountedWhole() {
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 1.2, at: 44_100), 88_200)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 2, at: 44_100), 88_200)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 0.01, at: 8_000), 8_000)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 0, at: 44_100), 0)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: -3, at: 44_100), 0)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: .nan, at: 44_100), 0)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: .infinity, at: 44_100), .max)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 1e300, at: 44_100), .max)
        XCTAssertEqual(SpeechExportSpace.bytes(forSeconds: 1e15, at: 44_100), .max)

        // Half a second of speech, and no file, still needs a whole second.
        XCTAssertEqual(
            refusal {
                try checkSpace(sameVolume: true, speechSeconds: 0.5, fileSeconds: 0) { _ in Self.reserve + 44_099 }
            } as? SpeechExportError,
            .notEnoughSpace(needed: 44_100)
        )
        // Two needs as large as can be, on one volume, add up to the most
        // there can be.
        XCTAssertEqual(
            refusal {
                try checkSpace(sameVolume: true, speechSeconds: .infinity, fileSeconds: .infinity) { _ in .max }
            } as? SpeechExportError,
            .notEnoughSpace(needed: .max)
        )
    }

    /// How long words take to speak: words over words a minute, in seconds;
    /// 0 for a speed not above 0, or not a finite number.
    func testHowLongWordsTakeToSpeak() {
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 400, wordsPerMinute: 200), 120)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 450, wordsPerMinute: 180), 150)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 0, wordsPerMinute: 200), 0)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 400, wordsPerMinute: 0), 0)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 400, wordsPerMinute: -200), 0)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 400, wordsPerMinute: .nan), 0)
        XCTAssertEqual(SpeechExportSpace.seconds(wordCount: 400, wordsPerMinute: .infinity), 0)
    }

    // MARK: - The Power Assertion

    /// A power assertion that records each hold and release in `log`, and
    /// gives the ID `id`, or none when `id` is nil, as when the system will
    /// not take the assertion.
    private func recordingPower(
        _ log: OSAllocatedUnfairLock<[String]>,
        id: IOPMAssertionID? = 7
    ) -> SpeechExportPower {
        SpeechExportPower(
            hold: { reason in
                log.withLock { $0.append("hold \(reason)") }
                return id
            },
            release: { released in
                log.withLock { $0.append("release \(released)") }
            }
        )
    }

    /// `whileHeld` holds once, runs its body, and releases once when the
    /// body returns, giving what the body gives.
    func testWhileHeldHoldsAndReleasesOnceAroundItsBody() {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])

        let value = recordingPower(log).whileHeld(reason: "Exporting") { () -> Int in
            log.withLock { $0.append("body") }
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(log.withLock { $0 }, ["hold Exporting", "body", "release 7"])
    }

    /// When its body throws, `whileHeld` still releases once, and the error
    /// passes through.
    func testWhileHeldReleasesWhenItsBodyThrows() {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])

        XCTAssertThrowsError(
            try recordingPower(log).whileHeld(reason: "Exporting") { () throws -> Int in
                log.withLock { $0.append("body") }
                throw SpeechExportError.busy
            }
        ) { error in
            XCTAssertEqual(error as? SpeechExportError, .busy)
        }
        XCTAssertEqual(log.withLock { $0 }, ["hold Exporting", "body", "release 7"])
    }

    /// When the system will not take the assertion, the body still runs,
    /// and nothing is released.
    func testWhileHeldRunsItsBodyWhenNoAssertionIsHeld() {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])

        let value = recordingPower(log, id: nil).whileHeld(reason: "Exporting") { "spoken" }

        XCTAssertEqual(value, "spoken")
        XCTAssertEqual(log.withLock { $0 }, ["hold Exporting"])
    }

    /// The live assertion: holding gives an ID the system knows, named as
    /// asked and keeping the system from idle sleep, and releasing lets it
    /// go. It keeps the Mac awake for a moment and makes no sound.
    func testTheLiveAssertionIsHeldAndLetGo() throws {
        let reason = "TextMouth's tests hold this for a moment"

        let id = try XCTUnwrap(SpeechExportPower.live.hold(reason))
        let held = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        SpeechExportPower.live.release(id)
        let afterRelease = IOPMAssertionCopyProperties(id)?.takeRetainedValue()

        XCTAssertEqual(held?[kIOPMAssertionNameKey] as? String, reason)
        XCTAssertEqual(held?[kIOPMAssertionTypeKey] as? String, kIOPMAssertPreventUserIdleSystemSleep)
        XCTAssertNil(afterRelease, "The assertion was not let go")
    }
}
