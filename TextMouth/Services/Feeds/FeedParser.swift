import Foundation

// MARK: - What a Feed Holds (FR03)

/// A feed as read from its document (FR03): what it says about itself and
/// each item it lists, before anything is compared with what TextMouth keeps
/// (`FeedReconciler`).
struct ParsedFeed: Equatable, Sendable {
    /// The document's format.
    enum Format: String, Equatable, Sendable {
        /// RSS 0.9x or 2.0.
        case rss
        /// RSS 1.0, whose items sit beside its channel in an RDF document.
        case rdf
        /// Atom (RFC 4287), or the Atom 0.3 that preceded it.
        case atom
        /// JSON Feed 1.1, or the 1.0 that preceded it (`JSONFeedParser`).
        case json
    }

    /// The document's format.
    var format: Format
    /// The feed's title, as one line of plain text; empty when it gives none.
    var title: String
    /// The feed's web site.
    var siteLink: URL?
    /// What the feed says about itself.
    var summary: FeedTextSource?
    /// Who publishes the feed.
    var author: String?
    /// Whether the feed says it is a serial show (`itunes:type` serial).
    var isSerial: Bool
    /// The address the feed says it has moved to (`itunes:new-feed-url`).
    var newFeedURL: URL?
    /// The items, in the document's order.
    var items: [ParsedItem]
    /// How the document was repaired before it could be read, or nil when it
    /// was well-formed.
    var repair: FeedParseRepair?
    /// Whether the document listed more items than TextMouth reads
    /// (`FeedParser.maximumItems`), so only the first ones were read.
    var reachedItemLimit: Bool
}

/// One item as read from a feed's document.
struct ParsedItem: Equatable, Sendable {
    /// Its guid, or an Atom entry's id.
    var guid: String?
    /// Its title, as one line of plain text: the title the feed gives, or the
    /// start of its summary when it gives none.
    var title: String
    /// Its web page.
    var link: URL?
    /// Its summary.
    var summary: FeedTextSource?
    /// Its full content, when the feed gives more than the summary.
    var content: FeedTextSource?
    /// When it was published, when the feed says in a form TextMouth reads.
    var published: Date?
    /// The file it offers.
    var enclosure: FeedEnclosure?
    /// How long it plays, in seconds.
    var duration: TimeInterval?
    /// Who wrote or presents it.
    var author: String?
    /// Its episode number.
    var episodeNumber: Int?
    /// Its transcripts.
    var transcripts: [FeedResource]
    /// Its chapters file.
    var chapters: FeedResource?
    /// Where it is in the document, counting from 0.
    var position: Int

    /// The identity the item is known by (`FeedItemIdentity`).
    var identity: String {
        FeedItemIdentity.key(
            guid: guid,
            enclosureURL: enclosure?.url,
            link: link,
            title: title,
            summaryHTML: summary?.text
        )
    }

    /// The most characters of an item's text that stand in for a title it
    /// lacks.
    static let standInTitleLength = 80

    /// The title an item that gives none is listed by: the start of its
    /// text `text`, as one line of plain text.
    static func standInTitle(from text: String, isHTML: Bool) -> String {
        String(FeedTextConverter.plainLine(text, isHTML: isHTML).prefix(standInTitleLength))
    }

    /// Whether `content` only repeats `summary`, whitespace aside, so the
    /// item keeps the summary alone.
    static func isRepeating(_ content: FeedTextSource, _ summary: FeedTextSource?) -> Bool {
        content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == summary?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How a feed whose markup is not well-formed was read (FR03): what the
/// strict reading found first, and how many items it had read before that.
/// The tidy reading then read the whole document.
struct FeedParseRepair: Equatable, Sendable {
    /// What is wrong with the markup, in the words used for every damaged
    /// file (`PackageSAXParser.problem(forCode:)`).
    var problem: String
    /// The line of the fault.
    var line: Int
    /// The column of the fault.
    var column: Int
    /// How many items the strict reading had read before the fault.
    var itemsBeforeFault: Int

    /// The fault as a log line describes it.
    var description: String {
        "\(problem) (line \(line), column \(column)), after \(itemsBeforeFault) item(s)"
    }
}

/// Why a document could not be read as a feed.
enum FeedParseError: Error, Equatable, Sendable {
    /// The document is empty, or holds only whitespace.
    case empty
    /// The document is larger than TextMouth reads (`FeedParser.maximumBytes`).
    case tooLarge
    /// The document is not RSS or Atom, such as a web page.
    case notAFeed
    /// The document could not be read even after repairing its markup: the
    /// first fault the strict reading found, at its line and column.
    case damaged(problem: String, line: Int, column: Int)
}

// MARK: - Namespaces

/// The namespaces a feed's elements belong to (FR03). Elements are matched by
/// namespace and local name, so any prefix works; a feed that uses a
/// conventional prefix without declaring it is read as if it had.
enum FeedNamespace {
    /// RSS 2.0's elements, which have no namespace.
    static let none = ""
    /// Atom (RFC 4287).
    static let atom = "http://www.w3.org/2005/Atom"
    /// Atom 0.3, which some old feeds still use.
    static let atom03 = "http://purl.org/atom/ns#"
    /// Apple Podcasts' elements.
    static let itunes = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    /// RSS's content module, for `content:encoded`.
    static let content = "http://purl.org/rss/1.0/modules/content/"
    /// Dublin Core, for `dc:creator` and `dc:date`.
    static let dublinCore = "http://purl.org/dc/elements/1.1/"
    /// Podcasting 2.0's elements.
    static let podcast = "https://podcastindex.org/namespace/1.0"
    /// Media RSS, for `media:content`.
    static let media = "http://search.yahoo.com/mrss/"
    /// RSS 1.0's elements.
    static let rss1 = "http://purl.org/rss/1.0/"
    /// RDF, whose root element holds an RSS 1.0 feed.
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    /// XHTML, which an Atom text construct of type xhtml holds.
    static let xhtml = "http://www.w3.org/1999/xhtml"

    /// The namespaces feeds conventionally bind each prefix to.
    static let conventionalPrefixes: [String: String] = [
        "itunes": itunes, "content": content, "dc": dublinCore, "atom": atom,
        "podcast": podcast, "media": media, "rdf": rdf,
    ]

    /// The namespace an element or attribute belongs to: `uri` as the
    /// document declares it, in its usual spelling, or, when the document
    /// declares none, the namespace its prefix conventionally names.
    static func resolve(uri: String?, qualifiedName: String?) -> String {
        if let uri, !uri.isEmpty {
            return canonical(uri)
        }
        guard let qualifiedName, let colon = qualifiedName.firstIndex(of: ":") else { return none }
        return conventionalPrefixes[String(qualifiedName[..<colon]).lowercased()] ?? none
    }

    /// The usual spelling of `uri`: Apple's namespace in any letter case,
    /// and Podcasting 2.0's earlier address, read as the ones above.
    static func canonical(_ uri: String) -> String {
        let lower = uri.lowercased()
        if lower == itunes.lowercased() { return itunes }
        if lower.hasPrefix("https://github.com/podcastindex-org/podcast-namespace") { return podcast }
        return uri
    }
}

// MARK: - Parsing

/// Reads RSS 2.0, RSS 1.0, and Atom feeds, with Apple's iTunes and
/// Podcasting 2.0 elements, and JSON Feed (FR03).
///
/// A document whose first character is "{" is JSON, read by
/// `JSONFeedParser` into the same kind of feed. Any other is XML.
///
/// An XML document is read first by `XMLParser`, streaming, with namespaces on
/// and external entities never resolved. Real feeds are often not
/// well-formed (an HTML entity such as `&nbsp;`, a bare ampersand, a blank
/// line before the XML declaration, a control character, a Latin-1 byte in
/// a feed declared UTF-8, a file cut short), and `XMLParser` stops at the
/// first such fault. The document is then read again from `XMLDocument`'s
/// tidy mode, which the research found reads every one of them, with
/// external entities never loaded (by default it loads local files named in
/// a DOCTYPE): its tree is walked into the same reader, so both readings
/// make the same feed. The repair is reported (`ParsedFeed.repair`), for the
/// log.
///
/// A document is read whole only up to `maximumBytes`, and its first
/// `maximumItems` items. Parsing never runs on the main thread: a large
/// feed's tidy reading takes about 100 ms.
enum FeedParser {
    /// The largest document TextMouth reads: 25 MB, ten times NPR's 2.2 MB
    /// feed of 355 episodes.
    static let maximumBytes = 25 * 1_024 * 1_024
    /// The most items TextMouth reads from one document.
    static let maximumItems = 2_000

    /// Reads `data` as a feed whose relative addresses are relative to
    /// `baseURL`, the address it was fetched from.
    /// - Throws: `FeedParseError`.
    static func parse(_ data: Data, baseURL: URL?, maximumItems: Int = maximumItems) throws -> ParsedFeed {
        guard data.count <= maximumBytes else { throw FeedParseError.tooLarge }
        guard data.contains(where: { !isXMLWhitespace($0) }) else { throw FeedParseError.empty }
        if JSONFeedParser.looksLikeJSON(data) {
            return try JSONFeedParser.parse(data, baseURL: baseURL, maximumItems: maximumItems)
        }

        // A tag with more attributes than a parser can take in reasonable time,
        // and an encoding the guard cannot see through, are faults
        // (`XMLInputGuard`): a hostile feed from any address costs minutes a
        // refresh otherwise. Entities of the feed's own are not asked about:
        // old feeds declare some, and are read.
        if let problem = XMLInputGuard.problemLeavingDefinitions(with: data) {
            throw FeedParseError.damaged(problem: XMLInputGuard.reason(for: problem), line: 1, column: 1)
        }
        let strict = StrictFeedReading(data: data, reader: FeedDocumentReader(baseURL: baseURL, itemLimit: maximumItems))
        switch strict.read() {
        case .feed(let feed):
            return feed
        case .notAFeed:
            throw FeedParseError.notAFeed
        case .fault(let code, let line, let column, let itemsRead):
            let problem = PackageSAXParser.problem(forCode: code)
            let tidy = FeedDocumentReader(baseURL: baseURL, itemLimit: maximumItems)
            let document: XMLDocument
            do {
                document = try XMLDocument(data: data, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
            } catch {
                throw FeedParseError.damaged(problem: problem, line: line, column: column)
            }
            guard let root = document.rootElement() else {
                throw FeedParseError.damaged(problem: problem, line: line, column: column)
            }
            TidyFeedWalk.walk(root, into: tidy)
            guard var feed = tidy.result() else {
                // A web page tidied into a tree is no feed either.
                if tidy.sawRoot { throw FeedParseError.notAFeed }
                throw FeedParseError.damaged(problem: problem, line: line, column: column)
            }
            feed.repair = FeedParseRepair(problem: problem, line: line, column: column, itemsBeforeFault: itemsRead)
            return feed
        }
    }

    /// The four whitespace bytes XML allows between markup.
    private static func isXMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - The Strict Reading

/// One strict reading of a document by `XMLParser`, delivering its events to
/// a `FeedDocumentReader`.
private final class StrictFeedReading: NSObject, XMLParserDelegate {
    /// How the strict reading ended.
    enum Outcome {
        /// The document is a feed, read whole (or to the item limit).
        case feed(ParsedFeed)
        /// The document is well-formed enough to show it is no feed.
        case notAFeed
        /// The document has a fault at `line` and `column`, after `itemsRead`
        /// items; `code` is `XMLParser`'s error code.
        case fault(code: Int, line: Int, column: Int, itemsRead: Int)
    }

    /// The document.
    private let data: Data
    /// What makes the feed of the events.
    private let reader: FeedDocumentReader
    /// The first fault the parser reported.
    private var firstFault: (code: Int, line: Int, column: Int)?
    /// Whether the reader asked to stop: at the item limit, or at a root
    /// that is no feed's.
    private var stoppedByReader = false

    /// A reading of `data` into `reader`.
    init(data: Data, reader: FeedDocumentReader) {
        self.data = data
        self.reader = reader
    }

    /// Reads the document.
    func read() -> Outcome {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        // Never load an external entity: a feed's DOCTYPE could name a file
        // on this Mac, and a network fetch would stall the reading.
        parser.shouldResolveExternalEntities = false
        let finished = parser.parse()

        if !stoppedByReader, !finished || firstFault != nil {
            let fault = firstFault ?? (
                (parser.parserError as NSError?)?.code ?? XMLParser.ErrorCode.internalError.rawValue,
                parser.lineNumber,
                parser.columnNumber
            )
            return .fault(code: fault.code, line: fault.line, column: fault.column, itemsRead: reader.itemCount)
        }
        guard let feed = reader.result() else { return .notAFeed }
        return .feed(feed)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = FeedDocumentReader.Name(uri: namespaceURI, qualifiedName: qName, local: elementName)
        if !reader.start(name, attributes: attributeDict) {
            stoppedByReader = true
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        reader.characters(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        reader.characters(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        reader.end(FeedDocumentReader.Name(uri: namespaceURI, qualifiedName: qName, local: elementName))
    }

    /// Keeps the first fault, which names the damage itself; anything after
    /// it describes only the parser stopping.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard firstFault == nil, !stoppedByReader else { return }
        firstFault = ((parseError as NSError).code, parser.lineNumber, parser.columnNumber)
    }
}

// MARK: - The Tidy Reading

/// Walks a tree `XMLDocument` tidied into a `FeedDocumentReader`, as the
/// events `XMLParser` would have delivered, depth first and without
/// recursion, so a deeply nested document cannot exhaust the stack.
private enum TidyFeedWalk {
    /// Walks `root` and everything inside it.
    static func walk(_ root: XMLElement, into reader: FeedDocumentReader) {
        /// An element open in the walk, and the next of its children to visit.
        struct Frame {
            let element: XMLElement
            let name: FeedDocumentReader.Name
            var nextChild: Int
        }
        guard let rootName = start(root, in: reader) else { return }
        var frames = [Frame(element: root, name: rootName, nextChild: 0)]
        while let last = frames.last {
            let children = last.element.children ?? []
            guard last.nextChild < children.count else {
                reader.end(last.name)
                frames.removeLast()
                continue
            }
            frames[frames.count - 1].nextChild += 1
            let child = children[last.nextChild]
            switch child.kind {
            case .element:
                guard let element = child as? XMLElement else { continue }
                guard let name = start(element, in: reader) else { return }
                frames.append(Frame(element: element, name: name, nextChild: 0))
            case .text:
                reader.characters(child.stringValue ?? "")
            default:
                // Comments and processing instructions are never read.
                continue
            }
        }
    }

    /// Tells `reader` that `element` starts, and returns its name, or nil
    /// when the reader asks to stop.
    private static func start(_ element: XMLElement, in reader: FeedDocumentReader) -> FeedDocumentReader.Name? {
        let name = FeedDocumentReader.Name(
            uri: element.uri,
            qualifiedName: element.name,
            local: element.localName ?? element.name ?? ""
        )
        var attributes: [String: String] = [:]
        for attribute in element.attributes ?? [] {
            guard let key = attribute.localName ?? attribute.name, attributes[key] == nil else { continue }
            attributes[key] = attribute.stringValue ?? ""
        }
        return reader.start(name, attributes: attributes) ? name : nil
    }
}

// MARK: - The Reader

/// Makes a feed of a document's elements, whichever reading reports them
/// (FR03): the strict `XMLParser` or the walk of the tidied tree.
///
/// Elements are matched by namespace and local name, and fields by where
/// they sit: a `title` counts as the feed's only directly inside its channel
/// (an `image` has one too), and as an item's only directly inside it.
/// Descriptions and content are kept as markup: text exactly as the
/// document holds it once its own escaping is undone, and any element a
/// publisher left unescaped inside written back as a tag, so a description
/// whose HTML is not escaped still reads as HTML.
final class FeedDocumentReader {
    /// An element's name: its namespace and its local name.
    struct Name: Equatable {
        let namespace: String
        let local: String

        /// The name a reading reports: `local` (which may still carry an
        /// undeclared prefix, as "itunes:duration") in the namespace `uri`,
        /// or, when the document declares none, in the namespace the
        /// prefix of `qualifiedName` conventionally names.
        init(uri: String?, qualifiedName: String?, local: String) {
            namespace = FeedNamespace.resolve(uri: uri, qualifiedName: qualifiedName ?? local)
            self.local = local.split(separator: ":").last.map(String.init) ?? local
        }
    }

    /// Where relative addresses are resolved from.
    private let baseURL: URL?
    /// The most items read.
    private let itemLimit: Int

    // MARK: State

    /// The document's format, once its root is seen.
    private var format: ParsedFeed.Format?
    /// The namespace of the format's own elements: the root's for RSS 2.0
    /// and Atom, RSS 1.0's for an RDF document.
    private var coreNamespace = FeedNamespace.none
    /// Whether the root element has been seen.
    private(set) var sawRoot = false

    /// The elements open now, outermost first.
    private var stack: [Name] = []
    /// The text of the element being read.
    private var text = ""
    /// The markup being captured for a description, summary, or content.
    private var capture: MarkupCapture?

    /// The feed's own fields.
    private var feedFields = FeedFields()
    /// The items read so far.
    private var items: [ParsedItem] = []
    /// Whether an item past the limit was found.
    private var reachedItemLimit = false
    /// The item being read, and how deep in the document it opened.
    private var item: (fields: ItemFields, depth: Int)?

    /// A reader resolving addresses from `baseURL`, reading at most
    /// `itemLimit` items.
    init(baseURL: URL?, itemLimit: Int) {
        self.baseURL = baseURL
        self.itemLimit = itemLimit
    }

    /// How many items have been read.
    var itemCount: Int { items.count }

    /// The feed read, or nil when the document's root is no feed's.
    func result() -> ParsedFeed? {
        guard let format else { return nil }
        return ParsedFeed(
            format: format,
            title: feedFields.title.map { FeedTextConverter.plainLine($0.text, isHTML: $0.kind == .html) } ?? "",
            siteLink: feedFields.siteLink,
            summary: feedFields.summary ?? feedFields.itunesSummary,
            author: feedFields.itunesAuthor ?? feedFields.dublinCoreCreator ?? feedFields.atomAuthors.joinedNames,
            isSerial: feedFields.isSerial,
            newFeedURL: feedFields.newFeedURL,
            items: items,
            repair: nil,
            reachedItemLimit: reachedItemLimit
        )
    }

    // MARK: Events

    /// An element starts. Returns false to stop reading: at a root that is
    /// no feed's, or at an item past the limit.
    func start(_ name: Name, attributes: [String: String]) -> Bool {
        if var open = capture {
            open.openTag(name.local, attributes: attributes)
            capture = open
            stack.append(name)
            return true
        }
        guard sawRoot else { return startRoot(name) }
        let parent = stack.last
        stack.append(name)
        text = ""

        if isItemElement(name), item == nil {
            guard items.count < itemLimit else {
                reachedItemLimit = true
                return false
            }
            item = (ItemFields(position: items.count), stack.count)
            return true
        }
        if let open = item {
            // Only the item's own children, and an Atom author's name, count.
            if stack.count == open.depth + 1 {
                startItemChild(name, attributes: attributes)
            }
        } else if let parent, isFeedLevel(parent) {
            startFeedChild(name, attributes: attributes)
        }
        return true
    }

    /// Text inside the element being read.
    func characters(_ string: String) {
        if capture != nil {
            capture?.append(string)
        } else {
            text += string
        }
    }

    /// An element ends.
    func end(_ name: Name) {
        if let open = capture {
            if stack.count > open.depth {
                capture?.closeTag(name.local)
                stack.removeLast()
                return
            }
            capture = nil
            finish(open)
            stack.removeLast()
            return
        }
        let value = text
        text = ""
        let depth = stack.count
        stack.removeLast()

        if let open = item {
            if depth == open.depth {
                if let built = open.fields.build(baseURL: baseURL) {
                    items.append(built)
                }
                item = nil
            } else if depth == open.depth + 1 {
                endItemChild(name, text: value)
            } else if depth == open.depth + 2, name.local == "name", isAtom, stack.last?.local == "author" {
                item?.fields.atomAuthors.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else if let parent = stack.last, isFeedLevel(parent) {
            endFeedChild(name, text: value)
        } else if name.local == "name", isAtom, stack.count >= 2, stack.last?.local == "author",
                  isFeedLevel(stack[stack.count - 2]) {
            feedFields.atomAuthors.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: The Root

    /// Decides the format from the root element, or stops at one that is no
    /// feed's, such as a web page's.
    private func startRoot(_ name: Name) -> Bool {
        sawRoot = true
        stack.append(name)
        switch (name.namespace, name.local) {
        case (_, "rss"):
            format = .rss
            coreNamespace = name.namespace
        case (FeedNamespace.rdf, "RDF"):
            format = .rdf
            coreNamespace = FeedNamespace.rss1
        case (FeedNamespace.atom, "feed"), (FeedNamespace.atom03, "feed"):
            format = .atom
            coreNamespace = name.namespace
        default:
            return false
        }
        return true
    }

    /// Whether the format is Atom.
    private var isAtom: Bool { format == .atom }

    /// Whether `name` is the format's item: an RSS item, or an Atom entry.
    private func isItemElement(_ name: Name) -> Bool {
        name.namespace == coreNamespace && name.local == (isAtom ? "entry" : "item")
    }

    /// Whether `name` is where the feed's own fields sit: an RSS channel, or
    /// an Atom feed.
    private func isFeedLevel(_ name: Name) -> Bool {
        name.namespace == coreNamespace && name.local == (isAtom ? "feed" : "channel")
    }

    // MARK: Items

    /// An item's child starts: attributes are read here, and markup capture
    /// begins.
    private func startItemChild(_ name: Name, attributes: [String: String]) {
        switch (name.namespace, name.local) {
        case (coreNamespace, "enclosure") where !isAtom:
            if let enclosure = enclosure(url: attributes["url"], type: attributes["type"], length: attributes["length"]) {
                item?.fields.enclosures.append(enclosure)
            }
        case (coreNamespace, "guid") where !isAtom:
            item?.fields.guidIsPermaLink = attributes["isPermaLink"]?.lowercased() != "false"
        case (coreNamespace, "description") where !isAtom:
            beginCapture(.itemSummary, kind: .unknown)
        case (FeedNamespace.content, "encoded"):
            beginCapture(.itemContent, kind: .unknown)
        case (FeedNamespace.itunes, "summary"):
            beginCapture(.itemITunesSummary, kind: .unknown)
        case (FeedNamespace.media, "content"):
            if let enclosure = enclosure(url: attributes["url"], type: attributes["type"], length: attributes["fileSize"]) {
                item?.fields.mediaContents.append(enclosure)
            }
        case (FeedNamespace.podcast, "transcript"):
            if let url = webAddress(attributes["url"]) {
                item?.fields.transcripts.append(FeedResource(url: url, mimeType: attributes["type"]))
            }
        case (FeedNamespace.podcast, "chapters"):
            if let url = webAddress(attributes["url"]) {
                // The first chapters file an item names counts.
                if item?.fields.chapters == nil {
                    item?.fields.chapters = FeedResource(url: url, mimeType: attributes["type"])
                }
            }
        case (coreNamespace, "link") where isAtom:
            startAtomLink(attributes, atFeedLevel: false)
        case (coreNamespace, "title"):
            // An RSS title's markup, which only a careless publisher leaves
            // unescaped, is written back and removed like an Atom title's.
            beginCapture(.itemTitle, kind: isAtom ? Self.atomTextKind(attributes["type"]) : .unknown)
        case (coreNamespace, "summary") where isAtom:
            beginCapture(.itemSummary, kind: Self.atomTextKind(attributes["type"]))
        case (coreNamespace, "content") where isAtom:
            // Content that only points elsewhere (src) holds nothing to read.
            if attributes["src"] == nil {
                beginCapture(.itemContent, kind: Self.atomTextKind(attributes["type"]))
            }
        default:
            break
        }
    }

    /// An item's child ends, with its text.
    private func endItemChild(_ name: Name, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch (name.namespace, name.local) {
        case (coreNamespace, "link") where !isAtom:
            if item?.fields.link == nil {
                let page = address(trimmed)
                item?.fields.link = page
            }
        case (coreNamespace, "guid") where !isAtom, (coreNamespace, "id") where isAtom:
            item?.fields.guid = trimmed
        case (coreNamespace, "pubDate") where !isAtom:
            item?.fields.pubDate = FeedDates.date(from: trimmed)
        case (coreNamespace, "author") where !isAtom:
            item?.fields.rssAuthor = trimmed
        case (coreNamespace, "published") where isAtom, (coreNamespace, "issued") where isAtom:
            item?.fields.atomPublished = FeedDates.date(from: trimmed)
        case (coreNamespace, "updated") where isAtom, (coreNamespace, "modified") where isAtom:
            item?.fields.atomUpdated = FeedDates.date(from: trimmed)
        case (FeedNamespace.dublinCore, "creator"):
            item?.fields.dublinCoreCreator = trimmed
        case (FeedNamespace.dublinCore, "date"):
            item?.fields.dublinCoreDate = FeedDates.date(from: trimmed)
        case (FeedNamespace.itunes, "duration"):
            item?.fields.duration = FeedDates.duration(from: trimmed)
        case (FeedNamespace.itunes, "episode"):
            item?.fields.episodeNumber = Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
        case (FeedNamespace.itunes, "title"):
            item?.fields.itunesTitle = trimmed
        case (FeedNamespace.itunes, "author"):
            item?.fields.itunesAuthor = trimmed
        default:
            break
        }
    }

    // MARK: The Feed's Own Fields

    /// A child of the channel or the Atom feed starts.
    private func startFeedChild(_ name: Name, attributes: [String: String]) {
        switch (name.namespace, name.local) {
        case (coreNamespace, "description") where !isAtom:
            beginCapture(.feedSummary, kind: .unknown)
        case (FeedNamespace.itunes, "summary"):
            beginCapture(.feedITunesSummary, kind: .unknown)
        case (coreNamespace, "title"):
            beginCapture(.feedTitle, kind: isAtom ? Self.atomTextKind(attributes["type"]) : .unknown)
        case (coreNamespace, "subtitle") where isAtom, (coreNamespace, "tagline") where isAtom:
            beginCapture(.feedSummary, kind: Self.atomTextKind(attributes["type"]))
        case (coreNamespace, "link") where isAtom:
            startAtomLink(attributes, atFeedLevel: true)
        case (FeedNamespace.atom, "link") where !isAtom:
            // An RSS feed's atom:link names its own address (rel="self") or
            // its site; only the site is kept, when the channel names none.
            if attributes["rel"]?.lowercased() == "alternate", feedFields.siteLink == nil {
                feedFields.siteLink = webAddress(attributes["href"])
            }
        default:
            break
        }
    }

    /// A child of the channel or the Atom feed ends, with its text.
    private func endFeedChild(_ name: Name, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch (name.namespace, name.local) {
        case (coreNamespace, "link") where !isAtom:
            feedFields.siteLink = address(trimmed) ?? feedFields.siteLink
        case (FeedNamespace.itunes, "author"):
            feedFields.itunesAuthor = trimmed
        case (FeedNamespace.dublinCore, "creator"):
            feedFields.dublinCoreCreator = trimmed
        case (FeedNamespace.itunes, "type"):
            feedFields.isSerial = trimmed.lowercased() == "serial"
        case (FeedNamespace.itunes, "new-feed-url"):
            feedFields.newFeedURL = webAddress(trimmed)
        default:
            break
        }
    }

    /// An Atom link, by its relation: the alternate (or unmarked) one is the
    /// page, an enclosure is the file offered.
    private func startAtomLink(_ attributes: [String: String], atFeedLevel: Bool) {
        let relation = attributes["rel"]?.lowercased() ?? "alternate"
        switch relation {
        case "alternate":
            guard let page = address(attributes["href"]) else { return }
            if atFeedLevel {
                feedFields.siteLink = feedFields.siteLink ?? page
            } else if item?.fields.link == nil {
                item?.fields.link = page
            }
        case "enclosure" where !atFeedLevel:
            if let enclosure = enclosure(url: attributes["href"], type: attributes["type"], length: attributes["length"]) {
                item?.fields.enclosures.append(enclosure)
            }
        default:
            break
        }
    }

    // MARK: Markup Capture

    /// Starts capturing the markup of the element just opened, for `target`.
    private func beginCapture(_ target: CaptureTarget, kind: FeedTextSource.Kind) {
        capture = MarkupCapture(target: target, kind: kind, depth: stack.count)
    }

    /// Hands a finished capture to the field it was for.
    private func finish(_ capture: MarkupCapture) {
        let source = capture.source
        guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch capture.target {
        case .itemTitle:
            if item?.fields.title == nil {
                let title = FeedTextConverter.plainLine(source.text, isHTML: source.kind == .html)
                item?.fields.title = title
            }
        case .itemSummary:
            if item?.fields.summary == nil {
                item?.fields.summary = source
            }
        case .itemITunesSummary:
            item?.fields.itunesSummary = source
        case .itemContent:
            if item?.fields.content == nil {
                item?.fields.content = source
            }
        case .feedTitle:
            feedFields.title = feedFields.title ?? source
        case .feedSummary:
            feedFields.summary = feedFields.summary ?? source
        case .feedITunesSummary:
            feedFields.itunesSummary = source
        }
    }

    /// The kind of an Atom text construct of the type `type`: "text" (the
    /// default), "html", or "xhtml", or a MIME type for content.
    private static func atomTextKind(_ type: String?) -> FeedTextSource.Kind {
        let lower = type?.lowercased() ?? "text"
        if lower.contains("html") { return .html }
        return lower == "text" || lower.hasPrefix("text/plain") ? .plain : .unknown
    }

    // MARK: Addresses

    /// The address `text` gives, resolved from the document's own address
    /// when relative; nil for none.
    private func address(_ text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed, relativeTo: baseURL)
            ?? URL(string: trimmed.replacingOccurrences(of: " ", with: "%20"), relativeTo: baseURL)
        return url?.absoluteURL
    }

    /// The http or https address `text` gives, or nil for any other: a file
    /// a feed names is never loaded.
    private func webAddress(_ text: String?) -> URL? {
        address(text).flatMap { FeedTransport.isWebAddress($0) ? $0 : nil }
    }

    /// An enclosure at an http or https address, with its type and its
    /// length when that is a positive number of bytes.
    private func enclosure(url: String?, type: String?, length: String?) -> FeedEnclosure? {
        guard let address = webAddress(url) else { return nil }
        let bytes = length.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 0 ? $0 : nil }
        let mimeType = type?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedEnclosure(url: address, mimeType: mimeType?.isEmpty == false ? mimeType : nil, length: bytes)
    }
}

// MARK: - Fields Being Read

/// What a capture of markup is for.
private enum CaptureTarget {
    case itemTitle, itemSummary, itemITunesSummary, itemContent
    case feedTitle, feedSummary, feedITunesSummary
}

/// The markup of one description, summary, or content, as it is read.
///
/// Text is kept as the document holds it once its own escaping is undone:
/// for an RSS description that is the HTML the publisher escaped, and for an
/// Atom text construct of type text, plain text. An element inside, which
/// only a publisher who left HTML unescaped (or Atom's xhtml) puts there, is
/// written back as a tag with its attributes; the text inside xhtml is text,
/// so it is escaped as it is written.
private struct MarkupCapture {
    /// The field the markup is for.
    let target: CaptureTarget
    /// What kind of text it is.
    let kind: FeedTextSource.Kind
    /// How deep in the document the captured element sits.
    let depth: Int
    /// The markup so far.
    private var markup = ""
    /// Whether an element has been written back, which makes it HTML.
    private var wroteTags = false

    /// A capture of the element at `depth`, for `target`.
    init(target: CaptureTarget, kind: FeedTextSource.Kind, depth: Int) {
        self.target = target
        self.kind = kind
        self.depth = depth
    }

    /// The text captured.
    var source: FeedTextSource {
        FeedTextSource(text: markup, kind: wroteTags ? .html : kind)
    }

    /// Text inside the captured element: escaped once tags have been written
    /// back, since text between tags is text; otherwise kept as markup.
    mutating func append(_ string: String) {
        markup += wroteTags ? FeedTextConverter.escaped(string) : string
    }

    /// An element inside starts: written back as a tag.
    mutating func openTag(_ name: String, attributes: [String: String]) {
        wroteTags = true
        markup += "<" + name
        for (key, value) in attributes.sortedStably(by: { $0.key < $1.key }) {
            markup += " \(key)=\"\(FeedTextConverter.escaped(value))\""
        }
        markup += ">"
    }

    /// An element inside ends.
    mutating func closeTag(_ name: String) {
        markup += "</\(name)>"
    }
}

/// The feed's own fields as they are read.
private struct FeedFields {
    var title: FeedTextSource?
    var siteLink: URL?
    var summary: FeedTextSource?
    var itunesSummary: FeedTextSource?
    var itunesAuthor: String?
    var dublinCoreCreator: String?
    var atomAuthors: [String] = []
    var isSerial = false
    var newFeedURL: URL?
}

/// One item's fields as they are read, from every element that can give
/// each, chosen between when the item ends.
private struct ItemFields {
    /// Where the item is in the document.
    let position: Int
    var title: String?
    var itunesTitle: String?
    var link: URL?
    var guid: String?
    var guidIsPermaLink = true
    var summary: FeedTextSource?
    var itunesSummary: FeedTextSource?
    var content: FeedTextSource?
    var pubDate: Date?
    var dublinCoreDate: Date?
    var atomPublished: Date?
    var atomUpdated: Date?
    var enclosures: [FeedEnclosure] = []
    var mediaContents: [FeedEnclosure] = []
    var duration: TimeInterval?
    var episodeNumber: Int?
    var dublinCoreCreator: String?
    var itunesAuthor: String?
    var rssAuthor: String?
    var atomAuthors: [String] = []
    var transcripts: [FeedResource] = []
    var chapters: FeedResource?

    /// A position-only item.
    init(position: Int) {
        self.position = position
    }

    /// The item these fields make, or nil when they give nothing to list.
    ///
    /// - The enclosure is chosen among the item's enclosures and then its
    ///   Media RSS contents (`FeedEnclosure.preferred(among:otherwise:)`),
    ///   else it is its first enclosure of any kind.
    /// - The page is the link, or a permalink guid that is an address.
    /// - The title is the title, `itunes:title`, or the start of the summary.
    /// - The date is the publication date, from the first element that gives
    ///   one that reads.
    /// - The content is kept only when it differs from the summary.
    func build(baseURL: URL?) -> ParsedItem? {
        let enclosure = FeedEnclosure.preferred(among: enclosures + mediaContents, otherwise: enclosures.first)
        var page = link
        if page == nil, guidIsPermaLink, let guid, let address = URL(string: guid, relativeTo: baseURL)?.absoluteURL,
           FeedTransport.isWebAddress(address) {
            page = address
        }
        let summaryText = summary ?? itunesSummary
        // The title was read as one line already; `itunes:title` is read now.
        var resolvedTitle = title ?? itunesTitle.map { FeedTextConverter.plainLine($0) } ?? ""
        if resolvedTitle.isEmpty, let summaryText {
            resolvedTitle = ParsedItem.standInTitle(from: summaryText.text, isHTML: true)
        }
        guard !resolvedTitle.isEmpty || guid != nil || enclosure != nil || page != nil else { return nil }
        let content = self.content.flatMap { ParsedItem.isRepeating($0, summaryText) ? nil : $0 }
        return ParsedItem(
            guid: guid,
            title: resolvedTitle,
            link: page,
            summary: summaryText,
            content: content,
            published: pubDate ?? dublinCoreDate ?? atomPublished ?? atomUpdated,
            enclosure: enclosure,
            duration: duration,
            author: dublinCoreCreator ?? itunesAuthor ?? atomAuthors.joinedNames ?? rssAuthor.map(Self.authorName),
            episodeNumber: episodeNumber,
            transcripts: transcripts,
            chapters: chapters,
            position: position
        )
    }

    /// The name in an RSS author, which RSS writes as an address and a name
    /// in parentheses ("lawyer@example.com (Pat Doe)"), or the whole value
    /// when it has no parentheses.
    private static func authorName(_ author: String) -> String {
        guard let open = author.firstIndex(of: "("), let close = author.lastIndex(of: ")"), open < close else {
            return author
        }
        let name = author[author.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? author : name
    }
}

extension Array where Element == String {
    /// The non-empty names, joined by commas, or nil when there are none: a
    /// feed's or an item's authors, whichever format lists them.
    var joinedNames: String? {
        let names = filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
