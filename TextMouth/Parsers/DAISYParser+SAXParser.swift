import Foundation

// MARK: - Shared SAX Parsing

/// Common driver for the SAX parsers that read DAISY's XML files: the OPF
/// package, NCX navigation, SMIL synchronization, and DTBook content.
///
/// `XMLParser` stops at the first well-formedness error, but once `parse()`
/// returns, its `parserError` holds only a generic "stopped" code (libxml2's
/// `XML_ERR_USER_STOP`, 111) with no position. The actual cause and its line
/// and column arrive solely through `parser(_:parseErrorOccurred:)`, so this
/// class records that first report. Subclasses implement the element
/// callbacks they need and call `parseDocument()`, which throws
/// `DAISYParserError.malformedXML` naming the file. No caller can then
/// mistake a half-read package, navigation map, or clip list for a whole one.
class DAISYSAXParser: NSObject, XMLParserDelegate {
    /// The file's raw bytes.
    let data: Data
    /// The file's path inside the package, named in every error it causes.
    let file: String

    /// The first error the parser reported, with the position it reported.
    private var firstError: (code: Int, line: Int, column: Int)?

    /// Prepare to parse `data`, reporting problems under the name `file`.
    init(data: Data, file: String) {
        self.data = data
        self.file = file
    }

    /// Read `path` from `provider` and prepare to parse it under that name,
    /// so an error always names the file that was actually read.
    /// - Throws: the provider's error when the file cannot be read.
    convenience init(path: String, in provider: DAISYFileProvider) throws {
        self.init(data: try provider.readFile(at: path), file: path)
    }

    /// Stream the file through `XMLParser`, delivering events to this delegate.
    /// - Throws: `DAISYParserError.malformedXML` when the parser stops before
    ///   the end of the document. Events delivered before the stop stand, so
    ///   a subclass may still inspect what it had read.
    final func parseDocument() throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Handlers match elements by local name after stripping any prefix.
        parser.shouldProcessNamespaces = false
        // DAISY files name their DTDs by URL. Never load them: in-memory data
        // has no base URL, a network fetch would stall parsing, and no handler
        // relies on DTD defaults.
        parser.shouldResolveExternalEntities = false

        let finished = parser.parse()
        if finished && firstError == nil && parser.parserError == nil { return }
        throw DAISYParserError.malformedXML(file: file, reason: failureReason(finalError: parser.parserError))
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

    /// Plain-language descriptions of the errors damaged DAISY files produce.
    private static func problem(forCode code: Int) -> String {
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
