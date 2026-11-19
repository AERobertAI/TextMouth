import XCTest
@testable import TextMouth

/// Pronunciation lexicons (W3C PLS 1.0) as substitution rules (FMT08): the
/// reader, the rules an alias makes, the writer and its round trip, the
/// service's import, the file actions behind Import Rules… and Export
/// Rules…, and every sentence they say.
@MainActor
final class PronunciationLexiconTests: XCTestCase {
    // MARK: - Fixtures

    /// A lexicon with `body` inside its root, in PLS 1.0's namespace.
    private func lexiconXML(_ body: String, root: String = "lexicon") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <\(root) version="1.0" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon" alphabet="ipa" xml:lang="en">
        \(body)
        </\(root)>
        """.utf8)
    }

    /// A service of its own that never touches the saved rules file's
    /// contents it is not given: hosted tests keep that file in their own
    /// temporary data root, which is checked here.
    private func makeService(_ rules: [SubstitutionRule] = []) throws -> TextSubstitutionService {
        let file = TextMouthPaths.substitutionsFile
        try XCTSkipUnless(
            file.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "the rules file is outside the isolated test root"
        )
        return TextSubstitutionService(rules: rules)
    }

    /// A new, empty folder under the temporary directory.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PronunciationLexicon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Reading

    /// An alias lexeme makes one rule: the grapheme as the pattern, the
    /// alias as the replacement, plain text, whole word, ignoring case.
    func testAnAliasBecomesAWholeWordCaseInsensitiveRule() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>W3C</grapheme><alias>World Wide Web Consortium</alias></lexeme>
        """))
        let rules = lexicon.substitutionRules
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].pattern, "W3C")
        XCTAssertEqual(rules[0].replacement, "World Wide Web Consortium")
        XCTAssertFalse(rules[0].isRegex)
        XCTAssertFalse(rules[0].caseSensitive)
        XCTAssertTrue(rules[0].wholeWord)
        XCTAssertTrue(rules[0].isEnabled)
        XCTAssertEqual(lexicon.setAsideCount, 0)
    }

    /// Every grapheme of a lexeme gets its own rule with the alias, and the
    /// first alias is the one used.
    func testEachGraphemeGetsARuleAndTheFirstAliasIsUsed() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>colour</grapheme><grapheme>color</grapheme><alias>kuller</alias><alias>other</alias></lexeme>
        """))
        XCTAssertEqual(lexicon.substitutionRules.map(\.pattern), ["colour", "color"])
        XCTAssertEqual(lexicon.substitutionRules.map(\.replacement), ["kuller", "kuller"])
    }

    /// PLS 1.0: the first alias marked prefer="true" is used, else the first
    /// alias; a later preferred alias does not replace an earlier one.
    func testThePreferredAliasIsUsed() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>a</grapheme><alias>first</alias><alias prefer="true">second</alias><alias prefer="true">third</alias></lexeme>
        <lexeme><grapheme>b</grapheme><alias prefer="false">one</alias><alias>two</alias></lexeme>
        <lexeme><grapheme>c</grapheme><alias>x</alias><alias prefer="TRUE">y</alias></lexeme>
        """))
        XCTAssertEqual(lexicon.substitutionRules.map(\.replacement), ["second", "one", "y"])
    }

    /// A lexeme with only phonemes makes no rule and is counted as set
    /// aside; a lexeme with both makes the rule and is not.
    func testPhonemeOnlyLexemesAreSetAsideAndCounted() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>Siobhan</grapheme><phoneme>ʃɪˈvɔːn</phoneme></lexeme>
        <lexeme><grapheme>tomato</grapheme><phoneme>t</phoneme><phoneme prefer="false">u</phoneme></lexeme>
        <lexeme><grapheme>GIF</grapheme><alias>jif</alias><phoneme>dʒɪf</phoneme></lexeme>
        <lexeme><grapheme>empty</grapheme></lexeme>
        """))
        XCTAssertEqual(lexicon.substitutionRules.map(\.pattern), ["GIF"])
        XCTAssertEqual(lexicon.setAsideCount, 3)
    }

    /// The real sample: one alias, four lexemes set aside.
    func testTheSampleLexicon() throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples/pls-lexicon/lexicon.pls")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sample.path), "sample missing")
        let lexicon = try PronunciationLexicon.read(from: sample)
        XCTAssertEqual(lexicon.lexemes.count, 5)
        XCTAssertEqual(lexicon.substitutionRules.map(\.pattern), ["W3C"])
        XCTAssertEqual(lexicon.substitutionRules.map(\.replacement), ["World Wide Web Consortium"])
        XCTAssertEqual(lexicon.setAsideCount, 4)
    }

    /// Entities, line breaks inside an alias, prefixed element names, and
    /// unknown elements are read without trouble.
    func testEntitiesWhiteSpacePrefixesAndUnknownElements() throws {
        let data = Data("""
        <?xml version="1.0"?>
        <pls:lexicon xmlns:pls="http://www.w3.org/2005/01/pronunciation-lexicon" version="1.0" xml:lang="en">
          <pls:meta name="x" content="y"/>
          <pls:lexeme role="noun">
            <pls:grapheme> AT&amp;T </pls:grapheme>
            <pls:alias>A T
              and T</pls:alias>
            <pls:example>ignored</pls:example>
          </pls:lexeme>
        </pls:lexicon>
        """.utf8)
        let rules = try PronunciationLexicon.parse(data).substitutionRules
        XCTAssertEqual(rules.map(\.pattern), ["AT&T"])
        XCTAssertEqual(rules.map(\.replacement), ["A T and T"])
    }

    /// An empty alias is a rule that skips its match, not a lexeme set aside.
    func testAnEmptyAliasSkipsTheMatch() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML(
            "<lexeme><grapheme>[sic]</grapheme><alias></alias></lexeme>"
        ))
        XCTAssertEqual(lexicon.substitutionRules.map(\.replacement), [""])
        XCTAssertEqual(lexicon.setAsideCount, 0)
    }

    /// A grapheme repeated in the file, in any capitals, makes one rule.
    func testARepeatedGraphemeMakesOneRule() throws {
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>Dr</grapheme><alias>Doctor</alias></lexeme>
        <lexeme><grapheme>dr</grapheme><alias>Drive</alias></lexeme>
        """))
        XCTAssertEqual(lexicon.substitutionRules.map(\.replacement), ["Doctor"])
    }

    /// Files that are no lexicon are refused with a reason, and a lexicon
    /// with no lexemes is read as empty.
    func testRefusals() throws {
        XCTAssertThrowsError(try PronunciationLexicon.parse(Data("not xml".utf8))) {
            XCTAssertEqual($0 as? PronunciationLexicon.ReadError, .notXML)
        }
        XCTAssertThrowsError(try PronunciationLexicon.parse(Data("<lexicon><lexeme>".utf8))) {
            XCTAssertEqual($0 as? PronunciationLexicon.ReadError, .notXML)
        }
        XCTAssertThrowsError(try PronunciationLexicon.parse(lexiconXML("<p>x</p>", root: "html"))) {
            XCTAssertEqual($0 as? PronunciationLexicon.ReadError, .notALexicon)
        }
        XCTAssertThrowsError(try PronunciationLexicon.parse(Data(count: PronunciationLexicon.byteLimit + 1))) {
            XCTAssertEqual($0 as? PronunciationLexicon.ReadError, .tooLarge)
        }
        XCTAssertEqual(try PronunciationLexicon.parse(lexiconXML("")).lexemes, [])
    }

    /// A lexicon that declares an entity, of either kind, is refused, not
    /// read with the entity as nothing ("&w; Wide Web" as " Wide Web").
    func testADeclaredEntityIsRefused() {
        let declarations = [
            #"<!ENTITY w "World">"#,
            #"<!ENTITY secret SYSTEM "file:///nowhere/at/all">"#,
        ]
        for declaration in declarations {
            let data = Data("""
            <?xml version="1.0"?>
            <!DOCTYPE lexicon [\(declaration)]>
            <lexicon version="1.0" xml:lang="en"><lexeme><grapheme>W3C</grapheme><alias>&w; Wide Web</alias></lexeme></lexicon>
            """.utf8)
            XCTAssertThrowsError(try PronunciationLexicon.parse(data), declaration) {
                XCTAssertEqual($0 as? PronunciationLexicon.ReadError, .declaresEntities)
            }
        }
    }

    // MARK: - The Rule Limit

    /// A generated lexicon of `lexemes` lexemes with `spellings` spellings
    /// each, every lexeme with an alias.
    private func bigLexicon(lexemes: Int, spellings: Int) -> Data {
        var body = ""
        for lexeme in 0..<lexemes {
            body += "<lexeme>"
            for spelling in 0..<spellings { body += "<grapheme>w\(lexeme)x\(spelling)</grapheme>" }
            body += "<alias>a\(lexeme)</alias></lexeme>\n"
        }
        return lexiconXML(body)
    }

    /// A lexicon past the limit is read up to the lexeme that would pass it:
    /// the rules are at most the limit, and the lexemes left are counted,
    /// small ones after the stop included.
    func testReadingStopsAtTheRuleLimitAndCountsWhatIsLeft() throws {
        let perLexeme = PronunciationLexicon.ruleLimit / 5
        let lexicon = try PronunciationLexicon.parse(bigLexicon(lexemes: 7, spellings: perLexeme))
        XCTAssertEqual(lexicon.substitutionRules.count, PronunciationLexicon.ruleLimit)
        XCTAssertEqual(lexicon.lexemes.count, 5)
        XCTAssertEqual(lexicon.unreadCount, 2)
        // One lexeme past the limit by itself is not read, and a small
        // lexeme after the stop is not read either.
        let spellings = (0...PronunciationLexicon.ruleLimit).map { "<grapheme>g\($0)</grapheme>" }.joined()
        let after = try PronunciationLexicon.parse(lexiconXML(
            "<lexeme>" + spellings + "<alias>x</alias></lexeme><lexeme><grapheme>small</grapheme><alias>y</alias></lexeme>"
        ))
        XCTAssertEqual(after.substitutionRules.count, 0)
        XCTAssertEqual(after.unreadCount, 2)
    }

    /// A lexicon at the limit exactly is read whole.
    func testALexiconAtTheLimitIsReadWhole() throws {
        let lexicon = try PronunciationLexicon.parse(bigLexicon(lexemes: 1, spellings: PronunciationLexicon.ruleLimit))
        XCTAssertEqual(lexicon.substitutionRules.count, PronunciationLexicon.ruleLimit)
        XCTAssertEqual(lexicon.unreadCount, 0)
    }

    /// An import past the limit adds the limit's rules, and its alert says
    /// how many entries were not read.
    func testTheImportSaysHowManyEntriesWereNotRead() throws {
        let service = try makeService()
        let file = try makeFolder().appendingPathComponent("huge.pls")
        try bigLexicon(lexemes: 3, spellings: PronunciationLexicon.ruleLimit).write(to: file)
        let outcome = LexiconFileActions.importLexicon(at: file, into: service)
        XCTAssertEqual(service.rules.count, PronunciationLexicon.ruleLimit)
        XCTAssertEqual(
            outcome.message,
            "Added 5,000 rules from “huge.pls”. 2 entries were not read, because a lexicon adds at most 5,000 rules at a time."
        )
    }

    // MARK: - Writing

    /// Rules are written as lexemes in order, and a regular expression, a
    /// disabled rule, and a rule with no pattern are left out and counted.
    func testExportWritesPlainEnabledRulesAndCountsTheRest() {
        let export = PronunciationLexicon.export([
            SubstitutionRule(pattern: "Dr.", replacement: "Doctor"),
            SubstitutionRule(pattern: #"\bMr\."#, replacement: "Mister", isRegex: true),
            SubstitutionRule(pattern: "off", replacement: "x", isEnabled: false),
            SubstitutionRule(pattern: "", replacement: "x"),
            SubstitutionRule(pattern: "[sic]", replacement: "")
        ])
        XCTAssertEqual(export.written, 2)
        XCTAssertEqual(export.leftOut, 3)
        XCTAssertEqual(export.lexicon.lexemes.map(\.graphemes), [["Dr."], ["[sic]"]])
    }

    /// What is written reads back as the same rules, including markup
    /// characters, an empty replacement, and text with Unicode.
    func testWrittenLexiconReadsBackAsTheSameRules() throws {
        let original = [
            SubstitutionRule(pattern: "AT&T", replacement: "A T and T"),
            SubstitutionRule(pattern: "<b>", replacement: "\"bold\" & 'strong'"),
            SubstitutionRule(pattern: "[sic]", replacement: ""),
            SubstitutionRule(pattern: "Siobhán", replacement: "Shivawn")
        ]
        let data = PronunciationLexicon.export(original).lexicon.xmlData()
        let back = try PronunciationLexicon.parse(data).substitutionRules
        XCTAssertEqual(back.map(\.pattern), original.map(\.pattern))
        XCTAssertEqual(back.map(\.replacement), original.map(\.replacement))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("xml:lang=\"en\""))
    }

    /// A control character XML forbids is dropped instead of making the
    /// file unreadable.
    func testForbiddenControlCharactersAreDropped() throws {
        let data = PronunciationLexicon.export([SubstitutionRule(pattern: "a\u{1}b", replacement: "c\u{0}d")]).lexicon.xmlData()
        let back = try PronunciationLexicon.parse(data).substitutionRules
        XCTAssertEqual(back.map(\.pattern), ["ab"])
        XCTAssertEqual(back.map(\.replacement), ["cd"])
    }

    // MARK: - The Service

    /// Import appends the new rules, once, after the existing ones, and a
    /// second import of the same lexicon adds nothing.
    func testImportAppendsRulesAndSkipsWhatIsAlreadyThere() throws {
        let service = try makeService([SubstitutionRule(pattern: "Dr.", replacement: "Doctor")])
        let lexicon = try PronunciationLexicon.parse(lexiconXML("""
        <lexeme><grapheme>dr.</grapheme><alias>Doctor</alias></lexeme>
        <lexeme><grapheme>W3C</grapheme><alias>World Wide Web Consortium</alias></lexeme>
        <lexeme><grapheme>Siobhan</grapheme><phoneme>x</phoneme></lexeme>
        """))
        XCTAssertEqual(service.importLexicon(lexicon), LexiconImportReport(added: 1, alreadyPresent: 1, setAside: 1))
        XCTAssertEqual(service.rules.map(\.pattern), ["Dr.", "W3C"])
        XCTAssertEqual(service.importLexicon(lexicon), LexiconImportReport(added: 0, alreadyPresent: 2, setAside: 1))
        XCTAssertEqual(service.rules.count, 2)
    }

    /// An imported rule changes the speech: its alias is spoken in place of
    /// the grapheme as a whole word, and not inside a longer word.
    func testAnImportedRuleChangesTheText() throws {
        let service = try makeService()
        service.importLexicon(try PronunciationLexicon.parse(lexiconXML(
            "<lexeme><grapheme>W3C</grapheme><alias>World Wide Web Consortium</alias></lexeme>"
        )))
        XCTAssertEqual(service.transform("The w3c and XW3CX.").modifiedText, "The World Wide Web Consortium and XW3CX.")
    }

    // MARK: - The File Actions

    /// Importing a lexicon file adds its rules and says how many.
    func testImportingAFileTellsWhatItAdded() throws {
        let service = try makeService()
        let file = try makeFolder().appendingPathComponent("names.pls")
        try lexiconXML("""
        <lexeme><grapheme>a</grapheme><alias>b</alias></lexeme>
        <lexeme><grapheme>c</grapheme><phoneme>d</phoneme></lexeme>
        """).write(to: file)
        let outcome = LexiconFileActions.importLexicon(at: file, into: service)
        XCTAssertEqual(outcome.title, "Rules Imported")
        XCTAssertEqual(
            outcome.message,
            "Added 1 rule from “names.pls”. 1 entry gives only a phonetic spelling, so it was set aside."
        )
        XCTAssertEqual(service.rules.map(\.pattern), ["a"])
    }

    /// A file that is no lexicon, and a file that is not there, change no
    /// rule and say why.
    func testImportingBadFilesChangesNothing() throws {
        let service = try makeService([SubstitutionRule(pattern: "x", replacement: "y")])
        let folder = try makeFolder()
        let text = folder.appendingPathComponent("a.pls")
        try Data("plain".utf8).write(to: text)
        XCTAssertEqual(
            LexiconFileActions.importLexicon(at: text, into: service),
            LexiconFileOutcome(
                title: "Import Failed",
                message: "“a.pls” is not a complete, valid XML file."
            )
        )
        let html = folder.appendingPathComponent("b.xml")
        try Data("<html/>".utf8).write(to: html)
        XCTAssertEqual(
            LexiconFileActions.importLexicon(at: html, into: service).message,
            "“b.xml” is an XML file, but not a pronunciation lexicon."
        )
        XCTAssertEqual(
            LexiconFileActions.importLexicon(at: folder.appendingPathComponent("missing.pls"), into: service).message,
            "TextMouth could not read “missing.pls”."
        )
        XCTAssertEqual(service.rules.count, 1)
    }

    /// Exporting writes the file, says what was left out, and the file
    /// imports into another service as the same rules.
    func testExportingWritesAFileThatImportsBack() throws {
        let service = try makeService([
            SubstitutionRule(pattern: "Dr.", replacement: "Doctor"),
            SubstitutionRule(pattern: "x+", replacement: "y", isRegex: true)
        ])
        let file = try makeFolder().appendingPathComponent("rules.pls")
        let outcome = LexiconFileActions.exportLexicon(from: service, to: file)
        XCTAssertEqual(outcome.title, "Rules Exported")
        XCTAssertEqual(
            outcome.message,
            "Exported 1 rule to “rules.pls”. 1 rule was left out: regular expressions and rules that are off cannot be written in a lexicon."
        )
        let other = try makeService()
        _ = LexiconFileActions.importLexicon(at: file, into: other)
        XCTAssertEqual(other.rules.map(\.pattern), ["Dr."])
        XCTAssertEqual(other.rules.map(\.replacement), ["Doctor"])
    }

    /// With no rule a lexicon can hold, nothing is written.
    func testExportingNothingWritesNoFile() throws {
        let service = try makeService([SubstitutionRule(pattern: "x+", replacement: "y", isRegex: true)])
        let file = try makeFolder().appendingPathComponent("none.pls")
        let outcome = LexiconFileActions.exportLexicon(from: service, to: file)
        XCTAssertEqual(outcome.title, "Export Failed")
        XCTAssertEqual(outcome.message, PronunciationLexiconWording.nothingToExport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - The Words

    /// The sentence for a lexicon that declares entities.
    func testTheEntityRefusalWords() {
        XCTAssertEqual(
            PronunciationLexiconWording.importFailure(fileName: "a.pls", .declaresEntities),
            "“a.pls” uses XML entities of its own, which TextMouth does not read."
        )
    }

    /// The sentences, pinned, for every count.
    func testTheWords() {
        typealias W = PronunciationLexiconWording
        XCTAssertEqual(W.imported(fileName: "a.pls", added: 0, alreadyPresent: 0, setAside: 0), "No rules were added from “a.pls”.")
        XCTAssertEqual(
            W.imported(fileName: "a.pls", added: 3, alreadyPresent: 1, setAside: 2),
            "Added 3 rules from “a.pls”. 1 rule was already in your rules. "
                + "2 entries give only a phonetic spelling, so they were set aside."
        )
        XCTAssertEqual(
            W.imported(fileName: "a.pls", added: 1, alreadyPresent: 2, setAside: 0),
            "Added 1 rule from “a.pls”. 2 rules were already in your rules."
        )
        XCTAssertEqual(
            W.importFailure(fileName: "a.pls", .tooLarge),
            "“a.pls” is too large to read."
        )
        XCTAssertEqual(
            W.exported(fileName: "a.pls", written: 5, leftOut: 2),
            "Exported 5 rules to “a.pls”. 2 rules were left out: regular expressions and rules that are off cannot be written in a lexicon."
        )
        XCTAssertEqual(W.exported(fileName: "a.pls", written: 2, leftOut: 0), "Exported 2 rules to “a.pls”.")
        XCTAssertEqual(W.exportWriteFailure(fileName: "a.pls"), "TextMouth could not save “a.pls”.")
        XCTAssertEqual(W.nothingToExport, "No rules to export: only plain text rules that are on can be written in a lexicon.")
        XCTAssertEqual(W.importedTitle, "Rules Imported")
        XCTAssertEqual(W.importFailedTitle, "Import Failed")
        XCTAssertEqual(W.exportedTitle, "Rules Exported")
        XCTAssertEqual(W.exportFailedTitle, "Export Failed")
        XCTAssertEqual(W.exported(fileName: "a.pls", written: 1, leftOut: 1), "Exported 1 rule to “a.pls”. 1 rule was left out: regular expressions and rules that are off cannot be written in a lexicon.")
    }

    /// A count of rules is grouped for the region, as every count is (FR34):
    /// "1,234 rules", and the limit the same way.
    func testCountsOfRulesAreGroupedForTheRegion() {
        typealias W = PronunciationLexiconWording
        XCTAssertEqual(
            W.imported(fileName: "a.pls", added: 1_234, alreadyPresent: 1_000, setAside: 0),
            "Added 1,234 rules from “a.pls”. 1,000 rules were already in your rules."
        )
        XCTAssertEqual(
            W.exported(fileName: "a.pls", written: 2_000, leftOut: 0),
            "Exported 2,000 rules to “a.pls”."
        )
    }

    /// The two buttons' titles, labels and hints, the panels' messages, and
    /// the file name the Save panel offers: each is spoken, so each is pinned.
    func testTheButtonsAndPanelsWords() {
        typealias W = PronunciationLexiconWording
        XCTAssertEqual(W.importButton, "Import Rules…")
        XCTAssertEqual(W.importLabel, "Import rules from a pronunciation lexicon file")
        XCTAssertEqual(
            W.importHint,
            "Adds the lexicon's entries after your rules; entries with only a phonetic spelling are set aside"
        )
        XCTAssertEqual(W.exportButton, "Export Rules…")
        XCTAssertEqual(W.exportLabel, "Export rules as a pronunciation lexicon file")
        XCTAssertEqual(
            W.exportHint,
            "Saves your plain text rules that are on; regular expression rules are left out"
        )
        XCTAssertEqual(W.importPanelMessage, "Choose a pronunciation lexicon file to add as rules.")
        XCTAssertEqual(W.exportPanelMessage, "Save your rules as a pronunciation lexicon file.")
        XCTAssertEqual(W.exportFileName, "Substitution Rules.pls")
    }
}
