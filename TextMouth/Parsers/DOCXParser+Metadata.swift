import Foundation

// MARK: - Metadata

/// Basic metadata extracted from docProps/core.xml
struct DOCXMetadata {
    var title: String
    var author: String
}

/// SAX parser for docProps/core.xml to extract title and author
class DOCXMetadataParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var title = ""
    private var author = ""
    private var currentElement = ""
    private var currentText = ""

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> DOCXMetadata {
        guard let data = xml.data(using: .utf8) else {
            return DOCXMetadata(title: "", author: "")
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return DOCXMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Strip namespace prefix (e.g. "dc:title" -> "title", "cp:lastModifiedBy" -> "lastModifiedBy")
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        currentElement = localName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        switch localName {
        case "title":
            if title.isEmpty { title = currentText }
        case "creator":
            if author.isEmpty { author = currentText }
        default:
            break
        }
    }
}
