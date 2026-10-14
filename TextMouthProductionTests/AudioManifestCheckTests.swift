import XCTest
@testable import TextMouth

/// The checks an import makes of an audiobook archive's manifest.json
/// (`AudioManifestCheck`): every problem stops the import with a sentence
/// that begins with the file's name and says what is wrong and where, each
/// pinned here word for word. Foundation's own words for JSON it cannot
/// read are its own, so those tests pin what TextMouth adds around them.
///
/// Each test lays out an audiobook's folder of its own in the sandbox, its
/// tracks empty files with audio names: the check lists the tracks by their
/// names and never opens them.
final class AudioManifestCheckTests: XCTestCase {
    /// The audiobook folder this test checks, removed when it ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeSandboxDirectory("manifest-check")
    }

    // MARK: - Manifests That Pass

    /// A manifest with every kind of entry, a byte order mark before it, and
    /// null where a key may be left out, passes, and is read as the book's
    /// reading reads it.
    func testWellFormedManifestPassesAndIsRead() throws {
        try writeTracks(["where_is_everybody.ogg", "one_for_the_angels.ogg", "mr_denton_on_dooms_day.ogg", "king_nine_will_not_return.ogg"])
        let json = AudioManifestTests.exampleJSON.replacingOccurrences(of: "\"author\": \"Various\",", with: "\"author\": null,")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8)).write(to: folder.appendingPathComponent("manifest.json"))

        let manifest = try check()

        XCTAssertEqual(manifest.title, "Radio Dramas")
        XCTAssertNil(manifest.author)
        XCTAssertEqual(manifest.tracks?.count, 6)
    }

    /// The manifests TextMouth itself writes, with sections, and those
    /// arranging a book the older way, pass as they always imported; so do
    /// the shortest and longest pauses, and an empty object.
    func testOlderManifestsAndTheEdgesOfThePausesPass() throws {
        try writeTracks(["a.ogg", "b.ogg"])
        let manifests = [
            #"{}"#,
            #"{"title": "Harbor Plays", "order": ["b.ogg", "b.ogg"], "chapters": {"a.ogg": "First Light"}}"#,
            #"{"segments": [{"title": "Opening", "file": "a.ogg", "startTime": 0, "endTime": 1}]}"#,
            #"{"pauseBetweenTracksMs": 0, "tracks": [{"file": "a.ogg", "pauseAfterMs": 60000}]}"#,
        ]
        for json in manifests {
            try writeManifest(json)
            XCTAssertNoThrow(try check(), json)
        }
    }

    // MARK: - The File and Its JSON

    /// Curly quotation marks, which TextEdit's Smart Quotes make, are not
    /// JSON: the problem gives Foundation's words with the line and column
    /// of the first one, counted from 1 as an editor counts them, and says
    /// where the quotation marks come from and how to stop them.
    func testCurlyQuotationMarksAreNamedWithTheirPlaceAndCause() throws {
        try writeManifest("{\n  \u{201C}title\u{201D}: \u{201C}Radio Dramas\u{201D}\n}")

        let message = try problemMessage()

        XCTAssertTrue(message.hasPrefix("manifest.json is not valid JSON: "), message)
        XCTAssertTrue(message.hasSuffix(
            " around line 2, column 3. It holds curly quotation marks, which TextEdit's Smart Quotes make as you type; "
                + "JSON needs straight ones. Turn off Smart Quotes under Edit, Substitutions, and type the quotation marks again."
        ), message)
    }

    /// JSON that is broken in another way gives Foundation's words and the
    /// place, without the advice about quotation marks.
    func testBrokenJSONIsNamedWithItsPlace() throws {
        try writeManifest("{\n  \"title\": \"Radio Dramas\"\n  \"author\": \"Various\"\n}")

        let message = try problemMessage()

        XCTAssertTrue(message.hasPrefix("manifest.json is not valid JSON: "), message)
        XCTAssertTrue(message.hasSuffix(" around line 3, column 3."), message)
        XCTAssertFalse(message.contains("quotation"), message)
    }

    /// Foundation's place is turned into the one an editor shows: the
    /// column from 1, counted in characters, of the byte Foundation stopped
    /// at; Foundation's own sentence counts from 0, in bytes, which two
    /// letters outside ASCII before the stray bracket here push two places
    /// further. Without that byte, Foundation's sentence is kept as it is.
    func testFoundationsPlaceIsCountedAsAnEditorCountsIt() {
        let data = Data("{\"title\": \"Café\",\n \"éé\": ] }".utf8)
        var reason = ""
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: data)) { error in
            reason = AudioManifestCheck.foundationReason(for: error, in: data)
        }
        XCTAssertTrue(reason.hasSuffix(" around line 2, column 8."), reason)

        let withoutPlace = NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [
            NSDebugDescriptionErrorKey: "Unable to parse empty data.",
        ])
        XCTAssertEqual(AudioManifestCheck.foundationReason(for: withoutPlace, in: Data()), "Unable to parse empty data.")
    }

    /// A manifest TextEdit saved as rich text says how to make it plain.
    func testRichTextSaysHowToMakeItPlain() throws {
        try writeManifest("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n{\\fonttbl\\f0\\fswiss Helvetica;}\n}")

        XCTAssertEqual(
            try problemMessage(),
            "manifest.json is saved as rich text, and must be plain text. In TextEdit, choose Format, Make Plain Text, then save it."
        )
    }

    /// JSON that is not one object says what it holds instead.
    func testJSONThatIsNotAnObjectSaysWhatItHolds() throws {
        try writeManifest(#"["where_is_everybody.ogg"]"#)
        XCTAssertEqual(try problemMessage(), "manifest.json must hold one object, in curly braces, but it holds a list.")
        try writeManifest(#""Radio Dramas""#)
        XCTAssertEqual(try problemMessage(), "manifest.json must hold one object, in curly braces, but it holds text.")
    }

    // MARK: - Keys

    /// A key TextMouth doesn't know is named, with the keys it knows.
    func testUnknownKeysAreNamedWithTheKeysItKnows() throws {
        try writeManifest(#"{"titel": "Radio Dramas", "author": "Various"}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json has a key TextMouth doesn't know: “titel”. "
                + "The keys it knows are title, author, tracks, pauseBetweenTracksMs, order, chapters, and segments."
        )

        try writeManifest(#"{"titel": "Radio Dramas", "auther": "Various"}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json has keys TextMouth doesn't know: “auther” and “titel”. "
                + "The keys it knows are title, author, tracks, pauseBetweenTracksMs, order, chapters, and segments."
        )
    }

    /// A key TextMouth doesn't know in an entry of tracks is named with the
    /// entry's number and the keys an entry takes.
    func testUnknownKeyInAnEntryIsNamedWithItsNumber() throws {
        try writeTracks(["a.ogg", "b.ogg"])
        try writeManifest(#"{"tracks": ["a.ogg", {"file": "b.ogg", "titel": "Second Thoughts"}]}"#)

        XCTAssertEqual(
            try problemMessage(),
            "manifest.json has a key TextMouth doesn't know in entry 2 of tracks: “titel”. "
                + "A track's keys are file, title, and pauseAfterMs; a group heading's is heading."
        )
    }

    // MARK: - Values

    /// A value of the wrong kind is named by its key, and its entry's number
    /// in a list, with the kind it must be and the kind it is.
    func testValuesOfTheWrongKindAreNamedByTheirPlace() throws {
        let cases: [(json: String, message: String)] = [
            (#"{"title": 5}"#, "manifest.json: title must be text in quotation marks, not a number."),
            (#"{"author": ["Various"]}"#, "manifest.json: author must be text in quotation marks, not a list."),
            (#"{"pauseBetweenTracksMs": "250"}"#, "manifest.json: pauseBetweenTracksMs must be a number of milliseconds, not text."),
            (#"{"pauseBetweenTracksMs": true}"#, "manifest.json: pauseBetweenTracksMs must be a number of milliseconds, not true."),
            (#"{"tracks": {"file": "a.ogg"}}"#, "manifest.json: tracks must be a list, in square brackets, not an object."),
            (
                #"{"tracks": ["a.ogg", 5]}"#,
                "manifest.json: entry 2 of tracks must be a file's name in quotation marks, or an object in curly braces, not a number."
            ),
            (
                #"{"tracks": [null]}"#,
                "manifest.json: entry 1 of tracks must be a file's name in quotation marks, or an object in curly braces, not null."
            ),
            (
                #"{"tracks": [{"file": "a.ogg", "pauseAfterMs": "long"}]}"#,
                "manifest.json: pauseAfterMs in entry 1 of tracks must be a number of milliseconds, not text."
            ),
            (#"{"tracks": [{"file": 7}]}"#, "manifest.json: file in entry 1 of tracks must be a file's name in quotation marks, not a number."),
            (#"{"tracks": [{"file": "a.ogg", "title": false}]}"#, "manifest.json: title in entry 1 of tracks must be text in quotation marks, not false."),
            (#"{"tracks": [{"heading": ["Season One"]}]}"#, "manifest.json: heading in entry 1 of tracks must be text in quotation marks, not a list."),
            (#"{"order": "a.ogg"}"#, "manifest.json: order must be a list, in square brackets, not text."),
            (#"{"order": ["a.ogg", null]}"#, "manifest.json: entry 2 of order must be a file's name in quotation marks, not null."),
            (#"{"chapters": ["a.ogg"]}"#, "manifest.json: chapters must be an object, in curly braces, not a list."),
            (
                #"{"chapters": {"a.ogg": 1}}"#,
                "manifest.json: the title for “a.ogg” in chapters must be text in quotation marks, not a number."
            ),
            (#"{"segments": {"title": "Opening"}}"#, "manifest.json: segments must be a list, in square brackets, not an object."),
        ]
        try writeTracks(["a.ogg"])
        for (json, message) in cases {
            try writeManifest(json)
            XCTAssertEqual(try problemMessage(), message, json)
        }
    }

    /// A pause outside 0 to 60000 milliseconds is named with its value.
    func testPausesOutsideTheirRangeAreNamedWithTheirValue() throws {
        try writeTracks(["a.ogg"])
        let cases: [(json: String, message: String)] = [
            (
                #"{"pauseBetweenTracksMs": 90000}"#,
                "manifest.json: pauseBetweenTracksMs is 90000, but a pause is from 0 to 60000 milliseconds."
            ),
            (
                #"{"tracks": [{"file": "a.ogg", "pauseAfterMs": -5}]}"#,
                "manifest.json: pauseAfterMs in entry 1 of tracks is -5, but a pause is from 0 to 60000 milliseconds."
            ),
            (
                #"{"tracks": [{"file": "a.ogg", "pauseAfterMs": 60000.5}]}"#,
                "manifest.json: pauseAfterMs in entry 1 of tracks is 60000.5, but a pause is from 0 to 60000 milliseconds."
            ),
        ]
        for (json, message) in cases {
            try writeManifest(json)
            XCTAssertEqual(try problemMessage(), message, json)
        }
    }

    // MARK: - Entries of Tracks

    /// An entry is a track or a group heading: one with both, or neither,
    /// or a heading carrying a track's keys, or an empty file or heading, is
    /// named by its number.
    func testEntriesThatAreNotOneThingAreNamedByTheirNumber() throws {
        try writeTracks(["a.ogg"])
        let entryKinds = "An entry is a track, with file, or a group heading, with heading."
        let cases: [(json: String, message: String)] = [
            (
                #"{"tracks": [{"file": "a.ogg", "heading": "Season One"}]}"#,
                "manifest.json: entry 1 of tracks has both file and heading. \(entryKinds)"
            ),
            (#"{"tracks": ["a.ogg", {"title": "Elegy"}]}"#, "manifest.json: entry 2 of tracks has neither file nor heading. \(entryKinds)"),
            (
                #"{"tracks": [{"heading": "Season One", "pauseAfterMs": 2000}, "a.ogg"]}"#,
                "manifest.json: entry 1 of tracks is a group heading, which takes heading alone, not pauseAfterMs."
            ),
            (
                #"{"tracks": [{"heading": " "}, "a.ogg"]}"#,
                "manifest.json: the heading in entry 1 of tracks is empty. A group heading needs words."
            ),
            (#"{"tracks": [""]}"#, "manifest.json: the file in entry 1 of tracks is empty. A track needs its file's name."),
            (#"{"tracks": [{"file": "", "title": "Elegy"}]}"#, "manifest.json: the file in entry 1 of tracks is empty. A track needs its file's name."),
        ]
        for (json, message) in cases {
            try writeManifest(json)
            XCTAssertEqual(try problemMessage(), message, json)
        }
    }

    /// tracks arranges a book alone: beside order, chapters, or segments,
    /// the problem names them.
    func testTracksBesideTheOlderKeysAreNamed() throws {
        try writeTracks(["a.ogg"])
        try writeManifest(#"{"tracks": ["a.ogg"], "order": ["a.ogg"]}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json has tracks together with order. Use tracks alone: it gives the book's order and titles itself."
        )

        try writeManifest(#"{"tracks": ["a.ogg"], "segments": [], "chapters": {}, "order": []}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json has tracks together with order, chapters, and segments. "
                + "Use tracks alone: it gives the book's order and titles itself."
        )
    }

    // MARK: - Files

    /// A file the manifest names that is not among the archive's audio
    /// files is named, with how names are spelled; letters' case counts.
    func testAFileTheArchiveDoesNotHoldIsNamed() throws {
        try writeTracks(["Where_Is_Everybody.ogg", "cover.jpg"])
        let spelling = "Names are written as seen from the manifest's own folder, exactly, with the letters' case and the extension."

        try writeManifest(#"{"tracks": ["where_is_everybody.ogg"]}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json names a file in tracks that isn't among the archive's audio files: “where_is_everybody.ogg”. \(spelling)"
        )

        try writeManifest(#"{"order": ["Where_Is_Everybody.ogg", "cover.jpg"]}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json names a file in order that isn't among the archive's audio files: “cover.jpg”. \(spelling)"
        )

        try writeManifest(#"{"chapters": {"Where_Is_Everybody.ogg": "Where Is Everybody?", "elegy.ogg": "Elegy"}}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json names a file in chapters that isn't among the archive's audio files: “elegy.ogg”. \(spelling)"
        )
    }

    /// Many files the archive does not hold are counted, the first five
    /// named, each once.
    func testManyMissingFilesAreCountedAndTheFirstFiveNamed() throws {
        try writeTracks(["present.ogg"])
        let names = (1...7).map { "part\($0).ogg" }
        let entries = (names + ["part1.ogg", "present.ogg"]).map { "\"\($0)\"" }.joined(separator: ", ")
        try writeManifest("{\"tracks\": [\(entries)]}")

        XCTAssertEqual(
            try problemMessage(),
            "manifest.json names 7 files in tracks that aren't among the archive's audio files: "
                + "“part1.ogg”, “part2.ogg”, “part3.ogg”, “part4.ogg”, “part5.ogg”, and 2 more. "
                + "Names are written as seen from the manifest's own folder, exactly, with the letters' case and the extension."
        )
    }

    /// A manifest inside the archive's one folder names tracks from that
    /// folder: a name that starts with the folder's name is not found.
    func testAManifestInsideTheOneFolderNamesTracksFromThere() throws {
        try writeTracks(["Radio Plays/a.ogg", "Radio Plays/b.ogg"])
        try Data(#"{"tracks": ["a.ogg", "Radio Plays/b.ogg"]}"#.utf8).write(to: folder.appendingPathComponent("Radio Plays/manifest.json"))

        XCTAssertEqual(
            try problemMessage(),
            "manifest.json names a file in tracks that isn't among the archive's audio files: “Radio Plays/b.ogg”. "
                + "Names are written as seen from the manifest's own folder, exactly, with the letters' case and the extension."
        )
    }

    /// A file tracks lists more than once is named, each once.
    func testAFileListedTwiceIsNamed() throws {
        try writeTracks(["a.ogg", "b.ogg"])
        try writeManifest(#"{"tracks": ["a.ogg", "b.ogg", "a.ogg"]}"#)
        XCTAssertEqual(try problemMessage(), "manifest.json lists a file more than once in tracks: “a.ogg”.")

        try writeManifest(#"{"tracks": ["a.ogg", "b.ogg", "a.ogg", "b.ogg", "a.ogg"]}"#)
        XCTAssertEqual(try problemMessage(), "manifest.json lists 2 files more than once in tracks: “a.ogg” and “b.ogg”.")
    }

    // MARK: - Group Headings

    /// A group heading with no track listed after it, before the next group
    /// heading or the end of the list, is named with its number.
    func testAGroupHeadingWithoutATrackIsNamed() throws {
        try writeTracks(["a.ogg"])
        try writeManifest(#"{"tracks": [{"heading": "Season One"}, {"heading": "Season Two"}, "a.ogg"]}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json: the group heading “Season One”, entry 1 of tracks, has no track after it before the next heading."
        )

        try writeManifest(#"{"tracks": ["a.ogg", {"heading": "Season Two"}]}"#)
        XCTAssertEqual(
            try problemMessage(),
            "manifest.json: the group heading “Season Two”, entry 2 of tracks, has no track after it before the end of tracks."
        )
    }

    // MARK: - What Only the Reading Refuses

    /// A section TextMouth's reading cannot take, as one without its start,
    /// is named by its place, after every check of the JSON has passed.
    func testASectionTheReadingRefusesIsNamedByItsPlace() throws {
        try writeTracks(["a.ogg"])
        try writeManifest(#"{"segments": [{"title": "Opening", "file": "a.ogg"}]}"#)

        XCTAssertEqual(try problemMessage(), "manifest.json: entry 1 of segments has no startTime.")
    }

    /// A coding path is said from its innermost key outward.
    func testPlacesAreSaidFromTheInnermostKeyOutward() {
        typealias Key = AudioManifestEntry.CodingKeys
        let path: [any CodingKey] = [AudioManifest.CodingKeys.segments, IndexKey(1), Key.file]
        XCTAssertEqual(AudioManifestCheck.place(of: path), "file in entry 2 of segments")
        XCTAssertEqual(AudioManifestCheck.place(of: Array(path.prefix(2))), "entry 2 of segments")
        XCTAssertEqual(AudioManifestCheck.place(of: []), "its top level")
    }

    // MARK: - Wording Helpers

    /// Names are quoted and listed as a sentence lists them, the first five
    /// and then how many more; numbers are written as a person writes them.
    func testNamesAndNumbersAreWrittenAsAPersonWritesThem() {
        XCTAssertEqual(AudioManifestProblem.quotedList(["a"]), "“a”")
        XCTAssertEqual(AudioManifestProblem.quotedList(["a", "b"]), "“a” and “b”")
        XCTAssertEqual(AudioManifestProblem.quotedList(["a", "b", "c"]), "“a”, “b”, and “c”")
        XCTAssertEqual(AudioManifestProblem.quotedList(["a", "b", "c", "d", "e"]), "“a”, “b”, “c”, “d”, and “e”")
        XCTAssertEqual(AudioManifestProblem.quotedList(["a", "b", "c", "d", "e", "f"]), "“a”, “b”, “c”, “d”, “e”, and 1 more")
        XCTAssertEqual(AudioManifestProblem.number(250), "250")
        XCTAssertEqual(AudioManifestProblem.number(-5), "-5")
        XCTAssertEqual(AudioManifestProblem.number(2.5), "2.5")
        XCTAssertEqual(AudioManifestProblem.number(1e300), "1e+300")
    }

    // MARK: - The Import

    /// A manifest with a mistake stops the import of its archive while its
    /// manifest is read, before the book is read: the alert names the
    /// archive, the step, and the problem, the failure is logged once,
    /// nothing is left in the library, and the archive is untouched.
    func testAnImportStopsAtTheManifestSayingWhatIsWrong() throws {
        let library = makeIntegrationLibraryFolder("Manifest Check")
        let archive = try makeTemporaryZip(prefix: "Radio Plays", orderedEntries: [
            TestZIPEntry("Radio Plays/manifest.json", Data(#"{"titel": "Harbor Plays"}"#.utf8)),
            TestZIPEntry("Radio Plays/elegy.ogg", Data("not audio, never read".utf8)),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        let bytes = try Data(contentsOf: archive)
        let problem = "manifest.json has a key TextMouth doesn't know: “titel”. "
            + "The keys it knows are title, author, tracks, pauseBetweenTracksMs, order, chapters, and segments."

        var failure: ImportFailure?
        XCTAssertThrowsError(try FileImportService.importAudioZipWithReport(from: archive, toFolder: library.path)) { error in
            failure = error as? ImportFailure
        }

        XCTAssertEqual(failure?.step, .readingManifest)
        XCTAssertEqual(failure?.underlying as? AudioManifestProblem, .unknownKeys(["titel"], entry: nil))
        XCTAssertEqual(
            failure?.localizedDescription,
            "Could not import “\(archive.lastPathComponent)”. Reading its manifest failed: \(problem)"
        )
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(archive.lastPathComponent): Reading its manifest failed: ").count, 1)
        XCTAssertEqual(try library.entries(), [])
        XCTAssertEqual(try Data(contentsOf: archive), bytes, "the archive must be untouched")
    }

    /// An archive without a manifest never reaches the manifest's step.
    func testAnImportWithoutAManifestReadsNone() throws {
        let library = makeIntegrationLibraryFolder("Manifest Check None")
        let tracks = try makeSandboxDirectory("manifest-check-tracks")
        try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent("01.wav"))
        let archive = try makeTemporaryZip(prefix: "Lectures", entries: [
            "01.wav": try Data(contentsOf: tracks.appendingPathComponent("01.wav")),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        var steps: [ImportStep] = []

        let imported = try FileImportService.importAudioZipWithReport(
            from: archive,
            toFolder: library.path,
            observer: { step, _ in steps.append(step) }
        )

        XCTAssertFalse(steps.contains(.readingManifest), "\(steps)")
        XCTAssertTrue(steps.contains(.readingAudio), "\(steps)")
        XCTAssertEqual(imported.book.title, archive.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Helpers

    /// Check this test's manifest, wherever it lies in the folder.
    private func check() throws -> AudioManifest {
        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder), "no manifest.json was found")
        return try AudioManifestCheck.checkedManifest(at: location, audioFolder: folder)
    }

    /// The sentence the check throws for this test's manifest; fails the
    /// test when it passes, or throws something else.
    private func problemMessage(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        do {
            _ = try check()
        } catch let problem as AudioManifestProblem {
            return problem.localizedDescription
        }
        XCTFail("The manifest passed", file: file, line: line)
        return ""
    }

    /// Write `json`, exactly as given, as this test's top-level manifest.
    private func writeManifest(_ json: String) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("manifest.json"))
    }

    /// Write an empty file for each of `names`, paths in this test's
    /// folder: tracks the check finds by name and never opens.
    private func writeTracks(_ names: [String]) throws {
        for name in names {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }
}

/// A coding key for a position in a list, as a decoder's coding path holds
/// one.
private struct IndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init(_ index: Int) {
        intValue = index
        stringValue = "Index \(index)"
    }

    init?(stringValue: String) {
        return nil
    }

    init?(intValue: Int) {
        self.init(intValue)
    }
}
