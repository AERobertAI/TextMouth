import XCTest
@testable import TextMouth

/// The nested contents list that the HTML page and the EPUB's navigation
/// document share (`ExportContentsList`): every item holds at most one list
/// (EPUB 3.3, section 7.3), every entry is there once in reading order, and
/// the list nests as the levels do when they skip or rise (B2, S1).
///
/// These tests read the lines as XML and count, so a shape that makes two
/// lists in one item fails whatever the lines look like.
final class ExportContentsListTests: XCTestCase {

    // MARK: - Helpers

    /// Entries of `levels`, titled "H1", "H2", and so on.
    private func entries(_ levels: [Int]) -> [ExportContentsEntry] {
        levels.enumerated().map { ExportContentsEntry(level: $1, title: "H\($0 + 1)", address: "#h\($0 + 1)") }
    }

    /// The structure of `lines` read as XML.
    private func structure(of lines: [String], file: StaticString = #filePath, line: UInt = #line) -> ContentsStructure {
        ContentsStructure.read(Data(("<nav>" + lines.joined(separator: "\n") + "</nav>").utf8), file: file, line: line)
    }

    // MARK: - The Shapes

    /// The shapes the review found: a heading that rises out of a skipped
    /// level, a first heading deeper than the rest, and the shapes of a
    /// Word or PDF book. Each entry is there once in order, no item holds two
    /// lists, and the depths are the nesting a reader expects.
    func testSkippedAndRisingLevelsNestWithOneListToAnItem() {
        let shapes: [(levels: [Int], depths: [Int])] = [
            ([1, 3, 2], [1, 2, 2]),
            ([1, 2, 4, 3], [1, 2, 3, 3]),
            ([1, 6, 3, 5, 2], [1, 2, 2, 3, 2]),
            ([3, 1, 2, 1, 2], [1, 1, 2, 1, 2]),
            ([2, 1], [1, 1]),
            ([1, 2, 3, 2, 1], [1, 2, 3, 2, 1]),
            ([1, 1, 1], [1, 1, 1]),
            ([4, 2, 3, 1, 5], [1, 1, 2, 1, 2]),
        ]
        for shape in shapes {
            let found = structure(of: ExportContentsList.lines(of: entries(shape.levels)))
            XCTAssertEqual(found.titles, shape.levels.indices.map { "H\($0 + 1)" }, "\(shape.levels)")
            XCTAssertEqual(found.depths, shape.depths, "\(shape.levels)")
            XCTAssertLessThanOrEqual(found.mostListsInAnItem, 1, "\(shape.levels) makes two lists in one item")
        }
    }

    /// No entries, no list.
    func testNoEntriesMakeNoList() {
        XCTAssertEqual(ExportContentsList.lines(of: []), [])
    }

    /// Any sequence of levels, made by a fixed seed: every entry once and in
    /// order, the first at depth 1, no depth more than one below the entry
    /// before it, no item with two lists, and the XML well-formed.
    func testAnySequenceOfLevelsMakesAValidNesting() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for round in 0..<300 {
            let levels = (0..<(1 + next(14))).map { _ in 1 + next(6) }
            let found = structure(of: ExportContentsList.lines(of: entries(levels)))
            XCTAssertEqual(found.titles.count, levels.count, "round \(round): \(levels)")
            XCTAssertEqual(found.titles, levels.indices.map { "H\($0 + 1)" }, "round \(round): \(levels)")
            XCTAssertEqual(found.depths.first, 1, "round \(round): \(levels)")
            for (before, after) in zip(found.depths, found.depths.dropFirst()) {
                XCTAssertLessThanOrEqual(after, before + 1, "round \(round): \(levels) jumps down two lists")
            }
            XCTAssertLessThanOrEqual(found.mostListsInAnItem, 1, "round \(round): \(levels)")
        }
    }

    /// Entries that deepen by more than one are one list deeper, not two.
    func testASkippedLevelOpensOneListOnly() {
        let found = structure(of: ExportContentsList.lines(of: entries([1, 5])))
        XCTAssertEqual(found.depths, [1, 2])
    }

    /// A title with markup characters is escaped in the list.
    func testTitlesAreEscaped() {
        let lines = ExportContentsList.lines(of: [ExportContentsEntry(level: 1, title: "A & <B>", address: "x.xhtml#a\"b")])
        XCTAssertEqual(lines, ["<ol>", "<li><a href=\"x.xhtml#a&quot;b\">A &amp; &lt;B&gt;</a></li>", "</ol>"])
    }
}

// MARK: - Reading a Contents List as XML

/// What a contents list holds, found by an XML parser: its links' words in
/// order, the depth of lists each link is inside, and the most lists any one
/// item holds.
struct ContentsStructure {
    /// The words of each link, in order.
    var titles: [String] = []
    /// The depth of `ol` elements each link is inside.
    var depths: [Int] = []
    /// The most `ol` elements any one `li` holds directly.
    var mostListsInAnItem = 0

    /// The structure of the XML in `data`; a document that is not well-formed
    /// fails the test.
    static func read(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> ContentsStructure {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
        return reader.structure
    }

    /// Collects the structure as the parser walks the document.
    private final class Reader: NSObject, XMLParserDelegate {
        var structure = ContentsStructure()
        private var listDepth = 0
        /// For each open `li`, how many lists it holds so far.
        private var listsInItems: [Int] = []
        /// Whether the open elements, from the outermost, include each `li`'s parent
        /// being a list (to count a list only in its item).
        private var current: (depth: Int, text: String)?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "ol":
                listDepth += 1
                if !listsInItems.isEmpty {
                    listsInItems[listsInItems.count - 1] += 1
                    structure.mostListsInAnItem = max(structure.mostListsInAnItem, listsInItems[listsInItems.count - 1])
                }
            case "li":
                listsInItems.append(0)
            case "a":
                current = (listDepth, "")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "ol":
                listDepth -= 1
            case "li":
                if !listsInItems.isEmpty { listsInItems.removeLast() }
            case "a":
                if let link = current {
                    structure.titles.append(link.text)
                    structure.depths.append(link.depth)
                }
                current = nil
            default:
                break
            }
        }
    }
}
