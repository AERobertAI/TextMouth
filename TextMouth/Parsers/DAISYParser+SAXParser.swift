import Foundation

// MARK: - DAISY SAX Parsing

/// Common base for the SAX parsers that read DAISY's XML files: the OPF
/// package, NCX navigation, SMIL synchronization, and DTBook content.
///
/// `PackageSAXParser` drives the parse and describes any damage; this class
/// reports a damaged file as `DAISYParserError.malformedXML`, naming it, so
/// every DAISY caller handles one error type whatever file failed.
class DAISYSAXParser: PackageSAXParser {
    /// Prepare to parse `data`, reporting problems under the name `file`.
    init(data: Data, file: String) {
        super.init(data: data, file: file, malformedXMLError: DAISYParserError.malformedXML)
    }

    /// Read `path` from `provider` and prepare to parse it under that name,
    /// so an error always names the file that was actually read.
    /// - Throws: the provider's error when the file cannot be read.
    convenience init(path: String, in provider: DAISYFileProvider) throws {
        self.init(data: try provider.readFile(at: path), file: path)
    }
}
