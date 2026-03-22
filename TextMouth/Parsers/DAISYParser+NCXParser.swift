import Foundation

// MARK: - NCX Parser (for DAISY 3 navigation)

/// A navigation point from the NCX
struct DAISYNavPoint {
    var label: String
    var contentSrc: String  // SMIL reference
    var level: Int
}

/// SAX parser for DAISY 3 NCX files to extract navigation points
class DAISYNCXParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var navPoints: [DAISYNavPoint] = []

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""
    private var currentLabel = ""
    private var currentSrc = ""
    private var depthCounter = 0
    private var inNavPoint = false
    private var inNavLabel = false
    private var inText = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [DAISYNavPoint] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return navPoints
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        elementStack.append(localName)

        switch localName {
        case "navpoint":
            depthCounter += 1
            inNavPoint = true
            currentLabel = ""
            currentSrc = ""
        case "navlabel" where inNavPoint:
            inNavLabel = true
        case "text" where inNavLabel:
            inText = true
            currentText = ""
        case "content" where inNavPoint:
            currentSrc = attributes["src"] ?? ""
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
            if inNavPoint && !currentLabel.isEmpty && !currentSrc.isEmpty {
                navPoints.append(DAISYNavPoint(
                    label: currentLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                    contentSrc: currentSrc,
                    level: depthCounter
                ))
            }
            depthCounter = max(0, depthCounter - 1)
            if depthCounter == 0 { inNavPoint = false }
        case "navlabel":
            inNavLabel = false
        case "text" where inNavLabel:
            currentLabel = currentText
            inText = false
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}
