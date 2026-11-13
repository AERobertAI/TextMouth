import Foundation

// MARK: - Subscription Lists (FR03)

/// One subscription an OPML file lists (FR03): the feed's address, its
/// title as the file gives it, and its web site.
struct OPMLSubscription: Equatable, Sendable {
    /// The feed's title, as the outline's title or text gives it, or the
    /// address's host when it gives neither.
    var title: String
    /// The feed's address.
    var feedURL: URL
    /// The feed's web site, when the outline names one.
    var siteURL: URL?
}

/// Why an OPML file could not be read (FR03), in sentences a listener reads.
enum OPMLReadError: Error, Equatable, Sendable {
    /// The file is empty.
    case empty
    /// The file is not an OPML document.
    case notOPML
    /// The file could not be read even after repairing its markup.
    case damaged(problem: String, line: Int)
    /// The file lists no feed TextMouth can subscribe to.
    case noFeeds

    /// The sentence the Library window shows and VoiceOver speaks.
    var message: String {
        switch self {
        case .empty:
            return "That file is empty."
        case .notOPML:
            return "That file isn't an OPML list of subscriptions."
        case let .damaged(problem, line):
            return "That OPML file is damaged at line \(line): \(problem)."
        case .noFeeds:
            return "That OPML file lists no feeds."
        }
    }
}

/// Reads and writes OPML 2.0 subscription lists (FR03), the format feed
/// readers exchange their subscriptions in: subscriptions only, with no
/// episode's state.
///
/// Reading takes every outline that names a feed (`xmlUrl`, which some
/// readers write in another letter case), at any depth, in document order,
/// each address once, walking into the outlines that only group others,
/// which are categories; external entities are never loaded. A file whose
/// markup is not well-formed, as files exported with a bare "&" in a title
/// often are, is read again after XMLDocument's tidying, as a damaged feed
/// is. Writing gives each feed an outline with its type, text, title,
/// address, and web site.
enum FeedOPML {
    /// The most bytes of an OPML file read: a list of thousands of feeds
    /// is a few hundred kilobytes.
    static let maximumBytes = 10 * 1_024 * 1_024

    // MARK: Reading

    /// The subscriptions the OPML document `data` lists.
    /// - Throws: `OPMLReadError`.
    static func subscriptions(in data: Data) throws(OPMLReadError) -> [OPMLSubscription] {
        guard data.contains(where: { !isXMLWhitespace($0) }) else { throw .empty }
        guard data.count <= maximumBytes else { throw .damaged(problem: "the file is larger than TextMouth reads", line: 1) }
        // As for a feed, the attributes and the encoding are asked, and not the
        // entities of the file's own (`XMLInputGuard`).
        if let problem = XMLInputGuard.problemLeavingDefinitions(with: data) {
            throw .damaged(problem: XMLInputGuard.reason(for: problem), line: 1)
        }
        let strict = OPMLStrictReading(data: data)
        switch strict.read() {
        case .read(let outlines):
            return try subscriptions(from: outlines)
        case .notOPML:
            throw .notOPML
        case let .fault(code, line):
            guard let outlines = tidiedOutlines(of: data) else {
                throw .damaged(problem: PackageSAXParser.problem(forCode: code), line: line)
            }
            return try subscriptions(from: outlines)
        }
    }

    /// The subscriptions `outlines` name, each address once, or none.
    /// - Throws: `OPMLReadError.noFeeds` when no outline names a feed
    ///   TextMouth can subscribe to.
    private static func subscriptions(from outlines: [[String: String]]) throws(OPMLReadError) -> [OPMLSubscription] {
        var seen = Set<String>()
        var found: [OPMLSubscription] = []
        for attributes in outlines {
            guard let subscription = subscription(from: attributes),
                  seen.insert(FeedAddress.comparisonKey(subscription.feedURL)).inserted else { continue }
            found.append(subscription)
        }
        guard !found.isEmpty else { throw .noFeeds }
        return found
    }

    /// The subscription an outline's attributes name, or nil when they name
    /// no feed TextMouth fetches: attribute names in any letter case, the
    /// address as a listener would type it (`FeedAddress.normalized`).
    static func subscription(from attributes: [String: String]) -> OPMLSubscription? {
        let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let address = lowered["xmlurl"], let feedURL = FeedAddress.normalized(address) else { return nil }
        let named = [lowered["title"], lowered["text"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let site = lowered["htmlurl"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return OPMLSubscription(
            title: named ?? (feedURL.host ?? feedURL.absoluteString),
            feedURL: feedURL,
            siteURL: site.flatMap { FeedTransport.isWebAddress($0) ? $0 : nil }
        )
    }

    /// The attributes of every outline of `data`, read after XMLDocument's
    /// tidying, in document order; nil when even that reading finds no OPML
    /// document.
    private static func tidiedOutlines(of data: Data) -> [[String: String]]? {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(),
              root.name?.lowercased() == "opml" else { return nil }
        var outlines: [[String: String]] = []
        var elements: [XMLElement] = [root]
        // Depth first, in document order: children before later siblings.
        while let element = elements.popLast() {
            if element.name?.lowercased() == "outline" {
                var attributes: [String: String] = [:]
                for attribute in element.attributes ?? [] {
                    if let name = attribute.name, let value = attribute.stringValue {
                        attributes[name] = value
                    }
                }
                outlines.append(attributes)
            }
            let children = (element.children ?? []).compactMap { $0 as? XMLElement }
            elements.append(contentsOf: children.reversed())
        }
        return outlines
    }

    /// Whether `byte` is XML whitespace.
    private static func isXMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: Writing

    /// An OPML 2.0 document listing `feeds` in order, titled `title`, made
    /// at `date`: each feed an outline of type "rss" with its title as text
    /// and title, its address, and its web site when it names one.
    static func document(listing feeds: [Feed], title: String, date: Date) -> Data {
        let outlines = feeds.map { feed -> String in
            var attributes = [
                ("type", "rss"),
                ("text", feed.title),
                ("title", feed.title),
                ("xmlUrl", feed.feedURL.absoluteString),
            ]
            if let site = feed.siteLink {
                attributes.append(("htmlUrl", site.absoluteString))
            }
            let written = attributes.map { "\($0.0)=\"\(XMLEscaping.attribute($0.1))\"" }.joined(separator: " ")
            return "    <outline \(written)/>"
        }
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>\(XMLEscaping.attribute(title))</title>
            <dateCreated>\(rfc822(date))</dateCreated>
          </head>
          <body>
        \(outlines.joined(separator: "\n"))
          </body>
        </opml>

        """
        return Data(text.utf8)
    }

    /// `date` as RFC 822 writes it, as OPML's dateCreated asks: "Sun, 04 Oct
    /// 2026 15:30:00 GMT".
    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

// MARK: - The Strict Reading

/// Reads an OPML document with `XMLParser`, never loading an external
/// entity, keeping the attributes of every outline, or the first fault in
/// its markup.
private final class OPMLStrictReading: NSObject, XMLParserDelegate {
    /// How the reading ended.
    enum Outcome {
        /// The document is OPML: each outline's attributes, in order.
        case read([[String: String]])
        /// The document's root is not OPML's.
        case notOPML
        /// The markup is not well-formed, at the line given; `code` is
        /// `XMLParser`'s error code.
        case fault(code: Int, line: Int)
    }

    /// The document.
    private let data: Data
    /// Each outline's attributes, in order.
    private var outlines: [[String: String]] = []
    /// Whether the root element has been seen, and whether it was OPML's.
    private var rootIsOPML: Bool?
    /// The first fault the parser reported.
    private var firstFault: (code: Int, line: Int)?

    /// A reading of `data`.
    init(data: Data) {
        self.data = data
    }

    /// Reads the document.
    func read() -> Outcome {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        // Never load an external entity: a DOCTYPE could name a file on this
        // Mac.
        parser.shouldResolveExternalEntities = false
        let finished = parser.parse()
        if rootIsOPML == false {
            return .notOPML
        }
        if !finished || firstFault != nil {
            let fault = firstFault ?? (
                (parser.parserError as NSError?)?.code ?? XMLParser.ErrorCode.internalError.rawValue,
                parser.lineNumber
            )
            return .fault(code: fault.code, line: fault.line)
        }
        return rootIsOPML == true ? .read(outlines) : .notOPML
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if rootIsOPML == nil {
            rootIsOPML = name == "opml"
            if rootIsOPML == false {
                parser.abortParsing()
                return
            }
        }
        if name == "outline" {
            outlines.append(attributeDict)
        }
    }

    /// Keeps the first fault, which names the damage itself.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard firstFault == nil, rootIsOPML != false else { return }
        firstFault = ((parseError as NSError).code, parser.lineNumber)
    }
}
