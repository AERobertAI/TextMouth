import Foundation

// MARK: - DAISY 3 OPF Parser

/// Parsed OPF package data
struct DAISYOPFResult {
    var title: String = ""
    var author: String = ""
    var manifest: [String: DAISYManifestItem] = [:]
    /// Ordered list of manifest item IDs defining the reading sequence
    var spineItemRefs: [String] = []
}

/// A single item from the OPF manifest
struct DAISYManifestItem {
    var id: String
    var href: String
    var mediaType: String
}

/// SAX parser for DAISY 3 OPF package files.
/// These use the OEB package namespace and contain dc-metadata for Dublin Core fields.
class DAISYOPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result = DAISYOPFResult()

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> DAISYOPFResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        elementStack.append(localName.lowercased())
        currentText = ""

        switch localName.lowercased() {
        case "item":
            // Manifest item
            if let id = attributes["id"], let href = attributes["href"],
               let mediaType = attributes["media-type"] {
                result.manifest[id] = DAISYManifestItem(id: id, href: href, mediaType: mediaType)
            }
        case "itemref":
            // Spine item reference — defines reading order
            if let idref = attributes["idref"] {
                result.spineItemRefs.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "title":
            if result.title.isEmpty && !text.isEmpty { result.title = text }
        case "creator":
            if result.author.isEmpty && !text.isEmpty { result.author = text }
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}
