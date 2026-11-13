import Foundation

// MARK: - SSML Reader

/// Reads an SSML file (W3C Speech Synthesis Markup Language, `.ssml`) as a
/// text book (FMT07): the markup is removed and the paragraphs and
/// sentences are kept, as simple HTML that `HTMLToMarkdownConverter` reads
/// as it reads every other HTML book.
///
/// The file is never given to the speech engine as SSML, and never as text
/// with its tags: `AVSpeechUtterance(ssmlRepresentation:)` ignores the
/// book's rate, pitch, and `sub` aliases and crashed on an `emphasis`
/// element, and the engine takes tag-shaped text for markup of its own
/// (`SpeechMarkupGuard`). Reading the words out of the file avoids both.
enum SSMLReader {
    // MARK: Failures

    /// Why an SSML file could not be read.
    enum Failure: LocalizedError, Equatable {
        /// The file is XML but its root element is not `speak`; the name
        /// is the element's local name, without any prefix.
        case notSSML(rootElement: String)
        /// The file is not well-formed XML; `reason` completes the sentence
        /// as `PackageSAXParser` words it, with the position.
        case damaged(reason: String)
        /// The file is not damaged, but TextMouth will not read it: it defines
        /// entities of its own, or is written in an encoding the guard cannot
        /// see through (`XMLInputGuard`).
        case unsafe(XMLInputGuard.Problem)

        var errorDescription: String? {
            switch self {
            case .notSSML(let rootElement):
                return "This file is not SSML: it begins with the element “\(rootElement)”, not “speak”."
            case .damaged(let reason):
                return "This SSML file is damaged or incomplete: \(reason)."
            case .unsafe(.encoding(let name)):
                return "TextMouth can't safely read this SSML file, because it is written in the \(name) encoding. "
                    + "Save it as UTF-8, then import it again."
            case .unsafe:
                return "TextMouth can't safely read this SSML file, because it defines entities of its own. "
                    + "Open it in a text editor, take the entity definitions out, save it, then import it again."
            }
        }
    }

    // MARK: Reading

    /// The HTML for the SSML file at `url`.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for one past `DocumentByteLimit`, and
    ///   whatever `html(from:)` throws.
    static func html(from url: URL) throws -> String {
        try html(from: DocumentByteLimit.contents(of: url))
    }

    /// The HTML for SSML `data`: a `<p>` for each paragraph, in order,
    /// inside `<html><body>`. A document with no words gives a body with
    /// no paragraph, which the import refuses as having no text.
    /// - Throws: `Failure.notSSML` when the root element is not `speak`,
    ///   and `Failure.damaged` when the XML is truncated or malformed.
    static func html(from data: Data) throws -> String {
        let builder = HTMLBuilder(data: data)
        // Keep the parse's outcome aside: a wrong root stops the parser on
        // purpose, which `parseDocument()` reports as damage, and the wrong
        // root is the real cause.
        let outcome = Result { try builder.parseDocument() }
        if let wrongRoot = builder.wrongRoot { throw Failure.notSSML(rootElement: wrongRoot) }
        try outcome.get()
        let body = builder.paragraphs.map { "<p>\($0)</p>" }.joined()
        return "<html><body>\(body)</body></html>"
    }

    // MARK: HTML Builder

    /// The SAX parser that turns SSML elements into paragraphs of HTML.
    /// Elements are matched by local name (any prefix stripped) and by
    /// case, as SSML is case-sensitive. External entities are never
    /// resolved (`PackageSAXParser`), and `audio`'s `src` is never read.
    private final class HTMLBuilder: PackageSAXParser {
        /// The finished paragraphs' inner HTML, in order.
        private(set) var paragraphs: [String] = []
        /// The local name of the root element, when it is not `speak`.
        private(set) var wrongRoot: String?

        /// The paragraph being written, as HTML (text already escaped).
        private var current = ""
        /// Whether the root element has been seen.
        private var sawRoot = false
        /// For each open `emphasis` element, innermost last, whether it
        /// asks for emphasis (any level but "none"), so its end knows
        /// whether its start counted in `emphasisDepth`.
        private var emphasisStack: [Bool] = []
        /// How many emphatic `emphasis` elements enclose the text being
        /// read; only the outermost writes tags, since nested ones add
        /// nothing to a listener.
        private var emphasisDepth = 0
        /// How many open elements lie inside one whose text is not written
        /// (`desc`, `meta`, `metadata`, `lexicon`, or a `sub` with an
        /// alias), counting that element itself. Zero while text is written.
        private var skipDepth = 0

        /// Prepare to read `data`; a damaged file is `Failure.damaged`.
        init(data: Data) {
            super.init(
                data: data, file: "SSML",
                malformedXMLError: { _, reason in Failure.damaged(reason: reason) },
                refusedXMLError: { _, problem in Failure.unsafe(problem) })
        }

        // MARK: Elements

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String]) {
            let name = ParserUtilities.stripNamespacePrefix(elementName)

            // The first element is the root: anything but `speak` is not SSML.
            if !sawRoot {
                sawRoot = true
                if name != "speak" {
                    wrongRoot = name
                    parser.abortParsing()
                    return
                }
            }

            // Inside an element whose text is dropped, everything is dropped.
            if skipDepth > 0 {
                skipDepth += 1
                return
            }

            switch name {
            case "p", "paragraph":
                // A paragraph ends any text that came before it outside one.
                finishParagraph()
            case "break", "voice", "audio", "s", "sentence":
                // A pause, a change of voice, a sound, and a sentence's
                // start are word boundaries, never paragraphs: words on
                // either side of one never run together.
                current += " "
            case "emphasis":
                // Level "none" asks for no emphasis: its content only.
                let emphatic = attributeDict["level"] != "none"
                emphasisStack.append(emphatic)
                if emphatic {
                    emphasisDepth += 1
                    if emphasisDepth == 1 { current += "<em>" }
                }
            case "sub":
                // Speak the alias in place of the content; keep the content
                // when there is no alias to speak.
                let alias = (attributeDict["alias"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !alias.isEmpty {
                    current += XMLEscaping.markup(alias)
                    skipDepth = 1
                }
            case "desc", "meta", "metadata", "lexicon":
                skipDepth = 1
            default:
                // say-as, phoneme, prosody, lang, token, w, mark, and
                // unknown elements: content only.
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            switch ParserUtilities.stripNamespacePrefix(elementName) {
            case "p", "paragraph":
                finishParagraph()
            case "s", "sentence", "voice", "audio":
                // Sentences never run together, whatever sits between the
                // tags, and a voice or a sound ends its words.
                current += " "
            case "emphasis":
                if emphasisStack.popLast() == true {
                    emphasisDepth -= 1
                    if emphasisDepth == 0 { current += "</em>" }
                }
            default:
                break
            }
        }

        // MARK: Text

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            write(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            write(String(decoding: CDATABlock, as: UTF8.self))
        }

        /// The end of the document ends the paragraph still being written.
        func parserDidEndDocument(_ parser: XMLParser) {
            finishParagraph()
        }

        /// Add `text` to the paragraph, escaped, unless it lies inside a
        /// dropped element.
        private func write(_ text: String) {
            guard skipDepth == 0 else { return }
            current += XMLEscaping.markup(text)
        }

        // MARK: Paragraphs

        /// Close the paragraph being written: tidy it and keep it when it
        /// has words. An open `emphasis` is closed here and reopened for
        /// the next paragraph, so every paragraph's tags balance.
        private func finishParagraph() {
            if emphasisDepth > 0 { current += "</em>" }
            let text = Self.tidy(current)
            if !text.isEmpty { paragraphs.append(text) }
            current = emphasisDepth > 0 ? "<em>" : ""
        }

        /// `html` with runs of white space made one space, the ends trimmed,
        /// emphasis tags hugging their words (a space belongs outside them,
        /// or Markdown would not read the emphasis), and empty emphasis dropped.
        private static func tidy(_ html: String) -> String {
            collapsed(collapsed(html)
                .replacingOccurrences(of: "<em> ", with: " <em>")
                .replacingOccurrences(of: " </em>", with: "</em> ")
                .replacingOccurrences(of: "<em></em>", with: ""))
        }

        /// `text` with each run of white space made one space and the ends trimmed.
        private static func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
