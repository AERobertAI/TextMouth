import Foundation

// MARK: - Relationships

/// SAX parser for word/_rels/document.xml.rels to extract hyperlink targets
class DOCXRelationshipsParser: DOCXSAXParser {
    private var relationships: [String: String] = [:]

    /// Read every relationship's ID and target.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   truncated or not well-formed. Links whose targets came after the
    ///   damage would silently read as bare text.
    func parse() throws -> [String: String] {
        try parseDocument()
        return relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        if localName == "Relationship" {
            if let id = attributes["Id"], let target = attributes["Target"] {
                relationships[id] = target
            }
        }
    }
}
