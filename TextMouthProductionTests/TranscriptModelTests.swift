import XCTest
@testable import TextMouth

/// The transcript model and its file (FR05): what transcript.json holds and
/// how it is written, what makes a transcript unusable, how a damaged file
/// is kept and ignored, and the note a transcribed book's record keeps.
final class TranscriptModelTests: XCTestCase {

    // MARK: - Encoding

    /// A transcript written to transcript.json reads back as it was, every
    /// field included: the language, the model, the build, the date, and
    /// each file's fingerprint, sentences, and words.
    func testATranscriptReadsBackAsItWasWritten() throws {
        let transcript = TranscriptFixtures.twoFiles
        let bytes = try TranscriptStore.encoded(transcript)

        XCTAssertEqual(try TranscriptStore.decoded(bytes), transcript)
    }

    /// The file is compact: each word is an array of numbers (its place in
    /// the sentence, its start and end in milliseconds, and its
    /// confidence), every time is a whole number of milliseconds, the date
    /// is ISO 8601, and the keys are sorted, so one transcript is always
    /// written as the same bytes.
    func testTheFileIsCompactAndWrittenTheSameWayEachTime() throws {
        let transcript = TranscriptFixtures.twoFiles
        let bytes = try TranscriptStore.encoded(transcript)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertEqual(try TranscriptStore.encoded(transcript), bytes)
        XCTAssertFalse(bytes.contains(UInt8(ascii: "\n")), "transcript.json is not pretty-printed")
        XCTAssertEqual(Set(object.keys), ["app", "createdAt", "files", "locale", "model", "version"])
        XCTAssertEqual(object["createdAt"] as? String, "2026-09-21T14:13:20Z")
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files[safe: 1]?["path"] as? String, "Disc 2/02.wav")
        let firstFile = try XCTUnwrap(files[safe: 0])
        let sentence = try XCTUnwrap((firstFile["sentences"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(sentence.keys), ["endMilliseconds", "startMilliseconds", "text", "words"])
        XCTAssertEqual(sentence["endMilliseconds"] as? Int, 2_400)
        let firstWord = try XCTUnwrap((sentence["words"] as? [[Any]])?.first)
        XCTAssertEqual(firstWord.count, 5)
        XCTAssertEqual(firstWord.prefix(4).compactMap { $0 as? Int }, [0, 9, 0, 400])
        XCTAssertEqual(firstWord[safe: 4] as? Double, 0.9)
        // The keys of the file's objects come in order.
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"app\"")).lowerBound, try XCTUnwrap(text.range(of: "\"files\"")).lowerBound)
    }

    /// A word without a confidence is written as four numbers and read back
    /// without one; a null in the confidence's place reads as none too.
    func testAWordWithoutAConfidenceHasNone() throws {
        let word = TranscriptWord(
            characterOffset: 3,
            characterCount: 4,
            startMilliseconds: 120,
            endMilliseconds: 480,
            confidence: nil
        )
        let bytes = try JSONEncoder().encode(word)

        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "[3,4,120,480]")
        XCTAssertEqual(try JSONDecoder().decode(TranscriptWord.self, from: bytes), word)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptWord.self, from: Data("[3,4,120,480,null]".utf8)), word)
    }

    /// Times are kept in whole milliseconds: the recognizer's 60 ms steps,
    /// which reach the app carrying their arithmetic's rounding, come out
    /// exact, and a time that is not a finite, positive number is 0.
    func testTimesAreKeptInWholeMilliseconds() {
        XCTAssertEqual(Transcript.milliseconds(0.059937), 60)
        XCTAssertEqual(Transcript.milliseconds(2.28), 2_280)
        XCTAssertEqual(Transcript.milliseconds(5_400.0600000001), 5_400_060)
        XCTAssertEqual(Transcript.milliseconds(-0.5), 0)
        XCTAssertEqual(Transcript.milliseconds(.nan), 0)
        XCTAssertEqual(Transcript.milliseconds(.infinity), 0)
        XCTAssertEqual(Transcript.seconds(2_280), 2.28)
    }

    /// A confidence is kept to three decimal places, and one that is not a
    /// number from 0 to 1 is not kept at all.
    func testConfidencesAreKeptToThreeDecimalPlaces() {
        XCTAssertEqual(Transcript.confidence(0.857_123), 0.857)
        XCTAssertEqual(Transcript.confidence(1), 1)
        XCTAssertEqual(Transcript.confidence(0), 0)
        XCTAssertNil(Transcript.confidence(1.2))
        XCTAssertNil(Transcript.confidence(-0.1))
        XCTAssertNil(Transcript.confidence(.nan))
        XCTAssertNil(Transcript.confidence(nil))
    }

    /// The note a book's record keeps names the transcript's layout,
    /// language, and date.
    func testTheNoteNamesTheTranscriptsLayoutLanguageAndDate() {
        XCTAssertEqual(
            TranscriptFixtures.twoFiles.note,
            TranscriptNote(version: Transcript.currentVersion, locale: "en-US", createdAt: TranscriptFixtures.date)
        )
    }

    // MARK: - Validation

    /// A transcript as the recognizer makes it passes validation.
    func testATranscriptAsTheRecognizerMakesItIsValid() {
        XCTAssertNil(TranscriptFixtures.twoFiles.validationFailure())
        XCTAssertNil(TranscriptFixtures.transcript([]).validationFailure())
    }

    /// Each kind of damage is found, and its reason names the first field
    /// that shows it, as transcript.json spells it, and never quotes the
    /// transcript's words.
    func testValidationNamesTheFirstUnusableField() {
        let cases: [(change: (inout Transcript) -> Void, reason: String)] = [
            ({ $0.version = 0 }, "version 0 is not the supported 1"),
            ({ $0.locale = " " }, "locale is empty"),
            ({ $0.files[0].path = "" }, "files[0].path is empty"),
            ({ $0.files[1].path = "/Volumes/Disc 2/02.wav" }, "files[1].path is absolute"),
            ({ $0.files[1].path = "Disc 2/../../02.wav" }, "files[1].path contains a \"..\" component"),
            ({ $0.files[1].path = "01.wav" }, "files[1].path names a file listed before it"),
            ({ $0.files[0].durationMilliseconds = -1 }, "files[0].durationMilliseconds is -1, below 0"),
            ({ $0.files[0].sentences[1].text = " \n" }, "files[0].sentences[1].text is blank"),
            (
                { $0.files[0].sentences[2].startMilliseconds = 2_000 },
                "files[0].sentences[2].startMilliseconds is 2000, before the previous sentence's 2400"
            ),
            (
                { $0.files[1].sentences[0].endMilliseconds = -60 },
                "files[1].sentences[0].endMilliseconds is -60, before its startMilliseconds 0"
            ),
            (
                { $0.files[0].sentences[0].words[1].characterCount = 0 },
                "files[0].sentences[0].words[1] is 0 characters long"
            ),
            (
                { $0.files[0].sentences[0].words[5].characterCount = 40 },
                "files[0].sentences[0].words[5] spans characters 29 to 69, outside 28 through 34"
            ),
            (
                { $0.files[0].sentences[0].words[2].characterOffset = 1 },
                "files[0].sentences[0].words[2] spans characters 1 to 3, outside 15 through 34"
            ),
            (
                { $0.files[0].sentences[1].words[0].startMilliseconds = 2_340 },
                "files[0].sentences[1].words[0] runs from 2340 to 2785 ms, outside 2400 through 5100"
            ),
            (
                { $0.files[0].sentences[0].words[5].endMilliseconds = 2_460 },
                "files[0].sentences[0].words[5] runs from 2000 to 2460 ms, outside 1600 through 2400"
            ),
            (
                { $0.files[0].sentences[0].words[0].confidence = 1.5 },
                "files[0].sentences[0].words[0] has a confidence of 1.5, outside 0 through 1"
            ),
        ]
        let words = TranscriptFixtures.twoFiles.files
            .flatMap(\.sentences)
            .flatMap { $0.text.split(separator: " ") }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 3 }

        for (number, testCase) in cases.enumerated() {
            var transcript = TranscriptFixtures.twoFiles
            testCase.change(&transcript)
            let reason = transcript.validationFailure()
            XCTAssertEqual(reason, testCase.reason, "case \(number)")
            for word in words {
                XCTAssertFalse(reason?.contains(word) == true, "case \(number) quotes \(word)")
            }
        }
    }

    // MARK: - The File in a Package

    /// A transcript written into a package is its transcript.json, written
    /// atomically, and reads back as it was.
    func testATranscriptWrittenIntoAPackageReadsBack() throws {
        let package = try makeSandboxDirectory("transcript-package")
        let transcript = TranscriptFixtures.twoFiles

        let written = try TranscriptStore.write(transcript, into: package)

        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("transcript.json")), written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["transcript.json"])
        XCTAssertEqual(TranscriptStore.read(from: package), .found(transcript))
    }

    /// A package without a transcript has none.
    func testAPackageWithoutATranscriptHasNone() throws {
        XCTAssertEqual(TranscriptStore.read(from: try makeSandboxDirectory("no-transcript")), .missing)
    }

    /// A transcript cut short, as an interrupted write on another Mac leaves
    /// one, is preserved beside itself and ignored, with one line in the
    /// debug log saying so without quoting it. Reading it again keeps the
    /// one copy rather than making another.
    func testATranscriptCutShortIsPreservedAndIgnored() throws {
        let package = try makeSandboxDirectory("transcript-cut-short")
        let file = package.appendingPathComponent("transcript.json")
        let whole = try TranscriptStore.encoded(TranscriptFixtures.twoFiles)
        let cutShort = whole.prefix(whole.count / 2)
        try cutShort.write(to: file)

        XCTAssertEqual(TranscriptStore.read(from: package), .unusable("it is not valid JSON"))
        XCTAssertEqual(TranscriptStore.read(from: package), .unusable("it is not valid JSON"))

        XCTAssertEqual(try Data(contentsOf: file), cutShort, "the damaged file itself is left as it was")
        let copies = try FileManager.default.contentsOfDirectory(atPath: package.path)
            .filter { $0.hasPrefix("transcript.json.unreadable-") }
        XCTAssertEqual(copies.count, 1, "\(copies)")
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(try XCTUnwrap(copies.first))), cutShort)
        let lines = debugLogLines(containing: "TRANSCRIPT_FILE: could not read transcript.json: it is not valid JSON")
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("Quillwort") }, "\(lines)")
    }

    /// A transcript, and a copy kept of one that could not be read, are
    /// TextMouth's own files, never taken for the book: a package whose
    /// record is lost still recovers its one audio file beside them, and a
    /// loose DAISY book never counts them among its files.
    func testATranscriptIsNeverTakenForPartOfTheBook() throws {
        let package = try makeSandboxDirectory("transcript-not-the-book")
        let audio = package.appendingPathComponent("Harbour Talk.m4a")
        try Data("audio".utf8).write(to: audio)
        // A transcript cut short is kept as a copy once read; the usable
        // one written next stands beside that copy.
        let whole = try TranscriptStore.encoded(TranscriptFixtures.twoFiles)
        try whole.prefix(whole.count / 2).write(to: package.appendingPathComponent(TextMouthPaths.transcriptFileName))
        XCTAssertEqual(TranscriptStore.read(from: package), .unusable("it is not valid JSON"))
        _ = try TranscriptStore.write(TranscriptFixtures.twoFiles, into: package)
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path)
        let copy = try XCTUnwrap(names.first { $0.hasPrefix("transcript.json.unreadable-") }, "\(names)")

        for name in [TextMouthPaths.transcriptFileName, copy] {
            XCTAssertTrue(TextMouthPaths.isTranscriptFile(name), name)
            XCTAssertFalse(FileImportService.isPackageContentName(name), name)
            XCTAssertFalse(DAISYPackageInventory.isBookPath(name), name)
        }
        XCTAssertEqual(
            try FileImportService.retainedContentURL(in: package).standardizedFileURL,
            audio.standardizedFileURL
        )
        XCTAssertFalse(TextMouthPaths.isTranscriptFile("transcript.json notes.txt"))
        XCTAssertTrue(FileImportService.isPackageContentName("transcript.json notes.txt"), "a book file of another name was refused")
    }

    /// A transcript that decodes but fails validation is preserved and
    /// ignored the same way, for the reason validation gives.
    func testATranscriptFailingValidationIsPreservedAndIgnored() throws {
        let package = try makeSandboxDirectory("transcript-invalid")
        var transcript = TranscriptFixtures.twoFiles
        transcript.files[1].sentences[1].endMilliseconds = 1_000
        try TranscriptStore.write(transcript, into: package)

        XCTAssertEqual(
            TranscriptStore.read(from: package),
            .unusable("files[1].sentences[1].endMilliseconds is 1000, before its startMilliseconds 1980")
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: package.path)
                .filter { $0.hasPrefix("transcript.json.unreadable-") }.count,
            1
        )
    }

    /// A transcript a later TextMouth wrote, in a layout this one does not
    /// read, is left alone: neither preserved nor read, and not logged as
    /// damage.
    func testATranscriptOfALaterLayoutIsLeftAlone() throws {
        let package = try makeSandboxDirectory("transcript-later-layout")
        let marker = UUID().uuidString
        try Data(#"{"version": 2, "files": "\#(marker)"}"#.utf8)
            .write(to: package.appendingPathComponent("transcript.json"))

        XCTAssertEqual(TranscriptStore.read(from: package), .unsupportedVersion(2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["transcript.json"])
        XCTAssertEqual(debugLogLines(containing: marker), [])
    }

    /// A transcript only in the cloud is not read, since reading it would
    /// download it, and nothing is preserved.
    func testATranscriptOnlyInTheCloudIsNotRead() throws {
        let package = try makeSandboxDirectory("transcript-in-cloud")
        try TranscriptStore.write(TranscriptFixtures.twoFiles, into: package)

        let lookup = TranscriptStore.read(from: package) { _ in throw LocalBookFiles.downloadRefusal }

        XCTAssertEqual(lookup, .inCloud)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["transcript.json"])
    }

    /// A decoding error is described by its kind and where it happened,
    /// never by what the decoder found there, which may be the book's text.
    func testDecodingErrorsAreDescribedWithoutQuotingTheFile() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.files[0].sentences[0].text = "Quillwort"
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try TranscriptStore.encoded(transcript)) as? [String: Any]
        )
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        // Read each level through the safe subscript, so a shorter list fails
        // here; the writes back below use indexes this unwrapping proved.
        var file = try XCTUnwrap(files[safe: 0])
        var sentences = try XCTUnwrap(file["sentences"] as? [[String: Any]])
        var sentence = try XCTUnwrap(sentences[safe: 0])
        sentence["startMilliseconds"] = "Quillwort"
        sentences[0] = sentence
        file["sentences"] = sentences
        files[0] = file
        object["files"] = files
        let bytes = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try TranscriptStore.decoded(bytes)) { error in
            let description = TranscriptStore.describe(error)
            XCTAssertEqual(description, "a value at files[0].sentences[0].startMilliseconds has the wrong type")
            XCTAssertFalse(description.contains("Quillwort"))
        }
        XCTAssertThrowsError(try TranscriptStore.decoded(Data(#"{"version": 1}"#.utf8))) { error in
            XCTAssertEqual(TranscriptStore.describe(error), "locale is missing")
        }
    }

    // MARK: - The Book's Record

    /// A transcribed book's record notes its transcript, and a save of the
    /// book's state, which a library row makes and which never carries the
    /// note, keeps it: library.json does not hold it, so the package record
    /// is its only home.
    func testEverySaveOfTheBooksStateKeepsTheRecordsTranscriptNote() throws {
        let folder = makeIntegrationLibraryFolder("Transcript Note")
        var book = Book(
            title: "The Salt Road",
            format: .audio,
            filePath: "",
            md5Hash: "note-test",
            folderPath: folder.path,
            tmbDirectoryName: "Salt Road.tmb"
        )
        book.filePath = book.tmbDirectory.appendingPathComponent("audio").path
        try FileManager.default.createDirectory(at: book.tmbDirectory, withIntermediateDirectories: true)
        var record = book.makeBookInfo()
        let note = TranscriptFixtures.twoFiles.note
        record.state.transcript = note
        try record.save(to: book.tmbDirectory)

        book.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 40)
        try book.saveBookInfoThrowing()

        let saved = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(saved.state.transcript, note)
        XCTAssertEqual(saved.state.readingPosition?.characterOffset, 40)
        XCTAssertNil(Book(record: saved, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
            .makeBookInfo().state.transcript, "a library row never carries the note")
    }

    /// A record without a note, as every book's has but a transcribed
    /// one's, is written without the field, so its bytes are as they always
    /// were; a note that cannot be read counts as none, and the record
    /// still loads.
    func testARecordWithoutAReadableNoteLoadsWithoutOne() throws {
        let plain = try JSONEncoder().encode(BookState())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("transcript"))

        let damaged = Data(#"{"isNew": true, "tmbDirectoryName": "Book.tmb", "transcript": 7}"#.utf8)
        let state = try JSONDecoder().decode(BookState.self, from: damaged)
        XCTAssertNil(state.transcript)
        XCTAssertEqual(state.tmbDirectoryName, "Book.tmb")

        var noted = BookState()
        noted.transcript = TranscriptFixtures.twoFiles.note
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(BookState.self, from: try encoder.encode(noted)).transcript, noted.transcript)
    }
}
