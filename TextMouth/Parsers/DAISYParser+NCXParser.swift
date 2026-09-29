import Foundation

// MARK: - NCX Parser (for DAISY 3 navigation)

/// A navigation point from the NCX
struct DAISYNavPoint {
    var label: String
    var contentSrc: String  // SMIL reference
    var level: Int
}

/// SAX parser for DAISY 3 NCX files to extract navigation points
class DAISYNCXParser: DAISYSAXParser {
    private var navPoints: [DAISYNavPoint] = []

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""
    /// Reserve each point in document order and keep a stack of its index.
    /// Nested points must not overwrite their parent's label/source, and
    /// emitting only at </navPoint> would reverse the reading order.
    private var navPointStack: [Int] = []
    private var inNavLabel = false
    private var inText = false

    /// Parse the navigation map into points in document order.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   truncated or not well-formed. Audio segments follow this list, so a
    ///   partial map would silently end the book early.
    func parse() throws -> [DAISYNavPoint] {
        try parseDocument()
        return navPoints.filter { !$0.label.isEmpty && !$0.contentSrc.isEmpty }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        elementStack.append(localName)

        switch localName {
        case "navpoint":
            let level = navPointStack.count + 1
            navPointStack.append(navPoints.count)
            navPoints.append(DAISYNavPoint(label: "", contentSrc: "", level: level))
        case "navlabel" where !navPointStack.isEmpty:
            inNavLabel = true
        case "text" where inNavLabel:
            inText = true
            currentText = ""
        case "content":
            if let index = navPointStack.last {
                navPoints[index].contentSrc = attributes["src"] ?? ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        switch localName {
        case "navpoint":
            _ = navPointStack.popLast()
        case "navlabel":
            inNavLabel = false
        case "text" where inNavLabel:
            if let index = navPointStack.last {
                navPoints[index].label = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            inText = false
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}
