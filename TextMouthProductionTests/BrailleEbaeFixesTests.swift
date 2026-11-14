import XCTest
@testable import TextMouth

/// The braille helper's fixes of what contracted EBAE's table misreads (November
/// 13, 2026, `fix_ebae_cells` in `TextMouthBraille/main.c`): found reading a
/// 2003 transcription of a novel in the old code with liblouis's tables. Every
/// sample is braille ASCII invented for the test, not a line of any book. Each
/// test also reads the same cells by liblouis alone (the helper's
/// `back-liblouis`), where the sample reads wrong, so that a test that passes
/// with the fix removed would be caught.
final class BrailleEbaeFixesTests: XCTestCase {
    /// The folder the helper's hidden files are made in.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// Contracted EBAE, the table the fixes are for, and uncontracted EBAE
    /// and UEB, which they leave as liblouis reads them.
    private let contracted = "en_US.tbl"
    private let uncontracted = "en-us-g1.ctb"
    private let ueb = "en-ueb-g2.ctb"

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleEbaeFixes")
    }

    // MARK: - Helpers

    /// The braille `ascii` (braille ASCII, a space for the blank cell) read
    /// back to print with `table`, by the helper, as a braille book's paragraph.
    private func read(_ ascii: String, _ table: String, liblouisAlone: Bool = false) throws -> EmphasizedText {
        let helper = BrailleTranslator.Tool.helper
        var tool = helper
        tool.command = { mode, table, input, output in
            helper.command(liblouisAlone && mode == "back" ? "back-liblouis" : mode, table, input, output)
        }
        let print = try BrailleTranslator.$tool.withValue(tool) {
            try BrailleTranslator.translate(
                [EmphasizedText(brailleCells(ascii))], table: table, direction: .brailleToPrint, workingIn: work
            )
        }
        return try XCTUnwrap(print.first, "\(table): \(ascii)")
    }

    /// Asserts that each braille sample reads as its print with contracted
    /// EBAE, and that liblouis alone reads it as something else.
    private func assertFixed(
        _ samples: [(braille: String, print: String)], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for sample in samples {
            XCTAssertEqual(try read(sample.braille, contracted).text, sample.print, sample.braille, file: file, line: line)
            XCTAssertNotEqual(
                try read(sample.braille, contracted, liblouisAlone: true).text, sample.print,
                "liblouis alone: \(sample.braille)", file: file, line: line
            )
        }
    }

    /// Asserts that each braille sample reads as its print with contracted EBAE
    /// as liblouis reads it too: the fix leaves it alone.
    private func assertUnchanged(
        _ samples: [(braille: String, print: String)], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for sample in samples {
            XCTAssertEqual(try read(sample.braille, contracted).text, sample.print, sample.braille, file: file, line: line)
            XCTAssertEqual(
                try read(sample.braille, contracted, liblouisAlone: true).text, sample.print,
                "liblouis alone: \(sample.braille)", file: file, line: line
            )
        }
    }

    // MARK: - Wordsigns written together

    /// EBAE writes "of the", "and the", "of a", "with a", "for the", and
    /// "with the" as one unit of cells; the table read "ofthe". A run of
    /// those cells alone is spaced into words, also after an opening quotation
    /// mark, before a comma, and after a capital sign.
    func testRunTogetherWordsignsReadAsWords() throws {
        try assertFixed([
            ("(!", "of the"), ("&!", "and the"), (")A", "with a"), ("=!", "for the"), (")!", "with the"), ("(A", "of a"),
            ("8(!0", "\"of the\""), ("(!1", "of the,"), (",(!", "Of the"), ("(!(A", "of the of a"),
        ])
    }

    /// A lone wordsign, a run of "a" cells, and every table that is not
    /// contracted EBAE read as liblouis reads them.
    func testWordsignsAloneAndOtherTablesAreLeftAlone() throws {
        try assertUnchanged([("(", "of"), ("!", "the"), ("A", "a"), ("AA", "aa")])
        for table in [uncontracted, ueb] {
            XCTAssertEqual(
                try read("(!", table).text, try read("(!", table, liblouisAlone: true).text, table
            )
        }
    }

    // MARK: - "ing" before a hyphen

    /// "ing" (⠬) before a hyphen (⠤) read "±" with the table; it reads "ing".
    func testIngBeforeAHyphenIsNotPlusMinus() throws {
        try assertFixed([("MOV+-IN", "moving-in"), ("SMIL+-", "smiling-")])
        try assertUnchanged([("MOV+", "moving"), ("MOV+ IN", "moving in")])
    }

    // MARK: - Initials

    /// A period (⠲) between single letters read "dd"; initials read with
    /// their periods, each letter a word of its own so that "p" is no "people".
    func testPeriodsBetweenInitialsAreNotDD() throws {
        try assertFixed([("P4B4U4H4", "p. b. u. h."), (",L4,A4", "L. A."), ("E4G4", "e. g.")])
    }

    /// Words that hold "dd" between letters are not initials.
    func testDDInsideWordsStays() throws {
        try assertUnchanged([("A4RESS", "address"), (",A4Y", "Addy"), ("LA4ER", "ladder")])
    }

    // MARK: - Still and St.

    /// ⠌⠲ read "St." always. It reads "Still." unless a capital sign and a
    /// capitalized word make it "St.".
    func testStillIsNotAlwaysSt() throws {
        try assertFixed([(",/4", "Still."), ("/4", "still."), (",/4 ,/4", "St. Still.")])
        try assertUnchanged([(",/4 ,P", "St. People")])
    }

    /// "Main St." at the end of a record stays "St." (cells liblouis wrote for
    /// the print), and "Still." after a sentence's end or alone reads "Still.".
    func testStAtTheEndOfARecordStaysSt() throws {
        try assertUnchanged([(",ma9 ,/4", "Main St."), ("a ,ma9 ,/4 &", "a Main St. and")])
        try assertFixed([(",d\"o4 ,/4", "Done. Still."), (",/4", "Still.")])
    }

    // MARK: - Before inside a word

    /// ⠆⠋ inside a word read "before"; it reads "bef", except in the compounds
    /// of "before".
    func testBeforeInsideAWordIsBef() throws {
        try assertFixed([("2FU4LED", "befuddled"), ("2FELL", "befell"), (",2FELL", "Befell")])
        try assertUnchanged([("2F", "before"), ("2F1", "before,"), ("2FH&", "beforehand"), ("2FTIME", "beforetime")])
    }

    // MARK: - Emphasized words that begin with m

    /// ⠨⠍ read "µ" before a word of letters; it is the emphasis sign, with
    /// its emphasis. A lone "µ", a unit after a number, and a sign inside a
    /// word stay "µ".
    func testItalicWordsBeginningWithMAreNotMicro() throws {
        let mama = try read(".MAMA", contracted)
        XCTAssertEqual(mama.text, "mama")
        XCTAssertTrue(mama.hasEmphasis)
        XCTAssertEqual(try read(".MAMA", contracted, liblouisAlone: true).text, "µama")
        XCTAssertEqual(try read(".ME", contracted).text, "me")
        XCTAssertEqual(try read("..,ONE .MAMA TWO THREE .MAMA1", contracted).text, "One mama two three mama,")
        // "a µzoo" is written ⠨⠍⠵⠕⠕, and is an emphasized "mzoo" for contracted EBAE.
        XCTAssertEqual(try read("A .MZOO", contracted).text, "a mzoo")
        XCTAssertTrue(try read("A .MZOO", contracted).hasEmphasis)
    }

    /// Micro as liblouis writes it (cells from its forward translation of
    /// the print on the right, on this table) stays micro: before a unit's
    /// letter sign ⠰, before a capital letter, before "mol", and after a
    /// number or a slash.
    func testMicroAsLiblouisWritesItStaysMicro() throws {
        for sample in [
            ("7.m;m7", "(µm)"), (".m;g_/m,l", "µg/mL"), ("a few .m;m", "a few µm"), (".m;,l", "µL"),
            (".m,hz", "µHz"), (".m,a", "µA"), (".m;,v", "µV"), (".mmol", "µmol"), ("#e .mmol", "5 µmol"),
            ("km_/.m;s", "km/µs"), ("#e .m;g ( salt", "5 µg of salt"), (".M", "µ"),
        ] {
            XCTAssertEqual(try read(sample.0, contracted).text, sample.1, sample.0)
        }
    }

    /// Uncontracted EBAE is read as liblouis reads it: ⠨⠍ before a word is micro.
    func testUncontractedEBAEKeepsMicroBeforeAWord() throws {
        XCTAssertEqual(try read(";a .mzoo", uncontracted).text, "a µzoo")
        XCTAssertEqual(try read("#e .m;g of salt", uncontracted).text, "5 µg of salt")
    }
}
