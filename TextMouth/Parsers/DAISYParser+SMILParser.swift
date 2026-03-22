import Foundation

// MARK: - SMIL Parser

/// Minimal SAX parser for DAISY SMIL files.
/// Extracts text content references (the src attributes of <text> elements).
class DAISYSMILParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var textReferences: [String] = []

    init(data: Data) {
        self.data = data
    }

    func parseTextReferences() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return textReferences
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        if localName == "text" {
            if let src = attributes["src"], !src.isEmpty {
                textReferences.append(src)
            }
        }
    }
}
