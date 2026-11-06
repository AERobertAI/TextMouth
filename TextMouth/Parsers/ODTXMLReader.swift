import Foundation

// MARK: - The XML Reader of an OpenDocument Part

/// The base of the readers of the XML parts of an OpenDocument package
/// (FMT27): `meta.xml`, `styles.xml`, and `content.xml`. It is an
/// `OfficeXMLReader` that reads names by OpenDocument's namespaces and ends a
/// damaged part with the sentence for an unreadable OpenDocument document.
class ODTXMLReader: OfficeXMLReader {
    /// The prefix each OpenDocument namespace is read as.
    private static let usualPrefixes: [String: String] = [
        "urn:oasis:names:tc:opendocument:xmlns:office:1.0": "office",
        "urn:oasis:names:tc:opendocument:xmlns:text:1.0": "text",
        "urn:oasis:names:tc:opendocument:xmlns:table:1.0": "table",
        "urn:oasis:names:tc:opendocument:xmlns:style:1.0": "style",
        "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0": "fo",
        "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0": "draw",
        "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0": "svg",
        "urn:oasis:names:tc:opendocument:xmlns:meta:1.0": "meta",
        "http://purl.org/dc/elements/1.1/": "dc",
    ]

    /// Prepares to read `data`, the part at `file` in the package.
    init(data: Data, file: String) {
        super.init(data: data, file: file, format: .odt, usualPrefixes: Self.usualPrefixes)
    }
}
