import Foundation

// MARK: - The Kinds of XML File

/// What a loose XML file is, by the element it begins with (FMT04, FMT13, FMT20).
enum XMLRootKind: Equatable, Sendable {
    /// A DTBook, DAISY 3's XML text: a `dtbook` root in any namespace or none.
    case dtbook
    /// A Word 2003 XML (WordML) document: a `wordDocument` root in Word's
    /// 2003 namespace.
    case wordML
    /// A PEF braille file (FMT20): a `pef` root in PEF 2008-1's namespace.
    case pef
    /// Any other XML file, a file that is not XML, an empty file, and a file
    /// that cannot be read.
    case other
}

// MARK: - The Sniffer

/// Names the kind of an XML file by its root element, never by its
/// extension alone. A loose .xml file may be a DTBook book (read by the
/// DAISY reader), a Word 2003 XML document (handed to textutil), a PEF
/// braille file (read by the braille reader), or any of
/// the countless other things that are XML (refused by name), and only the
/// element the file begins with tells which.
enum XMLDocumentSniffer {
    /// The most bytes read from the start of a file to find its root
    /// element. A real DTBook or WordML file names its root within its first
    /// few lines; a file whose prolog (comments, processing instructions,
    /// and a DOCTYPE) is longer than this is `.other`, which is the limit.
    static let scanLength = 65_536

    /// The namespace of Word 2003 XML's `wordDocument` element.
    private static let wordMLNamespace = "http://schemas.microsoft.com/office/word/2003/wordml"

    /// The namespace of PEF 2008-1's `pef` element (FMT20).
    private static let pefNamespace = "http://www.daisy.org/ns/2008/pef"

    /// The kind of the file at `url`, from its first `scanLength` bytes.
    /// A missing file, a folder, and a file that cannot be read are `.other`.
    static func rootKind(ofFileAt url: URL) -> XMLRootKind {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              !isFolder.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        // Reading only the start keeps a huge file from filling memory.
        guard let prefix = try? handle.read(upToCount: scanLength) else { return .other }
        return rootKind(of: prefix)
    }

    /// Whether the file at `url` holds no text at all: it has no bytes, or
    /// only white space (spaces, tabs, line breaks, and a leading UTF-8 byte
    /// order mark). An import tells such a file it has no text to read
    /// rather than that it is some other kind of XML. Only the first
    /// `scanLength` bytes are read, so a file longer than that is never
    /// called blank, and a missing file, a folder, and a file that cannot
    /// be read are not blank either.
    static func holdsNoText(fileAt url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              !isFolder.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // One byte more than the scan: a file that fills it is longer.
        // `read` answers nil, not empty data, at the end of an empty file; a
        // read that fails throws, and a file that cannot be read is not blank.
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: scanLength + 1) ?? Data()
        } catch {
            return false
        }
        guard bytes.count <= scanLength else { return false }
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = bytes.starts(with: byteOrderMark) ? bytes.dropFirst(byteOrderMark.count) : bytes[...]
        return body.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    /// The kind of an XML document that begins with `prefix`. The prefix may
    /// be cut off anywhere once its root element has started.
    static func rootKind(of prefix: Data) -> XMLRootKind {
        guard !prefix.isEmpty else { return .other }
        // Whatever the caller passes, only the first `scanLength` bytes count.
        let parser = XMLParser(data: prefix.prefix(scanLength))
        let finder = RootElementFinder()
        parser.delegate = finder
        parser.shouldProcessNamespaces = true
        // The DOCTYPE of a DTBook names its DTD by an http URL. Never fetch
        // it or any other external entity.
        parser.shouldResolveExternalEntities = false
        // The parse ends in an error, either the abort in the finder or the
        // cut that ends the prefix: once the root is known, the error is moot.
        _ = parser.parse()

        guard let root = finder.root else { return .other }
        if root.localName == "dtbook" { return .dtbook }
        if root.localName == "wordDocument" && root.namespaceURI == wordMLNamespace { return .wordML }
        if root.localName == "pef" && root.namespaceURI == pefNamespace { return .pef }
        return .other
    }

    /// The book format a loose .xml file at `url` imports as: `.daisy` for a
    /// DTBook, `.wordml` for a Word 2003 XML document, `.braille` for a
    /// PEF braille file, nil for every other kind.
    static func bookFormat(ofFileAt url: URL) -> BookFormat? {
        switch rootKind(ofFileAt: url) {
        case .dtbook: return .daisy
        case .wordML: return .wordml
        case .pef: return .braille
        case .other: return nil
        }
    }
}

// MARK: - Finding the Root

/// Records the first element a parse reaches and stops the parse there, so
/// the prolog is passed over and the rest of the document is never read.
private final class RootElementFinder: NSObject, XMLParserDelegate {
    /// The first element's local name and namespace URI, once it is found.
    private(set) var root: (localName: String, namespaceURI: String)?

    /// Note the root element and abort: nothing after it matters.
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        root = (elementName, namespaceURI ?? "")
        parser.abortParsing()
    }
}
