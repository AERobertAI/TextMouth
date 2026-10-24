import XCTest
@testable import TextMouth

/// The braille helper's reading passes (October 24, 2026,
/// `TextMouthBraille/main.c`): emphasis signs read before liblouis reads the
/// braille back, so that its words are the words the braille holds.
///
/// **EBAE.** liblouis 3.39.0 reads EBAE's emphasis sign ⠨ before a word as a
/// period before the letters a to j (".cat"), as "=" before k, as "µ" before
/// m, and the sign it writes again after a passage, before punctuation, as
/// ">"; BARD's EBAE books read so too. The helper reads the signs itself, as
/// BANA's rules write them (the Library of Congress's Instruction Manual for
/// Braille Transcribing, fifth edition, lesson 15, whose examples most of
/// the contracted samples are), and gives liblouis the braille without them.
final class BrailleEmphasisReadingTests: XCTestCase {
    /// The folder the helper's hidden files are made in.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// The bundled EBAE tables: uncontracted and contracted.
    private let ebaeUncontracted = "en-us-g1.ctb"
    private let ebaeContracted = "en_US.tbl"

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleEmphasisReading")
    }

    // MARK: - Helpers

    /// The braille `ascii` (braille ASCII, a space for the blank cell, in
    /// either case) read back to print with `table`, as a braille book's
    /// paragraph is.
    private func read(_ ascii: String, _ table: String) throws -> EmphasizedText {
        let print = try BrailleTranslator.translate(
            [EmphasizedText(brailleCells(ascii))], table: table, direction: .brailleToPrint, workingIn: work
        )
        return try XCTUnwrap(print.first, "\(table): \(ascii)")
    }

    /// Asserts that each of `samples`, braille ASCII and the print it holds,
    /// reads back as that print with `table`.
    private func assertReads(
        _ samples: [(braille: String, print: String)], _ table: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for sample in samples {
            XCTAssertEqual(try read(sample.braille, table).text, sample.print, "\(table): \(sample.braille)", file: file, line: line)
        }
    }

    // MARK: - EBAE: The Words

    /// Contracted EBAE as BANA writes it reads without a stray period, "=",
    /// or "µ": a word's sign, a passage's (⠨⠨, then ⠨ before its last word),
    /// bold's (⠸⠨, ⠸⠨⠨), a sign after opening punctuation, after a dash or a
    /// slash, and after a joined "to", "into", or "by", the termination sign
    /// ⠠⠄, and liblouis's own signs before punctuation. Before this pass the
    /// first sample read ".blue-eyed", and "6.me" read "µe".
    func testContractedEBAEReadsWithoutStraySigns() throws {
        try assertReads([
            (".,m>*", "March"),
            (".blue-ey$", "blue-eyed"),
            (".,hold .! .bus6", "Hold the bus!"),
            ("..,pl1se6 ,hold ! .bus6", "Please! Hold the bus!"),
            (",w[6 ..,look at page .#c4", "Wow! Look at page 3."),
            (#",%e ?"\3 ..,poor ,alice ,faye .re,y ne$s .t .job4"#, "She thought: Poor Alice Faye really needs that job."),
            (",? is .8 coat4", "This is his coat."),
            (".,2 .c>e;l6", "Be careful!"),
            (".96.t[n", "into town"),
            (",give x 6..hm1 n 6.me6", "Give it to him, not to me!"),
            (",0.default", "By default"),
            (".6,george", "to George"),
            (".,0.,george6", "By George!"),
            ("..,6]r is .human4", "To err is human."),
            (".,hel,'lo6", "Hello!"),
            ("8.,help60 ! boy yell$4", "\"Help!\" the boy yelled."),
            (".,/op--.,n[6", "Stop -- Now!"),
            (".&_/.or", "and/or"),
            ("_.cat sat", "cat sat"),
            (#"_..one two ?ree f\r _.five4"#, "one two three four five."),
            // liblouis's own signs: ⠨ again before a passage's punctuation,
            // and the termination sign before a word's.
            (#".."o two ?ree f\r .five.1 six"#, "one two three four five, six"),
            (".s.d,'1 ;x", "sound, x"),
            (#".."o two ?ree f\r .s.d.1 ;x"#, "one two three four sound, x"),
        ], ebaeContracted)
    }

    /// Uncontracted EBAE reads without a stray period or "=" too, in BANA's
    /// signs and in those liblouis writes. Before this pass ".kite" read
    /// "=ite", and ".five.1" read ".five>".
    func testUncontractedEBAEReadsWithoutStraySigns() throws {
        try assertReads([
            (";a .cat sat", "a cat sat"),
            ("..one two three four .five1 six", "one two three four five, six"),
            ("..it was not at .all4", "it was not at all."),
            (".one .two .three four", "one two three four"),
            (".,march", "March"),
            ("8.,help60 the boy yelled4", "\"Help!\" the boy yelled."),
            (".cat,''s", "cat's"),
            ("_..one two three four _.five4", "one two three four five."),
            (".cat-dog", "cat-dog"),
            (".cat,'-dog", "cat-dog"),
            (".kite flew", "kite flew"),
            ("..one two three four .five.1 six", "one two three four five, six"),
            (".cat,'1 sat", "cat, sat"),
        ], ebaeUncontracted)
    }

    /// What is not a sign is left as liblouis reads it: ⠨ inside a number,
    /// the decimal point, so an emphasized number reads as the same number
    /// plain (liblouis's own reading of EBAE decimals, "3.e", is kept); ⠨
    /// beginning a contraction inside a word ("sound", "bound"); and ⠨⠅
    /// standing alone, which liblouis writes for "=" (and contracted EBAE for
    /// "knowledge" emphasized too).
    func testEBAELeavesWhatIsNoSign() throws {
        XCTAssertEqual(try read(".#c.e", ebaeUncontracted).text, try read("#c.e", ebaeUncontracted).text)
        XCTAssertEqual(try read("! .#c.e cats", ebaeContracted).text, try read("! #c.e cats", ebaeContracted).text)
        try assertReads([(".s.d is", "sound is"), ("a .b.d book", "a bound book"), ("a .k ;b", "a = b")], ebaeContracted)
        try assertReads([(";a .k ;b", "a = b")], ebaeUncontracted)
    }
}
