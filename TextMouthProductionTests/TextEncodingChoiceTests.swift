import XCTest
@testable import TextMouth

/// Book Information's Text Encoding pop-up (encodingchoice), without a
/// window: the options it offers and their names, what a book is read in
/// now and how that is said, every sentence the choice speaks, and which
/// books offer it.
final class TextEncodingChoiceTests: XCTestCase {

    // MARK: - The Options

    /// Automatic comes first, then UTF-8, then each name of the catalog once,
    /// in the catalog's order and exactly as the catalog names it.
    func testTheOptionsAreAutomaticThenUTF8ThenEachCatalogNameOnce() {
        let options = TextEncodingChoices.options
        XCTAssertEqual(options.first, .automatic)
        XCTAssertEqual(options.dropFirst().first, .encoding("utf-8"))
        let names = options.map(TextEncodingChoices.name(of:))
        XCTAssertEqual(Array(names.prefix(2)), ["Automatic", "UTF-8"])

        var catalogNames: [String] = []
        for entry in TextEncodingCatalog.entries where !catalogNames.contains(entry.name) {
            catalogNames.append(entry.name)
        }
        XCTAssertEqual(Array(names.dropFirst(2)), catalogNames)
        XCTAssertEqual(Set(names).count, names.count, "no name is offered twice: \(names)")
        XCTAssertEqual(names.dropFirst(2).first, "Windows-1252 (Western European)")
        XCTAssertTrue(names.contains("Shift JIS (Japanese)"))
        XCTAssertTrue(names.contains("Big5 (Traditional Chinese)"))
    }

    /// A name the catalog gives Windows' variant and the standard alike is
    /// offered once, by its first entry, and a choice of it tries both, in
    /// the catalog's order; either recorded is shown as that one option.
    func testANameOfTwoEntriesIsOneOptionReadInEither() {
        XCTAssertEqual(TextEncodingChoices.identifiers(of: .encoding("big5")), ["big5", "cp950"])
        XCTAssertEqual(TextEncodingChoices.identifiers(of: .encoding("cp932")), ["cp932", "shift_jis"])
        XCTAssertEqual(TextEncodingChoices.identifiers(of: .encoding("koi8-r")), ["koi8-r"])
        XCTAssertEqual(TextEncodingChoices.identifiers(of: .encoding("utf-8")), ["utf-8"])
        XCTAssertEqual(TextEncodingChoices.identifiers(of: .automatic), [])

        XCTAssertEqual(TextEncodingChoices.option(forIdentifier: "cp950"), .encoding("big5"))
        XCTAssertEqual(TextEncodingChoices.option(forIdentifier: "big5"), .encoding("big5"))
        XCTAssertEqual(TextEncodingChoices.option(forIdentifier: "shift_jis"), .encoding("cp932"))
        XCTAssertEqual(TextEncodingChoices.option(forIdentifier: "UTF-8"), .encoding("utf-8"))
        XCTAssertNil(TextEncodingChoices.option(forIdentifier: "x-cp1999"))
    }

    /// The option of an encoding a file was read in: UTF-8's, a catalog
    /// name's, and none for an encoding no option names.
    func testTheOptionOfAnEncoding() throws {
        XCTAssertEqual(TextEncodingChoices.option(for: .utf8), .encoding("utf-8"))
        let cyrillic = try XCTUnwrap(TextFileDecoder.encoding(forLabel: "windows-1251"))
        XCTAssertEqual(TextEncodingChoices.option(for: cyrillic), .encoding("windows-1251"))
        XCTAssertNil(TextEncodingChoices.option(for: .utf16LittleEndian))
    }

    // MARK: - What a Book Is Read In

    /// A record's choice or guess is the reading, in words, without the file:
    /// a record of nothing, or of Automatic with nothing to record, leaves
    /// the file to say.
    func testTheReadingARecordGives() throws {
        let chosen = try XCTUnwrap(TextEncodingReading(record: TextEncodingRecord(identifier: "koi8-r", source: .chosen)))
        XCTAssertEqual(chosen.option, .encoding("koi8-r"))
        XCTAssertEqual(chosen.basis, .chosen)
        XCTAssertEqual(chosen.description, "KOI8-R (Russian), chosen")

        let guessed = try XCTUnwrap(TextEncodingReading(record: TextEncodingRecord(identifier: "cp950", source: nil)))
        XCTAssertEqual(guessed.option, .encoding("big5"))
        XCTAssertEqual(guessed.description, "Big5 (Traditional Chinese), guessed")

        let automatic = try XCTUnwrap(TextEncodingReading(record: TextEncodingRecord(identifier: "windows-1251", source: .automatic)))
        XCTAssertEqual(automatic.description, "Windows-1251 (Cyrillic), guessed", "Automatic's guess is a guess")

        XCTAssertEqual(TextEncodingReading(record: TextEncodingRecord(identifier: "utf-8", source: .chosen))?.description, "UTF-8, chosen")
        XCTAssertNil(TextEncodingReading(record: .unrecorded))
        XCTAssertNil(TextEncodingReading(record: TextEncodingRecord(identifier: nil, source: .automatic)))
    }

    /// What a file's bytes say, in words: a byte-order mark, UTF-16 without
    /// one, valid UTF-8, an HTML declaration (Latin 1 read as Windows-1252,
    /// and an encoding the catalog lacks named by its IANA name), the
    /// Windows-1252 default, and a guess.
    func testTheReadingTheBytesGive() throws {
        func reading(_ bytes: [UInt8], format: BookFormat = .txt, policy: TextFileDecoder.EncodingPolicy = .fallback) throws -> TextEncodingReading {
            TextEncodingReading(decoded: try TextFileDecoder.decode(
                Data(bytes), fileName: "Fixture.\(format.fileExtensions.first ?? "txt")", format: format, policy: policy
            ))
        }
        let utf16 = try reading([0xFF, 0xFE, 0x41, 0x00, 0xE9, 0x00])
        XCTAssertEqual(utf16.description, "UTF-16 (little-endian), from its byte order mark")
        XCTAssertNil(utf16.option, "no option names UTF-16")

        let markedUTF8 = try reading([0xEF, 0xBB, 0xBF, 0x41])
        XCTAssertEqual(markedUTF8.description, "UTF-8, from its byte order mark")
        XCTAssertEqual(markedUTF8.option, .encoding("utf-8"))

        XCTAssertEqual(try reading([0x41, 0x00, 0x42, 0x00]).description, "UTF-16 (little-endian), recognized by its bytes")
        XCTAssertEqual(try reading([0x43, 0x61, 0x66, 0xC3, 0xA9]).description, "UTF-8")

        func html(_ charset: String, _ body: [UInt8]) -> [UInt8] {
            Array("<meta charset=\"\(charset)\"><p>".utf8) + body
        }
        XCTAssertEqual(try reading(html("iso-8859-2", [0xB1]), format: .html).description, "ISO 8859-2 (Central European), declared in the file")
        XCTAssertEqual(try reading(html("iso-8859-1", [0xE9]), format: .html).description, "Windows-1252 (Western European), declared in the file")
        let baltic = try reading(html("iso-8859-4", [0xE9]), format: .html)
        XCTAssertNil(baltic.option)
        XCTAssertEqual(baltic.basis, .declared)
        XCTAssertTrue(baltic.description.hasSuffix(", declared in the file"), baltic.description)

        XCTAssertEqual(try reading([0x43, 0x61, 0x66, 0xE9]).description, "Windows-1252 (Western European), the default")

        // The Windows-1251 sample file's text, which the guesser names.
        let russian = "Съешь же ещё этих мягких французских булок, да выпей чаю.\nПаром отходит в семь.\n"
        let russian1251: [UInt8] = Array(try XCTUnwrap(
            russian.data(using: XCTUnwrap(TextFileDecoder.encoding(forLabel: "windows-1251")))
        ))
        XCTAssertEqual(try reading(russian1251, policy: .guess).description, "Windows-1251 (Cyrillic), guessed")
        XCTAssertEqual(try reading(russian1251, policy: .chosen("koi8-r")).description, "KOI8-R (Russian), chosen")
    }

    /// What a book in the library is read in now: a guessed book's record
    /// says it without its file; a book that records nothing has its file
    /// read; a file only in the cloud is never read, nor downloaded, to
    /// learn it; and a file that can't be read is said so.
    func testWhatABookIsReadInNow() throws {
        let guessed = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        XCTAssertEqual(TextEncodingReading.current(of: guessed).valueDescription, "KOI8-R (Russian), guessed")

        let unicode = try importedForTest(copyOfFormatSample("txt-encodings/utf-8.txt")).book
        XCTAssertEqual(TextEncodingReading.current(of: unicode).valueDescription, "UTF-8")
        let western = try importedForTest(copyOfFormatSample("txt-encodings/windows-1252.txt")).book
        XCTAssertEqual(TextEncodingReading.current(of: western).valueDescription, "Windows-1252 (Western European), the default")

        let inCloud = MaintenanceFileAccess(isDataless: { _ in true })
        XCTAssertEqual(TextEncodingReading.current(of: unicode, access: inCloud), .unknown("Not known until the book is downloaded"))
        // A file that goes to the cloud as it is read is refused the same way.
        let refused = MaintenanceFileAccess(isDataless: { _ in false }, refusesRead: { _ in true })
        XCTAssertEqual(TextEncodingReading.current(of: unicode, access: refused), .unknown("Not known until the book is downloaded"))

        try FileManager.default.removeItem(at: western.bookFileURL)
        XCTAssertEqual(TextEncodingReading.current(of: western), .unknown("Not known, since the file can't be read"))
        XCTAssertEqual(TextEncodingRowState.checking.valueDescription, "Checking the file")
    }

    // MARK: - Which Books

    /// A plain-text, Markdown, or HTML book from a file the listener added
    /// offers the pop-up, and so does one whose encoding is recorded; text
    /// typed in, a feed's article, and books of other formats do not.
    func testWhichBooksOfferAChoice() {
        func book(_ format: BookFormat, source: String?, encoding: String? = nil, feedItem: Bool = false) -> Book {
            Book(
                title: "Ledger", format: format, filePath: "/nowhere/Ledger", md5Hash: "hash",
                sourceFilePath: source, feedLink: feedItem ? FeedBookLink(feedID: UUID(), itemID: "item") : nil,
                textEncoding: encoding
            )
        }
        XCTAssertTrue(book(.txt, source: "/Users/someone/Ledger.txt").offersTextEncodingChoice)
        XCTAssertTrue(book(.markdown, source: "/Users/someone/Ledger.md").offersTextEncodingChoice)
        XCTAssertTrue(book(.html, source: "/Users/someone/Ledger.html").offersTextEncodingChoice)
        XCTAssertTrue(book(.txt, source: nil, encoding: "koi8-r").offersTextEncodingChoice, "added back from its marker")
        XCTAssertFalse(book(.txt, source: nil).offersTextEncodingChoice, "text typed in")
        XCTAssertFalse(book(.html, source: nil, feedItem: true).offersTextEncodingChoice, "a feed's article")
        XCTAssertFalse(book(.html, source: "/Users/someone/a.html", feedItem: true).offersTextEncodingChoice)
        XCTAssertFalse(book(.epub, source: "/Users/someone/Ledger.epub").offersTextEncodingChoice)
        XCTAssertFalse(book(.audio, source: "/Users/someone/Ledger.m4a").offersTextEncodingChoice)
        XCTAssertFalse(book(.braille, source: "/Users/someone/Ledger.brf").offersTextEncodingChoice)
    }

    // MARK: - The Words

    /// Each reading in words: the name, then what decided it; valid UTF-8 by
    /// its name alone.
    func testTheWordsOfAReading() {
        let name = "Windows-1251 (Cyrillic)"
        XCTAssertEqual(TextEncodingWording.describe(name: name, basis: .chosen), "Windows-1251 (Cyrillic), chosen")
        XCTAssertEqual(TextEncodingWording.describe(name: name, basis: .guessed), "Windows-1251 (Cyrillic), guessed")
        XCTAssertEqual(TextEncodingWording.describe(name: "UTF-8", basis: .byteOrderMark), "UTF-8, from its byte order mark")
        XCTAssertEqual(
            TextEncodingWording.describe(name: "UTF-16 (big-endian)", basis: .unmarkedUnicode), "UTF-16 (big-endian), recognized by its bytes"
        )
        XCTAssertEqual(TextEncodingWording.describe(name: "UTF-8", basis: .validUTF8), "UTF-8")
        XCTAssertEqual(TextEncodingWording.describe(name: name, basis: .declared), "Windows-1251 (Cyrillic), declared in the file")
        XCTAssertEqual(
            TextEncodingWording.describe(name: "Windows-1252 (Western European)", basis: .defaultEncoding),
            "Windows-1252 (Western European), the default"
        )
        XCTAssertEqual(TextEncodingWording.name(of: .utf32BigEndian), "UTF-32 (big-endian)")
    }

    /// The confirmation's title, message, and button, exactly.
    func testTheWordsOfTheConfirmation() {
        XCTAssertEqual(
            TextEncodingWording.confirmTitle(bookTitle: "Ledger", option: .encoding("cp932")),
            "Read “Ledger” again as Shift JIS (Japanese)?"
        )
        XCTAssertEqual(TextEncodingWording.confirmTitle(bookTitle: "Ledger", option: .automatic), "Read “Ledger” again automatically?")
        let places = "Your place and bookmarks move with their words. "
            + "Where none of their words are left, as when garbled letters become Cyrillic, "
            + "each goes to about the same point in its chapter, or to the nearest passage the two readings share."
        XCTAssertEqual(
            TextEncodingWording.confirmMessage(option: .encoding("cp932"), keepsText: false, stopsEditing: false),
            "Its text is replaced by the new reading. " + places
        )
        XCTAssertEqual(
            TextEncodingWording.confirmMessage(option: .automatic, keepsText: true, stopsEditing: false),
            "TextMouth reads its file as it reads a file you add: in the encoding the file names, or else the one TextMouth finds. "
                + "Its text is replaced by the new reading. " + places + " "
                + "An edit of its text is kept beside the new reading, as a copy in the book's package."
        )
        XCTAssertEqual(
            TextEncodingWording.confirmMessage(option: .encoding("cp932"), keepsText: true, stopsEditing: true),
            "Its text is replaced by the new reading. " + places + " "
                + "An edit of its text is kept beside the new reading, as a copy in the book's package. "
                + "Edit Text stops for this book; choose Edit Text again to edit the new reading."
        )
        XCTAssertEqual(TextEncodingWording.confirmButton, "Read Again")
    }

    /// Every refusal, and what VoiceOver hears once a book is read again.
    func testTheWordsOfARefusalAndOfDone() throws {
        XCTAssertEqual(TextEncodingWording.extractionRefusal, "TextMouth is reading the library's text again. Try again when that finishes.")
        XCTAssertEqual(
            TextEncodingWording.readingAgainRefusal(bookTitle: "Ledger"),
            "TextMouth is reading “Ledger” again in another encoding. Try again when that finishes."
        )
        XCTAssertEqual(TextEncodingWording.exportingRefusal(bookTitle: "Ledger"), "“Ledger” is being exported. Wait until the export ends, then try again.")
        XCTAssertEqual(
            TextEncodingWording.notValidRefusal(bookTitle: "Ledger", encoding: "Shift JIS (Japanese)"),
            "“Ledger” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding. Nothing was changed."
        )
        XCTAssertEqual(
            TextEncodingWording.editNotKeptRefusal(bookTitle: "Ledger"),
            "TextMouth couldn't keep the text you changed in “Ledger” beside the new reading, so it left the book as it was."
        )
        XCTAssertEqual(TextEncodingWording.failedRefusal(bookTitle: "Ledger", reason: nil), "TextMouth couldn't read “Ledger” again, so it left the book as it was.")
        XCTAssertEqual(
            TextEncodingWording.failedRefusal(bookTitle: "Ledger", reason: "The file is missing."),
            "TextMouth couldn't read “Ledger” again, so it left the book as it was: The file is missing."
        )
        XCTAssertEqual(TextEncodingWording.bookGoneRefusal, "The book is no longer in the library, so it was not read again.")

        let reading = try XCTUnwrap(TextEncodingReading(record: TextEncodingRecord(identifier: "cp932", source: .chosen)))
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(bookTitle: "Ledger", reading: reading, keptCopy: nil),
            "“Ledger” is now read as Shift JIS (Japanese), chosen."
        )
        let copy = URL(fileURLWithPath: "/library/Ledger.tmb/content.md.edited-20261024T120000Z")
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(bookTitle: "Ledger", reading: reading, keptCopy: copy),
            "“Ledger” is now read as Shift JIS (Japanese), chosen. "
                + "Its earlier text was kept as content.md.edited-20261024T120000Z, in the book's package."
        )
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(bookTitle: "Ledger", reading: nil, keptCopy: copy, stoppedEditing: true),
            "“Ledger” was read again. "
                + "Its earlier text was kept as content.md.edited-20261024T120000Z, in the book's package. "
                + "Edit Text has stopped for Ledger, since its file was read again. Choose Edit Text again to edit the new text."
        )
        // Replace Existing says where its copy went in the same words.
        XCTAssertEqual(
            DuplicateReplacement.keptTextAnnouncement(title: "Ledger", copy: copy),
            "Replaced “Ledger”. Its earlier text was kept as content.md.edited-20261024T120000Z, in the book's package."
        )
    }
}
