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

    /// A contraction that liblouis reads with what follows it, past the place
    /// its emphasis ends, has its characters split there: contracted EBAE
    /// reads "can't" (⠉⠄⠞) as one rule, so with "can" in bold (⠸⠨⠉⠠⠄⠄⠞) all
    /// of "can't" came back bold; now its "can" is, and its "'t" is not.
    /// Italic's sign before "can" is liblouis's period, and stays.
    func testARuleReadAcrossAnEmphasisEndIsSplitWhereTheEmphasisEnds() throws {
        try assertReads([
            ("a _.c,''t", #"a **can**\'t"#),
            ("a .c't is", #"a \.can\'t is"#),
        ], ebaeContracted)
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
                         "go to =x", "into >y", "by \u{B5}"]
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
/// as an en dash). A 64-bit linear congruential generator, so the sentences
/// are the same on every run.
private struct SymbolSentenceGenerator {
    private var state: UInt64

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
        state = seed
    }

    /// The next 31 bits.
    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    /// A number from 0 to `count` less 1.
    private mutating func pick(_ count: Int) -> Int {
        Int(next() % UInt64(count))
    }

    /// One token; a number is a word in a sentence with dashes.
    private mutating func token(dashes: Bool) -> String {
        let kind = pick(10)
        let word = Self.words[pick(Self.words.count)]
        let symbol = Self.symbols[pick(Self.symbols.count)]
        switch kind {
        case 0...2:
            return word
        case 3:
            let number = String(Self.numbers[pick(Self.numbers.count)])
            return dashes ? word : number
        case 4:
            return word + "-" + Self.words[pick(Self.words.count)]
        case 5:
            return symbol + word
        case 6:
            let k = pick(Self.openers.count)
            return Self.openers[k] + symbol + Self.closers[k]
        case 7:
            return Self.joined[pick(Self.joined.count)] + " " + symbol + word
        case 8:
            return "." + Self.wordsFromAToJ[pick(Self.wordsFromAToJ.count)]
        default:
            return word + "/" + symbol + Self.words[pick(Self.words.count)]
        }
    }

    /// One sentence of three to seven tokens, a quarter of them joined by
    /// dashes.
    mutating func sentence() -> String {
        let dashes = pick(4) == 0
        let count = 3 + pick(5)
        return (0..<count).map { _ in token(dashes: dashes) }.joined(separator: dashes ? " -- " : " ")
    }
}
