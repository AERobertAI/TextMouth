import Foundation

// MARK: - DOCX SAX Parsing

/// Common base for the SAX parsers that read the XML parts of a DOCX
/// package.
///
/// `PackageSAXParser` drives the parse and describes any damage; this class
/// reports a damaged part as `DOCXParserError.malformedXML`, naming it by its
/// path inside the package, so every DOCX caller handles one error type
/// whatever part failed.
class DOCXSAXParser: PackageSAXParser {
    /// Prepare to parse `data`, reporting problems under the part path `file`.
    init(data: Data, file: String) {
        super.init(data: data, file: file, malformedXMLError: DOCXParserError.malformedXML)
    }
}
