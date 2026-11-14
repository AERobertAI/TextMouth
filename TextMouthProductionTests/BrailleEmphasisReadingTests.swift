import XCTest
@testable import TextMouth

/// The braille helper's reading passes (October 24, 2026,
/// `TextMouthBraille/main.c`): emphasis signs read before liblouis reads the
/// braille back.
///
/// **EBAE.** liblouis 3.39.0 reads EBAE's emphasis sign ⠨ before a word as a
/// period before the letters a to j (".cat"), as "=" before k, and as "µ"
/// before m, and drops it silently before the other letters, which loses
/// the emphasis. Those readings are its own EBAE's too: it writes a period
/// before a word, "=", ">", and "µ" with ⠨, so where ⠨ could be one of them
/// the braille cannot tell a sign from print. The pass therefore reads a
/// sign only where liblouis drops it anyway (review, October 24, 2026): every
/// word reads as it read before, and the emphasis is added where the sign is
/// sure. A stray period before an emphasized word beginning a to j stays.
/// Leaving a sign out can still change how liblouis reads the cells around
/// it, so a paragraph the pass would read with any other character reads
/// as liblouis reads it alone, without its emphasis (the safety net,
/// verifier, October 24, 2026).
/// Most contracted samples are the examples of the Library of Congress's
/// Instruction Manual for Braille Transcribing, fifth edition, lesson 15,
/// as BANA writes them; content.md holds the emphasis as Markdown's
/// (`BrailleBookReader.markdownLine(of:)`, every punctuation character
/// escaped).
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

    /// What `body` returns with the bundled helper reading braille back by
    /// liblouis alone, without the reading passes, when `liblouisAlone`
    /// (its test-only `back-liblouis`), and loading the table file `file`,
    /// when given, in place of the table named: en_US.tbl's own
    /// en-us-g2.ctb, which TextMouth does not offer.
    private func withHelper<T>(liblouisAlone: Bool, file: String?, _ body: () throws -> T) throws -> T {
        let helper = BrailleTranslator.Tool.helper
        var tool = helper
        tool.command = { mode, table, input, output in
            guard var command = helper.command(liblouisAlone && mode == "back" ? "back-liblouis" : mode, table, input, output) else {
                return nil
            }
            if let file { command.arguments = command.arguments.map { $0 == table ? file : $0 } }
            return command
        }
        return try BrailleTranslator.$tool.withValue(tool, operation: body)
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

    /// Contracted EBAE as BANA writes it reads with liblouis's words, and with
    /// the emphasis of each sign the pass can tell from print: a word's sign,
    /// a passage's (⠨⠨, then ⠨ before its last word, which ends it), bold's
    /// (⠸⠨, ⠸⠨⠨), a sign after opening punctuation, after a dash or a slash
    /// (which end a word's emphasis), and after a joined "to", "into", or "by",
    /// and the termination sign ⠠⠄. Before the letters a to j, k, and m,
    /// liblouis reads ⠨ as a period, "=", or "µ", as it writes them, so the
    /// sign is left and the word reads as before (".blue-eyed", ".bus", "µe");
    /// a passage's last sign there still ends the passage.
    func testContractedEBAEReadsItsWordsAsBeforeWithTheEmphasisItCanTell() throws {
        try assertReads([
            (".,m>*", "*March*"),
            (".blue-ey$", #"\.blue\-eyed"#),
            (".,hold .! .bus6", #"*Hold the* \.bus\!"#),
            ("..,pl1se6 ,hold ! .bus6", #"*Please\! Hold the \.bus*\!"#),
            (",w[6 ..,look at page .#c4", #"Wow\! *Look at page 3*\."#),
            (#",%e ?"\3 ..,poor ,alice ,faye .re,y ne$s .t .job4"#, #"She thought\: *Poor Alice Faye really* needs *that* \.job\."#),
            (",? is .8 coat4", #"This is \.\" coat\."#),
            (".,2 .c>e;l6", #"*Be* \.careful\!"#),
            (".96.t[n", #"\.into town"#),
            (",give x 6..hm1 n 6.me6", #"Give it to *him\, not to µe*\!"#),
            (",0.default", #"By \.default"#),
            (".,0.,george6", #"*By George*\!"#),
            ("..,6]r is .human4", #"*To err is \.human*\."#),
            (".,hel,'lo6", #"*Hel*lo\!"#),
            ("8.,help60 ! boy yell$4", #"\"*Help*\!\" the boy yelled\."#),
            (".,/op--.,n[6", #"*Stop* \-\- *Now*\!"#),
            (".&_/or", #"*and*\/or"#),
            (".&_/.or", #"*and*\/*or*"#),
            ("_.cat sat", "**cat** sat"),
            (#"_..one two ?ree f\r _.five4"#, #"**one two three four five**\."#),
            (".zoo sat", "*zoo* sat"),
            ("_.zoo sat", "**zoo** sat"),
            (".,zoo is", "*Zoo* is"),
            // liblouis's own signs before punctuation: the termination sign,
            // read, and ⠨, which before a comma it reads as ">", left.
            (".s.d,'1 ;x", #"*sound*\, x"#),
            (#".."o two ?ree f\r .five.1 six"#, #"*one two three four \.five*\> six"#),
        ], ebaeContracted)
    }

    /// Uncontracted EBAE reads its words as before too, with the emphasis the
    /// pass can tell: before "cat", "five", and "all" the sign stays, as the
    /// period liblouis reads it as, and before "kite" as "="; a passage's
    /// last sign still ends it; a bold word in an italic passage, and
    /// "*ABCs*", whose termination sign ends only the capitals, keep theirs.
    func testUncontractedEBAEReadsItsWordsAsBeforeWithTheEmphasisItCanTell() throws {
        try assertReads([
            (";a .cat sat", #"a \.cat sat"#),
            ("..one two three four .five1 six", #"*one two three four \.five*\, six"#),
            ("..it was not at .all4", #"*it was not at \.all*\."#),
            (".one .two .three four", "*one two three* four"),
            (".,march", "*March*"),
            ("8.,help60 the boy yelled4", #"\"*Help*\!\" the boy yelled\."#),
            (".cat,''s", #"\.cat\'s"#),
            ("_..one two three four _.five4", #"**one two three four five**\."#),
            (".kite flew", #"\=ite flew"#),
            ("..one _.two three four .five six", #"*one* ***two*** *three four \.five* six"#),
            ("..no more of the .zoo4", #"*no more of the zoo*\."#),
            (".,,abc,'s", "*ABCs*"),
        ], ebaeUncontracted)
    }

    /// BANA's EBAE has no sign for bold italic, and liblouis's, bold's sign
    /// before italic's, is not read as one: ⠸⠨⠨ is a bold passage's sign,
    /// and more ⠨ than that are left to liblouis. Its words read as before,
    /// whatever the emphasis.
    func testLiblouisBoldItalicSignsKeepTheirWords() throws {
        try assertReadsWords([
            ("_..cat sat", "cat sat"),
            ("_..one _..two three", "one two three"),
            ("_....one two three four _..five._.1 six", "one two three four five, six"),
        ], ebaeUncontracted)
    }

    /// Contracted EBAE joins words that print spaces apart. "into" joined
    /// to "into" before "mother" (⠔⠖⠔⠖⠐⠍) reads as before, ".into", since ⠨
    /// before "in" is liblouis's period; a bold passage of joined words
    /// ("to the", "into out") reads as one; and ⠨⠅, which liblouis writes
    /// both for "=" and for "knowledge" emphasized, reads "=", ending a
    /// passage open before it.
    func testContractedEBAEReadsJoinedWordsAndTheKnowledgeSign() throws {
        try assertReads([
            (#".9696"m"#, #"\.into into mother"#),
            ("_..g 6! _./ore n[", "**go to the store** now"),
            (#"_.."n 96\ _.d "y"#, "**name into out do** young"),
            (#".."o two ?ree .k n["#, #"*one two three* \= now"#),
            (".k n[", #"\= now"#),
        ], ebaeContracted)
    }

    /// The verifier's cases (October 24, 2026), which the pass read with
    /// other words than main (e110d985), read main's words. A: contracted
    /// EBAE reads "(" ⠶ and "be" ⠆ together as "}" once a passage or bold
    /// sign between them is gone ("}from the old one went)", "}can)"), so
    /// the safety net reads them as liblouis does alone, without their
    /// emphasis. B: double capitals begun inside a word end at their
    /// termination sign, which the pass had taken for emphasis's ("X-RAYS").
    /// C: a termination sign left out had joined a word's parts into one
    /// contraction ("perhapsaps", "besideide"), and turned main's "c't"
    /// into "can't"; it is kept for liblouis now. B and C keep their
    /// emphasis.
    func testTheVerifiersCasesReadMainsWords() throws {
        try assertReads([
            (#"7..2f ! old "o .w5t7"#, #"\(before the old one went\)"#),
            ("7_.2c7", #"\(because\)"#),
            (#"7_..2f ! old "o _.w5t7"#, #"\(before the old one went\)"#),
            (".;,x-,,ray,'s", #"*X\-RAYs*"#),
            (".,mc,,donald,'s", "*McDONALDs*"),
            (".p],'haps", "*per*haps"),
            ("_.2,'side", "**be**side"),
            ("a _.c,''t", #"a **c**\'t"#),
        ], ebaeContracted)
        try assertReads([
            (".;,x-,,ray,'s", #"*X\-RAYs*"#),
            (".,mc,,donald,'s", "*McDONALDs*"),
            (".per,'haps", "*per*haps"),
            ("_.be,'side", "**be**side"),
        ], ebaeUncontracted)
    }

    /// The safety net takes only its own paragraph's emphasis: a paragraph
    /// whose words the pass would change reads as liblouis reads it alone,
    /// with no emphasis, while the next one, whose signs the pass leaves out
    /// without changing a word, keeps the emphasis they mark.
    func testTheSafetyNetTakesOnlyItsOwnParagraphsEmphasis() throws {
        let paragraphs = [#"7..2f ! old "o .w5t7"#, ".,mc,,donald,'s is"].map { EmphasizedText(brailleCells($0)) }
        let print = try BrailleTranslator.translate(paragraphs, table: ebaeContracted, direction: .brailleToPrint, workingIn: work)
        XCTAssertEqual(print.map(BrailleBookReader.markdownLine(of:)), [#"\(before the old one went\)"#, "*McDONALDs* is"])
        XCTAssertFalse(print.first?.hasEmphasis ?? true)
    }

    /// BANA's signs never change a word: 3,000 seeded sentences with real
    /// signs in each EBAE table (`BANASentenceGenerator`) read back with
    /// exactly the words liblouis reads alone from the same braille, case
    /// included, as main (e110d985) read them (the helper's test-only
    /// `back-liblouis`), and at least two in three keep emphasis. Before the
    /// safety net, the verifier's 24,000 such sentences read other words in
    /// 52 (October 24, 2026). The third table is en-us-g2.ctb, which
    /// en_US.tbl includes and TextMouth does not offer, read through the
    /// bundled helper by its file name.
    func testBANAEmphasisReadsLiblouissOwnWords() throws {
        let tables: [(name: String, file: String?)] = [(ebaeUncontracted, nil), (ebaeContracted, nil), (ebaeContracted, "en-us-g2.ctb")]
        for table in tables {
            let label = table.file ?? table.name
            let pieces = BANASentenceGenerator.pieces
            let braille = try withHelper(liblouisAlone: false, file: table.file) {
                try BrailleTranslator.translate(pieces, table: table.name, direction: .printToBraille, workingIn: work)
            }
            var generator = BANASentenceGenerator(
                seed: 20_261_024, braille: Dictionary(zip(pieces, braille), uniquingKeysWith: { first, _ in first }),
                contracted: table.name == ebaeContracted
            )
            let sentences = (0..<3_000).map { _ in EmphasizedText(generator.sentence()) }
            let read = try withHelper(liblouisAlone: false, file: table.file) {
                try BrailleTranslator.translate(sentences, table: table.name, direction: .brailleToPrint, workingIn: work)
            }
            let alone = try withHelper(liblouisAlone: true, file: table.file) {
                try BrailleTranslator.translate(sentences, table: table.name, direction: .brailleToPrint, workingIn: work)
            }
            // liblouis alone reads an emphasized word that begins with m as
            // "µ" and the rest (the sentences hold no print "µ"); the pass
            // reads the sign, except after a number, where a unit is likelier
            // (November 13, 2026, `is_sign_before_m_word`). So "µ" is "m" in
            // both readings.
            let micro = { (text: String) in text.replacingOccurrences(of: "\u{B5}", with: "m") }
            // liblouis alone also reads "ing" and a hyphen before another hyphen
            // as "±" and a hyphen ("someth±-aunt"), which the helper's own fix
            // reads as "ing" and a dash, spaced ("something -- aunt")
            // (November 13, 2026); so "±-" is "ing -- " in the alone reading.
            let plusMinus = { (text: String) in
                text.replacingOccurrences(of: "\u{B1}-", with: "ing -- ").replacingOccurrences(of: "\u{B1}", with: "ing-")
            }
            let changed = zip(read, alone).filter { micro($0.text) != micro(plusMinus($1.text)) }
            XCTAssertEqual(read.count, sentences.count, label)
            XCTAssertEqual(alone.count, sentences.count, label)
            XCTAssertEqual(changed.count, 0, "\(label): \(changed.prefix(5).map { "\($0.1.text) → \($0.0.text)" })")
            XCTAssertGreaterThan(read.filter(\.hasEmphasis).count, sentences.count * 2 / 3, label)
        }
    }

    /// What is no sign reads exactly as liblouis read it before the pass
    /// (main, e110d985): ⠨ inside a number, the decimal point ("3.e" for 3.5,
    /// liblouis's own reading), ⠨ beginning a contraction inside a word
    /// ("sound", ".bound"), and ⠨⠅ standing alone, liblouis's "=".
    func testEBAELeavesWhatIsNoSign() throws {
        try assertReadsWords([(".#c.e", "3.e"), ("#c.e", "3.e"), (";a .k ;b", "a = b")], ebaeUncontracted)
        try assertReadsWords([
            ("! .#c.e cats", "the 3.every cats"), ("! #c.e cats", "the 3.every cats"),
            (".s.d is", "sound is"), ("a .b.d book", "a .bound book"), ("a .k ;b", "a = b"),
        ], ebaeContracted)
    }

    /// The review's plain sentences (October 24, 2026), each written and
    /// read back in both EBAE tables, read back as their print, as main read
    /// them; the pass had read "5 µg" as "5 *m;g*", "x >= y" as "x *1=* y",
    /// and "(=)" as "(*knowledge*)".
    func testTheReviewsSymbolSentencesReadBackAsTheirPrint() throws {
        let sentences = ["5 \u{B5}g", "x >= y", "x == y", "(=)", ">quoted", "a->b", "km/\u{B5}s", "\u{B5}", "[=]", "a -- =b",
                         "go to =x", "into >y", "by \u{B5}",
                         // Micro before a unit, as liblouis writes it (⠨⠍⠰⠍, ⠨⠍⠰⠛, ⠨⠍⠰⠠⠇, ⠨⠍⠍⠕⠇).
                         "(\u{B5}m)", "\u{B5}g/mL", "a few \u{B5}m", "\u{B5}L", "5 \u{B5}mol"]
        for table in [ebaeUncontracted, ebaeContracted] {
            let braille = try BrailleTranslator.translate(sentences, table: table, direction: .printToBraille, workingIn: work)
            XCTAssertEqual(try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: work), sentences, table)
        }
    }

    /// An italic passage across `BrailleTranslator`'s cut of a paragraph of
    /// more than 4,000 cells, as BANA writes it (⠨⠨ before its first word,
    /// ⠨ before its last), reads its words exactly: the piece after the cut
    /// has no opening sign, so its words come back plain but for the last,
    /// whose sign is read alone, and no sign is read as print.
    func testAPassageAcrossTheCutReadsItsWords() throws {
        let passage = "one two three four five six seven eight nine ten eleven twelve"
        let braille = String(repeating: "zoo ", count: 985) + ".." + passage + " .zebra1 six"
        let expected = String(repeating: "zoo ", count: 985) + passage + " zebra, six"
        XCTAssertGreaterThan(braille.count, BrailleTranslator.maximumPieceScalars)
        for table in [ebaeUncontracted, ebaeContracted] {
            let print = try read(braille, table)
            XCTAssertEqual(print.text, expected, table)
            XCTAssertTrue(print.hasEmphasis, table)
        }
    }

    /// Plain print with the signs liblouis's EBAE writes with ⠨ (a period
    /// before a word, "=", ">", "µ") at a word's start, after "(", "[", a
    /// quotation mark, a dash, a hyphen, or a slash, and after a joined
    /// "to", "into", or "by", with numbers and hyphens, written and read
    /// back, reads back as its print: 3,000 seeded sentences in each EBAE
    /// table, every one of which main (e110d985) read back exactly too. The
    /// pass read only 175 of them back exactly before the review's fix
    /// (October 24, 2026), taking the signs for emphasis.
    func testPlainEBAEWithSymbolsReadsBackAsItsPrint() throws {
        var generator = SymbolSentenceGenerator(seed: 20_261_024)
        let sentences = (0..<3_000).map { _ in generator.sentence() }
        for table in [ebaeUncontracted, ebaeContracted] {
            let braille = try BrailleTranslator.translate(sentences, table: table, direction: .printToBraille, workingIn: work)
            let print = try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: work)
            let changed = zip(sentences, print).filter { $0 != $1 }
            XCTAssertEqual(print.count, sentences.count, table)
            XCTAssertEqual(changed.count, 0, "\(table): \(changed.prefix(5).map { "\($0.0) → \($0.1)" })")
        }
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

    /// The EBAE pass runs only where EBAE's signs mean emphasis. This Mac's
    /// Bharati tables also write italic as ⠨ before a word, but read ⠨ as
    /// the letter "kh", which the pass dropped from every word it began
    /// (review, October 24, 2026): Punjabi "ਖਾਣਾ ਖਾਓ" came back "ਆਣਾ ਆਓ".
    /// Each word, written and read back, reads as main read it: the Punjabi
    /// exactly, and Hindi "खेल" as ".एल", liblouis's own reading. Skips a
    /// table this Mac does not offer.
    func testTheEBAEPassLeavesTheBharatiTablesAlone() throws {
        let cases: [(table: String, print: String, readBack: String)] = [
            ("mac:pa.tbl", "ਖਾਣਾ ਖਾਓ", "ਖਾਣਾ ਖਾਓ"),
            ("mac:pa.tbl", "ਖੇਡ", "ਖੇਡ"),
            ("mac:pa.tbl", "ਖਿੜਕੀ ਖੋਲ੍ਹੋ", "ਖਿੜਕੀ ਖੋਲ੍ਹੋ"),
            ("mac:hi.tbl", "खेल", ".एल"),
        ]
        let offered = cases.filter { BrailleTableCatalog.table(withID: $0.table) != nil }
        try XCTSkipIf(offered.isEmpty, "This Mac offers neither pa.tbl nor hi.tbl (\(BrailleTableCatalog.macTablesFolder.path))")
        for sample in offered {
            let braille = try BrailleTranslator.translate([sample.print], table: sample.table, direction: .printToBraille, workingIn: work)
            let print = try BrailleTranslator.translate(braille, table: sample.table, direction: .brailleToPrint, workingIn: work)
            XCTAssertEqual(print, [sample.readBack], sample.table)
        }
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

/// The seeded plain sentences of
/// `BrailleEmphasisReadingTests.testPlainEBAEWithSymbolsReadsBackAsItsPrint`:
/// words, numbers, hyphenated pairs, and the signs liblouis's EBAE writes
/// with ⠨ ("=", ">", "µ", and a period before a word) where a word begins,
/// after opening punctuation, a slash, a dash, or a joined "to", "into", or
/// "by". The tokens are those liblouis reads back exactly on main: a period
/// stands only before a word beginning a to j (before other letters liblouis
/// drops it), and numbers never stand beside a dash (liblouis reads "10 --"
/// as an en dash). Seeded, so the sentences are the same on every run.
private struct SymbolSentenceGenerator {
    private var random: SeededRandom

    private static let words = [
        "cat", "sat", "on", "mat", "kite", "more", "mom", "zoo", "dog", "ice", "hello", "jam", "bad", "fig",
        "good", "egg", "aunt", "city", "day", "here", "there", "under", "young", "town", "go", "said", "milk",
    ]
    private static let wordsFromAToJ = ["cat", "dog", "ice", "hello", "jam", "bad", "fig", "good", "egg", "aunt", "city"]
    private static let symbols = ["=", ">", "\u{B5}"]
    private static let openers = ["(", "[", "\""]
    private static let closers = [")", "]", "\""]
    private static let joined = ["to", "into", "by"]
    private static let numbers = [3, 5, 10, 25, 100, 2024]

    init(seed: UInt64) {
        random = SeededRandom(seed: seed)
    }

    /// `symbol` glued to `word`; a micro sign stands before no word of
    /// letters ("µzoo"), where braille cannot tell it from an emphasized word
    /// beginning with m, which the pass reads as emphasis, and before a unit
    /// ("µL") liblouis's own reading of the words after it in the same record
    /// is not exact (it read "good" after a dash as "gd"), so the micro signs
    /// before units are in `testTheReviewsSymbolSentencesReadBackAsTheirPrint`.
    private func attached(_ symbol: String, _ word: String) -> String {
        symbol == "\u{B5}" ? ">" + word : symbol + word
    }

    /// One token; a number is a word in a sentence with dashes.
    private mutating func token(dashes: Bool) -> String {
        let kind = random.pick(10)
        let word = random.element(of: Self.words)
        let symbol = random.element(of: Self.symbols)
        switch kind {
        case 0...2:
            return word
        case 3:
            let number = String(random.element(of: Self.numbers))
            return dashes ? word : number
        case 4:
            return word + "-" + random.element(of: Self.words)
        case 5:
            return attached(symbol, word)
        case 6:
            let k = random.pick(Self.openers.count)
            return Self.openers[k] + symbol + Self.closers[k]
        case 7:
            return random.element(of: Self.joined) + " " + attached(symbol, word)
        case 8:
            return "." + random.element(of: Self.wordsFromAToJ)
        default:
            return word + "/" + attached(symbol, random.element(of: Self.words))
        }
    }

    /// One sentence of three to seven tokens, a quarter of them joined by
    /// dashes.
    mutating func sentence() -> String {
        let dashes = random.pick(4) == 0
        let count = 3 + random.pick(5)
        return (0..<count).map { _ in token(dashes: dashes) }.joined(separator: dashes ? " -- " : " ")
    }
}

/// A 64-bit linear congruential generator (Knuth's MMIX constants), so that
/// seeded sentences are the same on every run.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// A number from 0 to `count` less 1, from the next state's top 31 bits
    /// (0 when `count` is less than 1, rather than a trap).
    mutating func pick(_ count: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(count, 1)))
    }

    /// One of `items`, which is never empty here.
    mutating func element<Item>(of items: [Item]) -> Item {
        items[pick(items.count)]
    }
}

/// Seeded braille sentences with emphasis signs as BANA writes them, for
/// `BrailleEmphasisReadingTests.testBANAEmphasisReadsLiblouissOwnWords`
/// (verifier, October 24, 2026). Each has three to nine words: words that
/// begin with every kind of letter and contraction (among them the "be"
/// words, whose ⠆ contracted EBAE reads with a "(" before it as "}"),
/// capitals, whole and begun inside a word, numbers, and hyphenated words,
/// each liblouis's braille of the word alone in the table read
/// (`braille`); with parentheses, brackets, quotation marks, dashes, and
/// punctuation; in contracted braille, a "to", "into", or "by" joined to
/// its word; and italic and bold as BANA's EBAE writes them (Instruction
/// Manual for Braille Transcribing, lesson 15; Braille Formats, 2011): ⠨ or
/// ⠸⠨ before a word, after its opening punctuation, a dash, or a joined word
/// (or before the joined word, which marks it alone); ⠨⠨ or ⠸⠨⠨ before a
/// passage of four words or more, and ⠨ or ⠸⠨ before its last; and the
/// termination sign ⠠⠄ where emphasis ends inside a word.
private struct BANASentenceGenerator {
    /// The words, each translated alone.
    static let words = [
        "cat", "dog", "egg", "fig", "good", "hello", "ice", "jam", "bad", "city", "aunt", "kite", "knowledge",
        "more", "mother", "March", "lamp", "nest", "open", "people", "quiet", "rose", "sun", "tree", "under",
        "very", "wide", "yes", "zoo", "before", "because", "beside", "between", "below", "beyond", "behind",
        "the", "and", "for", "with", "of", "child", "can", "that", "his", "were", "enough", "perhaps",
        "little", "friend", "today", "Alice", "George", "NASA", "McDONALDs", "X-RAYs", "ABCs", "3", "25",
        "100", "blue-eyed", "well-known",
    ]

    /// Words emphasized in part: the part emphasized, then the rest, each
    /// translated alone, which the termination sign parts, as BANA writes
    /// "*per*haps".
    static let partWords: [(part: String, rest: String)] = [
        ("per", "haps"), ("be", "side"), ("be", "fore"), ("un", "done"), ("zoo", "keeper"), ("some", "thing"),
        ("ABC", "def"), ("over", "due"), ("re", "read"),
    ]

    /// Every piece of print whose braille the generator takes.
    static let pieces = words + partWords.flatMap { [$0.part, $0.rest] }

    /// The cells the generator writes itself, as EBAE writes them.
    private enum Cells {
        static let blank = "\u{2800}"
        static let sign = "⠨"
        static let boldPrefix = "⠸"
        static let termination = "⠠⠄"
        static let dash = "⠤⠤"
        /// Parentheses, brackets, and quotation marks: opening, closing.
        static let enclosures = [("⠶", "⠶"), ("⠠⠶", "⠶⠄"), ("⠦", "⠴")]
        /// A comma, a period, an exclamation mark, a question mark, and a
        /// semicolon.
        static let punctuation = ["⠂", "⠲", "⠖", "⠦", "⠆"]
        /// Contracted EBAE's "to", "into", and "by", joined to the next word.
        static let joinedWords = ["⠖", "⠔⠖", "⠴"]
    }

    /// One word of a sentence, with its cells in the order they stand.
    private struct Word {
        /// Whether a dash, rather than a blank cell, joins it to the word
        /// before.
        var afterDash = false
        var opening = ""
        /// The sign before a joined word, which marks the joined word alone.
        var joinedSign = ""
        var joined = ""
        var sign = ""
        var cells: String
        var closing = ""
        /// Whether an emphasis already marks it, or a passage holds it.
        var marked = false

        /// All its cells.
        var braille: String { opening + joinedSign + joined + sign + cells + closing }
    }

    private var random: SeededRandom
    /// liblouis's braille of each of `pieces`, in the table read.
    private let braille: [String: String]
    /// Whether the table is contracted, so that "to", "into", and "by" join
    /// the words after them.
    private let contracted: Bool

    init(seed: UInt64, braille: [String: String], contracted: Bool) {
        random = SeededRandom(seed: seed)
        self.braille = braille
        self.contracted = contracted
    }

    /// One sentence, in braille.
    mutating func sentence() -> String {
        var words: [Word] = []
        for _ in 0..<(3 + random.pick(7)) {
            let word = random.element(of: Self.words)
            words.append(Word(cells: braille[word, default: ""]))
        }
        let count = words.count
        // Parentheses, brackets, or quotation marks around one to three words.
        if random.pick(2) == 0 {
            let first = random.pick(count)
            let (opening, closing) = random.element(of: Cells.enclosures)
            words[first].opening = opening
            words[min(count - 1, first + random.pick(3))].closing = closing
        }
        // A dash between two words, punctuation after one, and, contracted,
        // a joined word before one.
        if random.pick(4) == 0 { words[1 + random.pick(count - 1)].afterDash = true }
        if random.pick(3) == 0 { words[random.pick(count)].closing += random.element(of: Cells.punctuation) }
        if contracted && random.pick(3) == 0 { words[random.pick(count)].joined = random.element(of: Cells.joinedWords) }
        emphasize(&words)
        if random.pick(3) == 0 { emphasize(&words) }
        return words.enumerated().map { index, word in
            (index == 0 ? "" : word.afterDash ? Cells.dash : Cells.blank) + word.braille
        }.joined()
    }

    /// Marks `words` with one emphasis, italic or, one time in three, bold,
    /// in BANA's signs: a word, a passage of four words or more, part of a
    /// word, or a joined word alone. Words an emphasis marks already are
    /// left as they are.
    private mutating func emphasize(_ words: inout [Word]) {
        let prefix = random.pick(3) == 0 ? Cells.boldPrefix : ""
        let first = random.pick(words.count)
        let kind = random.pick(4)
        guard !words[first].marked else { return }
        switch kind {
        case 0 where words.count - first >= 4:
            let last = first + 3 + random.pick(words.count - first - 3)
            guard !words[first...last].contains(where: \.marked) else { return }
            for index in first...last { words[index].marked = true }
            words[first].sign = prefix + Cells.sign + Cells.sign
            words[last].sign = prefix + Cells.sign
        case 1:
            let split = random.element(of: Self.partWords)
            words[first].cells = braille[split.part, default: ""] + Cells.termination + braille[split.rest, default: ""]
            words[first].sign = prefix + Cells.sign
        case 2 where !words[first].joined.isEmpty:
            words[first].joinedSign = prefix + Cells.sign
        default:
            words[first].sign = prefix + Cells.sign
        }
        words[first].marked = true
    }
}
