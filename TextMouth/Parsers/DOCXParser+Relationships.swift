import Foundation

// MARK: - Relationships

/// SAX parser for word/_rels/document.xml.rels to extract hyperlink targets
class DOCXRelationshipsParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var relationships: [String: String] = [:]

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> [String: String] {
        guard let data = xml.data(using: .utf8) else { return relationships }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
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
