import Foundation

// MARK: - SMIL Parser

/// What one SMIL file points at (PG08): the text fragments it synchronizes,
/// in reading order, and the same references found by the `id` of the
/// `text` element or enclosing `par` that holds them, so a DAISY 2.02 page
/// entry that names a `par` or a `text` can be followed to its content.
struct DAISYSMILReferences {
    /// The `src` of every `text` element that has one, in reading order.
    var textReferences: [String] = []
    /// Each `text` element's `id`, and each enclosing `par`'s `id`, mapped to
    /// the `src` of the first `text` element they hold.
    var textReferencesByID: [String: String] = [:]
}

/// Minimal SAX parser for DAISY SMIL files.
/// Extracts text content references (the src attributes of <text> elements).
class DAISYSMILParser: DAISYSAXParser {
    private var references = DAISYSMILReferences()
    /// The `id` of each `par` element now open, innermost last; an empty
    /// string stands for a `par` without an id.
    private var parIDStack: [String] = []

    /// The text fragments the file synchronizes, in reading order.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   truncated or not well-formed; the references after the damage would
    ///   otherwise vanish from the book's text without notice.
    func parseTextReferences() throws -> [String] {
        try parseReferences().textReferences
    }

    /// The text fragments the file synchronizes, in reading order, and the
    /// same references by `id`, from one parse of the file (PG08).
    /// - Throws: as `parseTextReferences()`.
    func parseReferences() throws -> DAISYSMILReferences {
        try parseDocument()
        return references
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        if localName == "par" {
            parIDStack.append(attributes["id"] ?? "")
        } else if localName == "text" {
            if let src = attributes["src"], !src.isEmpty {
                references.textReferences.append(src)
                // The first text a par (or a text id) holds is where it points.
                let ids = [attributes["id"], parIDStack.last].compactMap { $0 }.filter { !$0.isEmpty }
                for id in ids where references.textReferencesByID[id] == nil {
                    references.textReferencesByID[id] = src
                }
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if ParserUtilities.stripNamespacePrefix(elementName).lowercased() == "par" {
            _ = parIDStack.popLast()
        }
    }
}
