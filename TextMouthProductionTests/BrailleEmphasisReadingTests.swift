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
/// Each word keeps the emphasis its signs mark, which content.md holds as
/// Markdown emphasis (`BrailleBookReader.markdownLine(of:)`, every
/// punctuation character escaped).
///
/// **UEB.** liblouis reads UEB's indicators, but reads the contraction just
/// before a terminator as if no space could follow it: "people" (⠏) came
/// back as "p", "his" (⠦) as a double quote. The helper reads braille with a
/// terminator again without its terminators, for the words, keeping the
/// emphasis liblouis read.
final class BrailleEmphasisReadingTests: XCTestCase {
    /// The folder the helper's hidden files are made in.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// The bundled EBAE tables: uncontracted and contracted.
    private let ebaeUncontracted = "en-us-g1.ctb"
    private let ebaeContracted = "en_US.tbl"

    /// The bundled contracted UEB table, the app's default.
    private let uebContracted = "en-ueb-g2.ctb"

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

    /// Asserts that each of `samples`, braille ASCII and the Markdown line
    /// content.md holds for it, reads back as that line with `table`: the
    /// print, its emphasis as Markdown's, and every punctuation character
    /// escaped.
    private func assertReads(
        _ samples: [(braille: String, markdown: String)], _ table: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for sample in samples {
            let print = try read(sample.braille, table)
            XCTAssertEqual(BrailleBookReader.markdownLine(of: print), sample.markdown, "\(table): \(sample.braille)", file: file, line: line)
        }
    }

    /// Asserts that each of `samples`, braille ASCII and the print it holds,
    /// reads back as that print with `table`, whatever its emphasis.
    private func assertReadsWords(
        _ samples: [(braille: String, print: String)], _ table: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for sample in samples {
            XCTAssertEqual(try read(sample.braille, table).text, sample.print, "\(table): \(sample.braille)", file: file, line: line)
        }
    }

    // MARK: - EBAE

    /// Contracted EBAE as BANA writes it reads without a stray period, "=",
    /// or "µ", and keeps the emphasis its signs mark: a word's sign, a
    /// passage's (⠨⠨, then ⠨ before its last word, which ends it), bold's
    /// (⠸⠨, ⠸⠨⠨), a sign after opening punctuation, after a dash or a slash
    /// (which end a word's emphasis), and after a joined "to", "into", or
    /// "by" (which take a sign of their own), the termination sign ⠠⠄, and
    /// liblouis's own signs before punctuation. Before the pass the second
    /// sample read ".blue-eyed", and "6.me" read "µe", with no emphasis.
    func testContractedEBAEReadsWithoutStraySignsAndKeepsItsEmphasis() throws {
        try assertReads([
            (".,m>*", "*March*"),
            (".blue-ey$", #"*blue\-eyed*"#),
            (".,hold .! .bus6", #"*Hold the bus*\!"#),
            ("..,pl1se6 ,hold ! .bus6", #"*Please\! Hold the bus*\!"#),
            (",w[6 ..,look at page .#c4", #"Wow\! *Look at page 3*\."#),
            (#",%e ?"\3 ..,poor ,alice ,faye .re,y ne$s .t .job4"#, #"She thought\: *Poor Alice Faye really* needs *that job*\."#),
            (",? is .8 coat4", #"This is *his* coat\."#),
            (".,2 .c>e;l6", #"*Be careful*\!"#),
            (".96.t[n", "*into town*"),
            (".96!", "*into* the"),
            (",give x 6..hm1 n 6.me6", #"Give it to *him\, not to me*\!"#),
            (",0.default", "By *default*"),
            (".6,george", "*to* George"),
            (".,0.,george6", #"*By George*\!"#),
            ("..,6]r is .human4", #"*To err is human*\."#),
            (".,hel,'lo6", #"*Hel*lo\!"#),
            ("8.,help60 ! boy yell$4", #"\"*Help*\!\" the boy yelled\."#),
            (".,/op--.,n[6", #"*Stop* \-\- *Now*\!"#),
            (".&_/or", #"*and*\/or"#),
            (".&_/.or", #"*and*\/*or*"#),
            ("_.cat sat", "**cat** sat"),
            (#"_..one two ?ree f\r _.five4"#, #"**one two three four five**\."#),
            // liblouis's own signs: ⠨ again before a passage's punctuation,
            // and the termination sign before a word's.
            (#".."o two ?ree f\r .five.1 six"#, #"*one two three four five*\, six"#),
            (".s.d,'1 ;x", #"*sound*\, x"#),
            (#".."o two ?ree f\r .s.d.1 ;x"#, #"*one two three four sound*\, x"#),
        ], ebaeContracted)
    }

    /// Uncontracted EBAE reads without a stray period or "=" too, in BANA's
    /// signs and in liblouis's, and keeps its emphasis, bold italic too:
    /// liblouis writes bold's sign before italic's, so ⠸⠨⠨ is a bold word in
    /// italic unless a later word of the paragraph, its fourth or after,
    /// closes it as a bold passage. Before the pass ".kite" read "=ite", and
    /// ".five.1" read ".five>".
    func testUncontractedEBAEReadsWithoutStraySignsAndKeepsItsEmphasis() throws {
        try assertReads([
            (";a .cat sat", "a *cat* sat"),
            ("..one two three four .five1 six", #"*one two three four five*\, six"#),
            ("..it was not at .all4", #"*it was not at all*\."#),
            (".one .two .three four", "*one two three* four"),
            (".,march", "*March*"),
            ("8.,help60 the boy yelled4", #"\"*Help*\!\" the boy yelled\."#),
            (".cat,''s", #"*cat*\'s"#),
            ("_..one two three four _.five4", #"**one two three four five**\."#),
            (".cat-dog", #"*cat\-dog*"#),
            (".cat,'-dog", #"*cat*\-dog"#),
            (".kite flew", "*kite* flew"),
            ("..one two three four .five.1 six", #"*one two three four five*\, six"#),
            (".cat,'1 sat", #"*cat*\, sat"#),
            ("_..cat sat", "***cat*** sat"),
            ("_..one _..two three", "***one two*** three"),
            ("..one _.two three four .five six", "*one* ***two*** *three four five* six"),
            ("_....one two three four _..five._.1 six", #"***one two three four five***\, six"#),
        ], ebaeUncontracted)
    }

    /// Contracted EBAE joins words that print spaces apart, and the pass
    /// reads them as print's words: "into" joined to "into" before "mother"
    /// (⠔⠖⠔⠖⠐⠍) takes the sign before it alone, as a joined "to" does; a
    /// bold passage counts "to the" (⠖⠮) and "into out" (⠔⠖⠳⠞) as two words
    /// each, so that four words of print make a passage, as liblouis wrote
    /// them, where three braille words had read as a bold italic word and a
    /// bold one. ⠨⠅, which liblouis writes both for "=" and for "knowledge"
    /// emphasized, closes an open italic passage as its last word, which had
    /// run on to the paragraph's end, and reads "=" elsewhere.
    func testContractedEBAEReadsJoinedWordsAndAPassageEndingInKnowledge() throws {
        try assertReads([
            (#".9696"m"#, "*into* into mother"),
            ("_..g 6! _./ore n[", "**go to the store** now"),
            (#"_.."n 96\ _.d "y"#, "**name into out do** young"),
            (#".."o two ?ree .k n["#, "*one two three knowledge* now"),
            (".k n[", #"\= now"#),
        ], ebaeContracted)
    }

    /// A contraction that liblouis reads with what follows it, past the place
    /// its emphasis ends, has its characters split there: contracted EBAE
    /// reads "can't" (⠉⠄⠞) as one rule, so with "can" emphasized
    /// (⠨⠉⠠⠄⠄⠞) all of "can't" came back italic; now its "can" is, and its
    /// "'t" is not. A rule whose cells share one emphasis is not split.
    func testARuleReadAcrossAnEmphasisEndIsSplitWhereTheEmphasisEnds() throws {
        try assertReads([
            ("a .c,''t", #"a *can*\'t"#),
            ("a _.c,''t", #"a **can**\'t"#),
            ("a .c't is", #"a *can\'t* is"#),
        ], ebaeContracted)
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
        try assertReadsWords([(".s.d is", "sound is"), ("a .b.d book", "a bound book"), ("a .k ;b", "a = b")], ebaeContracted)
        try assertReadsWords([(";a .k ;b", "a = b")], ebaeUncontracted)
    }

    /// Computer braille, between EBAE's indicators ⠸⠬ and ⠸⠱ (liblouis's
    /// around a web or mail address), holds no emphasis sign: its ⠨ is a
    /// period, kept even where the address is a passage's last word, whose
    /// periods had been taken for liblouis's end sign ("a*b.com").
    func testEBAELeavesComputerBrailleAsItIs() throws {
        try assertReads([
            (#".."o two ?ree ._+a.b.com_: n["#, #"*one two three a\.b\.com* now"#),
            ("see _+a.b.com_: n[", #"see a\.b\.com now"#),
        ], ebaeContracted)
        try assertReads([("..one two three ._+a.b.com_: now", #"*one two three a\.b\.com* now"#)], ebaeUncontracted)
    }

    // MARK: - UEB

    /// Contracted UEB reads the contraction before a terminator as the word
    /// it is: the review's six cases (E1), as liblouis writes them, which
    /// read "p", "K", "c", a double quote, a prime, and "en" before; bold's
    /// terminator ⠘⠄ as italic's ⠨⠄, and both in a row for bold italic
    /// (which read "***p***"). "people's" and "can't", each one rule, are
    /// split where the emphasis ends. A terminator inside a word ("*the*n",
    /// "un*believ*able") ends the emphasis there, as it did.
    func testContractedUEBReadsTheContractionBeforeATerminator() throws {
        try assertReads([
            (".1p.''s sake", #"*people*\'s sake"#),
            ("! .1,k.''s keep]", #"the *Knowledge*\'s keeper"#),
            ("a .1c.''t", #"a *can*\'t"#),
            ("gave !m .7all ( 8.' ?+s", "gave them *all of his* things"),
            (#".7t !y 7.' "h"#, "*that they were* here"),
            (".7,x 0 5.'", "*It was enough*"),
            ("!y .1w]e.'1 &", #"they *were*\, and"#),
            ("^1p^''s sake", #"**people**\'s sake"#),
            ("gave !m ^7all ( 8^' ?+s", "gave them **all of his** things"),
            ("! ^1.1p.'^''s sake", #"the ***people***\'s sake"#),
            (".1!.'n", "*the*n"),
            ("un.1believ.'able", "un*believ*able"),
        ], uebContracted)
    }

    /// UEB braille without a terminator is read once, by liblouis alone, as
    /// before: a word indicator (⠨⠂) and a symbol indicator (⠨⠆) mark their
    /// word and letter, and plain braille reads plain.
    func testUEBWithoutATerminatorReadsAsBefore() throws {
        try assertReads([
            (".1p is", "*people* is"),
            (".2a ;b", "*a* b"),
            ("= ! p's sake", #"for the people\'s sake"#),
        ], uebContracted)
    }
}
