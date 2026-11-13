import XCTest
import SwiftSoup
@testable import TextMouth

/// `SSMLReader` (FMT07): an SSML file read as text, its markup removed and
/// its paragraphs and sentences kept, as simple HTML.
final class SSMLReaderTests: XCTestCase {
    // MARK: - Helpers

    /// `body` wrapped in a `speak` element in the SSML namespace.
    private func speak(_ body: String) -> String {
        "<speak version=\"1.1\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\">\(body)</speak>"
    }

    /// The inner HTML of each paragraph `ssml` reads as, in order, so a test
    /// states only its SSML and its paragraphs.
    private func paragraphs(_ ssml: String) throws -> [String] {
        let html = try SSMLReader.html(from: Data(ssml.utf8))
        return try paragraphs(inHTML: html)
    }

    /// The inner HTML of each `p` in `html`, written without pretty-printing.
    private func paragraphs(inHTML html: String) throws -> [String] {
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        return try document.select("p").array().map { try $0.html() }
    }

    /// The text of the chapter `html` becomes through the converter and the
    /// Markdown parser, the path every HTML book's text takes.
    private func readerText(ofHTML html: String) throws -> String {
        let markdown = try HTMLToMarkdownConverter.convert(html)
        let content = try MarkdownDocParser.parse(markdown: markdown, title: "SSML")
        return content.chapters.map(\.text).joined(separator: "\n\n")
    }

    // MARK: - The sample

    func testTheSampleReadsAsTwoParagraphsWithItsEmphasisKept() throws {
        let copy = try copyOfFormatSample("ssml/passage.ssml")
        let html = try SSMLReader.html(from: copy)
        XCTAssertEqual(try paragraphs(inHTML: html), [
            "The ferry leaves at 9:30am. Wait here until you hear the horn.",
            "It is <em>not</em> a long crossing. Mind the gap between the boat and the pier. "
                + "Say the word tomato twice, and spell SSML. World Wide Web Consortium publishes the standard."
        ])
    }

    func testTheSampleReadsAsPlainTextWithoutMarkup() throws {
        let copy = try copyOfFormatSample("ssml/passage.ssml")
        let text = try readerText(ofHTML: SSMLReader.html(from: copy))
        for symbol in ["<", ">", "*", "W3C"] {
            XCTAssertFalse(text.contains(symbol), "The text holds “\(symbol)”: \(text)")
        }
        XCTAssertTrue(text.contains("World Wide Web Consortium"))
        XCTAssertTrue(text.contains("9:30am"))
        XCTAssertTrue(text.contains("It is not a long crossing."))
    }

    // MARK: - Breaks, sentences, and paragraphs

    func testABreakKeepsOneSpaceBetweenItsWords() throws {
        XCTAssertEqual(try paragraphs(speak("<p>Wait<break time=\"2s\"/>here</p>")), ["Wait here"])
        XCTAssertEqual(try paragraphs(speak("<p>Wait <break/> here</p>")), ["Wait here"])
    }

    /// A voice's start and end each separate words, so neighbouring voices'
    /// words never run together.
    func testVoicesNeverRunTogether() throws {
        XCTAssertEqual(try paragraphs(speak("<p><voice name=\"a\">Hello.</voice><voice name=\"b\">Hi.</voice></p>")),
                       ["Hello. Hi."])
        XCTAssertEqual(try paragraphs(speak("<p>Said<voice name=\"a\">Hello</voice>twice</p>")),
                       ["Said Hello twice"])
    }

    /// An audio element, empty or with fallback text, separates the words
    /// on either side of it.
    func testAudioNeverRunsTheWordsAroundItTogether() throws {
        XCTAssertEqual(try paragraphs(speak("<p>Wait<audio src=\"h.mp3\"/>then</p>")), ["Wait then"])
        XCTAssertEqual(try paragraphs(speak("<p>Wait<audio src=\"h.mp3\">Horn.</audio>then</p>")),
                       ["Wait Horn. then"])
    }

    /// The start of a sentence separates it from words just before it.
    func testASentenceStartsAWordApart() throws {
        XCTAssertEqual(try paragraphs(speak("<p>Intro<s>One.</s></p>")), ["Intro One."])
    }

    func testSentencesWithNothingBetweenThemStayApart() throws {
        XCTAssertEqual(try paragraphs(speak("<p><s>One.</s><s>Two.</s></p>")), ["One. Two."])
        XCTAssertEqual(try paragraphs(speak("<p><sentence>One.</sentence><sentence>Two.</sentence></p>")),
                       ["One. Two."])
    }

    func testParagraphElementsAreParagraphs() throws {
        XCTAssertEqual(try paragraphs(speak("<paragraph>First.</paragraph><p>Second.</p>")), ["First.", "Second."])
    }

    func testWhiteSpaceCollapsesAndAnEmptyParagraphWritesNothing() throws {
        let ssml = speak("<p>  Spread \n\t over   lines.  </p><p>   </p><p><break/></p>")
        XCTAssertEqual(try paragraphs(ssml), ["Spread over lines."])
    }

    func testTextDirectlyInSpeakMakesParagraphsOfItsOwn() throws {
        let ssml = speak("Before. <p>Inside.</p> After.")
        XCTAssertEqual(try paragraphs(ssml), ["Before.", "Inside.", "After."])
    }

    func testSentencesOutsideAParagraphFormOneParagraphEndedByTheNext() throws {
        let ssml = speak("<s>One.</s><s>Two.</s><p>Three.</p>")
        XCTAssertEqual(try paragraphs(ssml), ["One. Two.", "Three."])
    }

    func testAFileWithNoWordsGivesABodyWithNoParagraph() throws {
        let html = try SSMLReader.html(from: Data(speak("<p> </p>").utf8))
        XCTAssertEqual(html, "<html><body></body></html>")
    }

    // MARK: - Elements

    func testSubSpeaksItsAliasInPlaceOfItsContent() throws {
        let ssml = speak("<p><sub alias=\"World Wide Web Consortium\">W3C</sub> sets it.</p>")
        XCTAssertEqual(try paragraphs(ssml), ["World Wide Web Consortium sets it."])
    }

    func testSubWithoutAnAliasKeepsItsContent() throws {
        XCTAssertEqual(try paragraphs(speak("<p><sub>W3C</sub> sets it.</p>")), ["W3C sets it."])
    }

    func testSubWithABlankAliasKeepsItsContent() throws {
        XCTAssertEqual(try paragraphs(speak("<p><sub alias=\"  \">W3C</sub> sets it.</p>")), ["W3C sets it."])
    }

    func testSubDropsEmphasisInsideItsAlias() throws {
        let ssml = speak("<p><sub alias=\"spoken\"><emphasis>written</emphasis></sub> words.</p>")
        XCTAssertEqual(try paragraphs(ssml), ["spoken words."])
    }

    func testAudioGivesItsFallbackTextAndNeverItsSource() throws {
        let ssml = speak("<p><audio src=\"https://example.com/horn.mp3\">Horn sounds.<desc>A long horn</desc></audio></p>")
        let html = try SSMLReader.html(from: Data(ssml.utf8))
        XCTAssertEqual(try paragraphs(inHTML: html), ["Horn sounds."])
        XCTAssertFalse(html.contains("example.com"))
    }

    func testDescMetaMetadataAndLexiconGiveNothing() throws {
        let ssml = speak("""
            <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Hidden title</dc:title></metadata>
            <meta name="author" content="Hidden"/>
            <lexicon uri="http://example.com/lexicon.pls">Hidden lexicon</lexicon>
            <p>Shown.<desc>Hidden description</desc></p>
            """)
        XCTAssertEqual(try paragraphs(ssml), ["Shown."])
    }

    func testElementsThatOnlyAffectSpeechGiveTheirContent() throws {
        let ssml = speak("""
            <p><voice name="x"><lang xml:lang="fr-FR"><prosody rate="slow"><say-as interpret-as="characters">SSML</say-as> \
            <phoneme alphabet="ipa" ph="t">tomato</phoneme> <mark name="m"/><token>a</token> <w>b</w> <unknown>c</unknown>\
            </prosody></lang></voice></p>
            """)
        XCTAssertEqual(try paragraphs(ssml), ["SSML tomato a b c"])
    }

    func testElementNamesAreMatchedByCase() throws {
        // SSML is case-sensitive: <P> is not a paragraph, so it adds no break.
        XCTAssertEqual(try paragraphs(speak("<p>One <P>two</P></p>")), ["One two"])
    }

    func testEmphasisKeepsItsWordsInEmAndMovesSpacesOutside() throws {
        let ssml = speak("<p>It is <emphasis> not </emphasis> long.</p>")
        XCTAssertEqual(try paragraphs(ssml), ["It is <em>not</em> long."])
    }

    func testNestedEmphasisWritesOneEm() throws {
        let ssml = speak("<p><emphasis>very <emphasis>very</emphasis></emphasis> long</p>")
        XCTAssertEqual(try paragraphs(ssml), ["<em>very very</em> long"])
    }

    /// Level "none" asks for no emphasis: its words are written plain. Every
    /// other level, and no level, is written as emphasis.
    func testEmphasisOfLevelNoneWritesItsContentOnly() throws {
        XCTAssertEqual(try paragraphs(speak("<p>It is <emphasis level=\"none\">not</emphasis> long.</p>")),
                       ["It is not long."])
        for level in ["strong", "moderate", "reduced"] {
            XCTAssertEqual(try paragraphs(speak("<p>It is <emphasis level=\"\(level)\">not</emphasis> long.</p>")),
                           ["It is <em>not</em> long."], level)
        }
        XCTAssertEqual(try paragraphs(speak("<p>It is <emphasis>not</emphasis> long.</p>")),
                       ["It is <em>not</em> long."])
    }

    /// A plain emphasis inside an emphatic one, and the reverse, keep the
    /// emphatic one's tags balanced.
    func testEmphasisOfLevelNoneNestsWithoutUnbalancingTags() throws {
        XCTAssertEqual(try paragraphs(speak("<p><emphasis>a <emphasis level=\"none\">b</emphasis> c</emphasis> d</p>")),
                       ["<em>a b c</em> d"])
        XCTAssertEqual(try paragraphs(speak("<p><emphasis level=\"none\">a <emphasis>b</emphasis> c</emphasis> d</p>")),
                       ["a <em>b</em> c d"])
    }

    func testEmptyEmphasisWritesNothing() throws {
        XCTAssertEqual(try paragraphs(speak("<p>A<emphasis/> <emphasis> </emphasis>B</p>")), ["A B"])
    }

    // MARK: - Escaping

    /// A markup character with a combining accent after it (one Character in
    /// Swift) is escaped like any other, where it was once written raw.
    func testAMarkupCharacterWithACombiningAccentIsEscaped() throws {
        let html = try SSMLReader.html(from: Data(speak("<p>Fish &amp;\u{301} chips &lt;\u{301}</p>").utf8))
        XCTAssertTrue(html.contains("&amp;\u{301} chips &lt;\u{301}"), html)
        XCTAssertEqual(html.unicodeScalars.filter { $0 == "<" }.count, 6, "only the tags of the page, in <html><body><p>… and their ends: \(html)")
    }

    func testLiteralMarkupCharactersAreEscapedAndReadAsWritten() throws {
        let ssml = speak("<p>Type &lt;b&gt;bold&lt;/b&gt; &amp; say \"hi\", then &quot;bye&quot;.</p>")
        let html = try SSMLReader.html(from: Data(ssml.utf8))
        XCTAssertTrue(html.contains("&lt;b&gt;bold&lt;/b&gt; &amp; say &quot;hi&quot;"), html)
        XCTAssertFalse(html.contains("<b>"))
        let text = try readerText(ofHTML: html)
        XCTAssertTrue(text.contains("Type <b>bold</b> & say \"hi\", then \"bye\"."), text)
    }

    func testCDATAIsText() throws {
        XCTAssertEqual(try paragraphs(speak("<p><![CDATA[a < b]]></p>")), ["a &lt; b"])
    }

    // MARK: - The root element

    func testAPrefixedRootReadsAsSSML() throws {
        let ssml = "<ssml:speak xmlns:ssml=\"http://www.w3.org/2001/10/synthesis\">"
            + "<ssml:p><ssml:s>Hello.</ssml:s></ssml:p></ssml:speak>"
        XCTAssertEqual(try paragraphs(ssml), ["Hello."])
    }

    func testAnotherRootIsNotSSML() throws {
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<html><body><p>Hi.</p></body></html>".utf8))) {
            XCTAssertEqual($0 as? SSMLReader.Failure, .notSSML(rootElement: "html"))
            XCTAssertEqual($0.localizedDescription,
                           "This file is not SSML: it begins with the element “html”, not “speak”.")
        }
    }

    func testAnotherRootThatIsNotWellFormedIsStillNotSSML() throws {
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<html><p>Hi.<br></html>".utf8))) {
            XCTAssertEqual($0 as? SSMLReader.Failure, .notSSML(rootElement: "html"))
        }
    }

    // MARK: - Damaged, empty, and oversized files

    func testATruncatedFileIsDamaged() throws {
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<speak><p>The ferry leaves".utf8))) {
            guard case SSMLReader.Failure.damaged = $0 else { return XCTFail("Expected damaged, got \($0)") }
            XCTAssertEqual($0.localizedDescription,
                           "This SSML file is damaged or incomplete: "
                           + "its markup breaks off early or has extra content after the end (line 1, column 27).")
        }
    }

    func testAnEmptyFileHasNoTextToRead() throws {
        let folder = try makeSandboxDirectory("SSMLReader")
        let file = folder.appendingPathComponent("empty.ssml")
        try Data().write(to: file)
        XCTAssertThrowsError(try SSMLReader.html(from: file)) {
            XCTAssertEqual($0.localizedDescription, "This file has no text to read.")
        }
    }

    func testAFilePastTheByteLimitIsRefused() throws {
        let copy = try copyOfFormatSample("ssml/passage.ssml")
        try DocumentByteLimit.$current.withValue(16) {
            XCTAssertThrowsError(try SSMLReader.html(from: copy)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 16))
            }
        }
    }

    // MARK: - External entities

    func testAnExternalEntityIsNeverResolved() throws {
        let ssml = "<!DOCTYPE speak [<!ENTITY outside SYSTEM \"file:///etc/hosts\">]><speak><p>A &outside; B</p></speak>"
        // The reader may read the file without the entity or refuse it; it
        // must never give the hosts file's text.
        if let html = try? SSMLReader.html(from: Data(ssml.utf8)) {
            XCTAssertFalse(html.contains("localhost"), html)
        }
    }
}
