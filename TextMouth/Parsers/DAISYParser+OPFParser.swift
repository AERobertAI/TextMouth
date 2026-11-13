import Foundation

// MARK: - DAISY 3 OPF Parser

/// Parsed OPF package data
struct DAISYOPFResult {
    var title: String = ""
    var author: String = ""
    var manifest: [String: DAISYManifestItem] = [:]
    /// The manifest items' IDs in the order the file lists them (a dictionary
    /// has no order, and one that changes from launch to launch must never
    /// decide the order a book is read in). An ID listed twice is placed where
    /// it first appears.
    var manifestOrder: [String] = []
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
class DAISYOPFParser: DAISYSAXParser {
    private var result = DAISYOPFResult()

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""

    /// Parse the package's metadata, manifest, and spine.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   truncated or not well-formed. A partial manifest or spine would
    ///   silently drop content files from the book.
    func parse() throws -> DAISYOPFResult {
        try parseDocument()
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
                if result.manifest[id] == nil { result.manifestOrder.append(id) }
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
