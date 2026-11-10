import Foundation

// MARK: - Shared SAX Parsing

/// Common driver for the SAX parsers that read the XML files inside a book
/// package: DAISY's OPF, NCX, SMIL, and DTBook files, and the parts of a
/// Word document.
///
/// `XMLParser` stops at the first well-formedness error, but once `parse()`
/// returns, its `parserError` holds only a generic "stopped" code (libxml2's
/// `XML_ERR_USER_STOP`, 111) with no position. The actual cause and its line
/// and column arrive solely through `parser(_:parseErrorOccurred:)`, so this
/// class records that first report. Each format's subclass supplies the
/// error that reports a damaged file in that format's terms; its parsers
/// implement the element callbacks they need and call `parseDocument()`,
/// which throws that error naming the file. No caller can then mistake a
/// half-read file for a whole one.
class PackageSAXParser: NSObject, XMLParserDelegate {
    /// Builds a format's error for a damaged file from the file's path and a
    /// reason that completes the sentence "The file is damaged or incomplete: …".
    typealias MalformedXMLError = (_ file: String, _ reason: String) -> Error

    /// The file's raw bytes.
    let data: Data
    /// The file's path inside the package, named in every error it causes.
    let file: String

    /// Builds a format's error for a file TextMouth will not read although it
    /// is not damaged: it defines entities of its own, or is written in an
    /// encoding the guard cannot see through (`XMLInputGuard.Problem`).
    typealias RefusedXMLError = (_ file: String, _ problem: XMLInputGuard.Problem) -> Error

    /// Builds the error `parseDocument()` throws when the file is damaged.
    private let malformedXMLError: MalformedXMLError

    /// Builds the error `parseDocument()` throws for a file it refuses
    /// without its being damaged; nil for a format that reports every refusal
    /// as damage (`malformedXMLError`).
    private let refusedXMLError: RefusedXMLError?

    /// The first error the parser reported, with the position it reported.
    private var firstError: (code: Int, line: Int, column: Int)?

    /// Prepare to parse `data`, reporting problems under the name `file`
    /// with the error `malformedXMLError` builds, and refusals with the error
    /// `refusedXMLError` builds.
    init(
        data: Data,
        file: String,
        malformedXMLError: @escaping MalformedXMLError,
        refusedXMLError: RefusedXMLError? = nil
    ) {
        self.data = data
        self.file = file
        self.malformedXMLError = malformedXMLError
        self.refusedXMLError = refusedXMLError
    }

    /// Stream the file through `XMLParser`, delivering events to this delegate.
    /// - Throws: the format's refusal when the part defines entities of its own
    ///   or is in an encoding `XMLInputGuard` cannot see through, its
    ///   malformed-XML error when the part has a tag with more attributes than
    ///   it allows, or when the parser stops before the end of the document.
    ///   Events delivered before the stop stand, so a subclass may still
    ///   inspect what it had read.
    final func parseDocument() throws {
        // `XMLParser` takes time that grows with the square of the attributes
        // in one start tag, so a hostile part could stall an import, and
        // entities of its own or an encoding the guard cannot read hide the
        // tags from it. No real part has any of them (`XMLInputGuard`), so a
        // part that does is refused before the parser reads it: as damaged
        // for the attributes, and in its own sentence for the others, which
        // are no damage.
        //
        // The scan of a very large part takes seconds, so it ends when the
        // import is cancelled, and a part it did not finish is never handed
        // to the parser: the flag stays set, and the ask below throws.
        if let problem = XMLInputGuard.problem(with: data, stoppingWhenCancelled: true) {
            if problem != .tooManyAttributes, let refusedXMLError {
                throw refusedXMLError(file, problem)
            }
            throw malformedXMLError(file, XMLInputGuard.tooManyAttributesProblem)
        }
        try ImportCancellation.throwIfCancelled()

        let parser = XMLParser(data: data)
        parser.delegate = self
        // Handlers match elements by local name after stripping any prefix.
        parser.shouldProcessNamespaces = false
        // DAISY files name their DTDs by URL. Never load them or any other
        // external entity: in-memory data has no base URL, a network fetch
        // would stall parsing, and no handler relies on DTD defaults.
        parser.shouldResolveExternalEntities = false

        let finished = parser.parse()
        if finished && firstError == nil && parser.parserError == nil { return }
        throw malformedXMLError(file, failureReason(finalError: parser.parserError))
    }

    /// Keep the first report: it names the damage itself, while anything
    /// after it only describes the parser stopping.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard firstError == nil else { return }
        firstError = ((parseError as NSError).code, parser.lineNumber, parser.columnNumber)
    }

    // MARK: - Failure Descriptions

    /// Explain why parsing stopped, in words that complete the sentence
    /// "The file is damaged or incomplete: …", with the position when known.
    private func failureReason(finalError: Error?) -> String {
        // An empty file fails without a callback, and a blank one with a
        // misleading "unexpected end" at its last blank line.
        if data.allSatisfy(Self.isXMLWhitespace) {
            return "the file is empty"
        }
        guard let firstError else {
            let code = (finalError as NSError?)?.code ?? XMLParser.ErrorCode.internalError.rawValue
            return "its markup could not be read (XML parser error \(code))"
        }
        return "\(Self.problem(forCode: firstError.code)) (line \(firstError.line), column \(firstError.column))"
    }

    /// Plain-language descriptions of the errors damaged package files
    /// produce. A damaged feed is described in the same words (`FeedParser`).
    static func problem(forCode code: Int) -> String {
        switch XMLParser.ErrorCode(rawValue: code) {
        case .prematureDocumentEndError?:
            // libxml2 reports this code both for a file that stops inside an
            // element (a truncated copy) and for content after the root element.
            return "its markup breaks off early or has extra content after the end"
        case .invalidCharacterError?, .unknownEncodingError?, .encodingNotSupportedError?, .invalidEncodingError?:
            return "it contains characters that are not valid in its declared text encoding"
        case .undeclaredEntityError?:
            return "it uses a named character entity that XML does not define"
        case .tagNameMismatchError?, .notWellBalancedError?:
            return "a closing tag does not match the element it closes"
        case .misplacedXMLDeclarationError?:
            return "its XML declaration is not at the very start of the file"
        default:
            return "its markup is not well-formed XML (parser error \(code))"
        }
    }

    /// The four whitespace bytes XML allows between markup.
    private static func isXMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - Reporting Damage

/// How a damaged file in a book package is described and recorded. Every
/// format reports damage through these, so a reader hears the same sentence,
/// and the debug log holds the same kind of line, whatever the book's format.
enum PackageDamage {
    /// The sentence that tells a reader a file is damaged: it names the file,
    /// gives `reason`, which completes "is damaged or incomplete: …", and
    /// says what to do. `container` names what holds the file ("this DAISY
    /// book"), and `original` names what to get again ("the book").
    static func message(file: String, reason: String, container: String, original: String) -> String {
        "The file “\(file)” in \(container) is damaged or incomplete: \(reason). "
            + "Get a fresh copy of \(original), then import it again."
    }

    /// Record damage the import worked around, as one import event starting
    /// with `tag`, in the console and in the debug log. The import layer has
    /// no warning channel yet, so this line is the only record of the damage.
    static func log(_ damage: Error, tag: String) {
        DiagnosticLog.event(.import, "\(tag): \(damage.localizedDescription)")
    }
}
