import Foundation

// MARK: - DAISY 2.02 NCC Parser

/// Parsed NCC (Navigation Control Center) data from a DAISY 2.02 book
struct DAISY202NCCResult {
    var title: String = ""
    var author: String = ""
    var headings: [NCCHeading] = []
}

/// A heading entry from the DAISY 2.02 NCC file
struct NCCHeading {
    var level: Int
    var text: String
    var href: String
}

/// SAX parser for DAISY 2.02 ncc.html files.
/// Extracts metadata from <meta> tags and navigation structure from headings.
class DAISY202NCCParser: NSObject, XMLParserDelegate {
    private let html: String
    private var result = DAISY202NCCResult()

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""
    private var currentHeadingLevel: Int?
    private var currentHref = ""
    private var inHeading = false
    private var inAnchor = false

    init(html: String) {
        self.html = html
    }

    func parse() -> DAISY202NCCResult {
        // NCC files may not be well-formed XML, so try to clean them up
        var cleanedHTML = html
        // Add XML declaration if missing (check trimmed to handle leading whitespace)
        let trimmedHTML = cleanedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHTML.hasPrefix("<?xml") {
            cleanedHTML = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + cleanedHTML
        }

        guard let data = cleanedHTML.data(using: .utf8) else { return result }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        elementStack.append(localName)

        switch localName {
        case "meta":
            // Extract Dublin Core metadata from meta tags
            let name = (attributes["name"] ?? "").lowercased()
            let content = attributes["content"] ?? ""
            switch name {
            case "dc:title":
                if result.title.isEmpty { result.title = content }
            case "dc:creator":
                if result.author.isEmpty { result.author = content }
            default:
                break
            }

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(localName.last!)) ?? 1
            currentHeadingLevel = level
            currentText = ""
            currentHref = ""
            inHeading = true

        case "a" where inHeading:
            currentHref = attributes["href"] ?? ""
            inAnchor = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHeading {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        switch localName {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if let level = currentHeadingLevel {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.headings.append(NCCHeading(level: level, text: text, href: currentHref))
                }
            }
            inHeading = false
            currentHeadingLevel = nil

        case "a":
            inAnchor = false

        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}
