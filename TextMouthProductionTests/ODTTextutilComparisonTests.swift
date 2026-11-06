import XCTest
@testable import TextMouth

/// TextMouth's own OpenDocument reader against textutil's reading of the
/// same files (FMT27), on the Mac, where textutil runs in tests. The Mac
/// keeps textutil until the reader has the same words as textutil in every
/// sample and at least textutil's headings, or each difference is named and
/// accepted; these tests are that check, and their failure messages list
/// every difference.
final class ODTTextutilComparisonTests: XCTestCase {

    // MARK: - Helpers

    /// The folder textutil writes its hidden output in; every read must leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("ODTComparisonWork")
    }

    /// The Markdown of the file at `url` as the reading text is made from
    /// textutil's HTML (the reader's own path). textutil reads it whatever
    /// the own reader's switch says (`OwnDocumentReaders.forcesTextutil`), so
    /// that the comparison is of the two readers even once the Mac reads
    /// OpenDocument text with the own one.
    private func textutilMarkdown(of url: URL) throws -> String {
        try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                try TextutilDocumentReader.extract(from: url, bookFormat: .odt, includesPages: true).markdown
            }
        }
    }

    /// The Markdown of TextMouth's own reading of the file at `url`, made by
    /// the same converter.
    private func ownMarkdown(of url: URL) throws -> String {
        let html = try ODTDocumentReader.html(of: url, includesPages: true)
        return try HTMLToMarkdownConverter.convert(html, includesPages: true)
    }

    /// Markdown without its comments (page markers and heading annotations).
    private func withoutComments(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
    }

    /// The words of `markdown`: runs of letters and digits, in order.
    private func words(of markdown: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in withoutComments(markdown).unicodeScalars {
            if TextutilPageBreaks.isCounted(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The words a listener hears of `markdown`: the words of its reading
    /// text (`MarkdownDocParser.parseChapter`), which writes no list marker,
    /// so that the numbers of a numbered list are not words of either reading.
    private func heardWords(of markdown: String) throws -> [String] {
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
        return words(of: chapter.text)
    }

    /// The headings of `markdown`, as "level: text".
    private func headings(of markdown: String) -> [String] {
        withoutComments(markdown).split(separator: "\n").compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
            return "\(hashes.count): \(line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces))"
        }
    }

    /// A heading line "level: text" as "level: its words", so that a
    /// difference in punctuation or escaping is not a difference.
    private func wordsOnly(_ heading: String) -> String {
        guard let colon = heading.firstIndex(of: ":") else { return heading }
        let text = String(heading[heading.index(after: colon)...])
        return String(heading[...colon]) + " " + words(of: text).joined(separator: " ")
    }

    /// The words of a heading line "level: text", with no level: the levels
    /// textutil gives come from sizes, and the own reading keeps the levels
    /// the file names, so a heading is textutil's and the own reading's when
    /// their words are.
    private func headingWords(_ heading: String) -> String {
        words(of: heading.drop { $0 != ":" }.dropFirst().description).joined(separator: " ")
    }

    /// The headings of `textutil` whose words are in none of `own`'s.
    private func headingsLacking(from own: [String], in textutil: [String]) -> [String] {
        let ownWords = Set(own.map(headingWords))
        return textutil.filter { !ownWords.contains(headingWords($0)) }
    }

    /// How many pages the Markdown marks.
    private func pageCount(of markdown: String) -> Int {
        markdown.components(separatedBy: "<!-- page: ").count - 1
    }

    /// What reading `markdown` against textutil's reading of the same file
    /// shows: the words only textutil's has, the words only the own one has
    /// (each in order, sorted for comparison), and the own reading's
    /// headings and textutil's that the own reading lacks.
    private func differences(own: String, textutil: String) throws -> (textutilOnly: [String], ownOnly: [String]) {
        var textutilOnly: [String] = [], ownOnly: [String] = []
        for change in try heardWords(of: own).difference(from: try heardWords(of: textutil)) {
            switch change {
            case .remove(_, let word, _): textutilOnly.append(word)
            case .insert(_, let word, _): ownOnly.append(word)
            }
        }
        // The differences come in no fixed order; they are compared sorted.
        return (textutilOnly.sorted(), ownOnly.sorted())
    }

    /// Asserts that the two readings have the same words in the same order
    /// and that TextMouth's has every heading textutil's has, listing each
    /// difference.
    private func assertAsGoodAsTextutil(
        sample path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let copy = try copyOfFormatSample(path)
        let textutil = try textutilMarkdown(of: copy)
        let own = try ownMarkdown(of: copy)
        let found = try differences(own: own, textutil: textutil)
        XCTAssertEqual(found.textutilOnly, [], "\(path): words only textutil has", file: file, line: line)
        XCTAssertEqual(found.ownOnly, [], "\(path): words only the own reader has", file: file, line: line)
        let ownHeadings = headings(of: own)
        let missing = headingsLacking(from: ownHeadings, in: headings(of: textutil))
        XCTAssertEqual(missing, [], "\(path): textutil's headings that the own reading lacks; own: \(ownHeadings)", file: file, line: line)
    }

    // MARK: - The Samples

    func testHandwrittenSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "odt/handwritten.odt")
    }

    func testTemplateSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "ott/handwritten.ott")
    }

    func testTextutilsOwnODTMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "odt/headings.odt")
    }

    // MARK: - Real Files from LibreOffice

    /// What reading one real OpenDocument file from LibreOffice's test data
    /// gives next to textutil's reading of it (FMT27). Nothing is left to
    /// differ silently: a file is the same, or its every difference is named
    /// here with the reason a listener would accept.
    private struct RealFile {
        /// The sample's name in `TestData/format-samples/odt`.
        let name: String
        /// The words only textutil's reading has, and only the own reading
        /// has, each in order.
        var textutilOnly: [String] = []
        var ownOnly: [String] = []
        /// For a difference too long to list: how many words, instead.
        var textutilOnlyCount: Int?
        var ownOnlyCount: Int?
        /// With a count, the first and last of the words, sorted, so that a
        /// count that stays right while the words change is noticed.
        var textutilOnlyEnds: (first: String, last: String)?
        var ownOnlyEnds: (first: String, last: String)?
        /// The headings of the own reading, as "level: words".
        var headings: [String] = []
        /// The headings of textutil's reading that the own reading lacks:
        /// those whose words are in none of the own reading's headings (the
        /// levels differ wherever the file names levels and textutil takes
        /// them from sizes).
        var textutilHeadingsNotOwn: [String] = []
        /// How many pages each reading finds.
        var pages = (own: 1, textutil: 1)
        /// For a file that differs: why the difference is acceptable, or
        /// better, for a listener.
        var why = ""
    }

    /// The fifteen real files, with what each comparison found.
    private static let realFiles: [RealFile] = [
        RealFile(
            name: "libreoffice-DUMMY2.odt", headings: ["1: Lorem ipsum"], pages: (3, 1),
            why: "the own reader begins pages at the layout's soft page breaks, which textutil's plain text loses"
        ),
        RealFile(
            name: "libreoffice-fdo66811-1.odt",
            ownOnly: ["This", "is", "test", "data", "of", "PDF", "export", "function"],
            headings: ["1: This is test data"],
            why: "the own reader reads the heading in a text box, which textutil drops"
        ),
        RealFile(
            name: "libreoffice-fdo69862.odt", textutilOnly: ["H1ello"], ownOnly: ["Hello", "Footnote"],
            why: "textutil runs the footnote's number into the word before it and drops the note's body; the own reader reads the word whole and the note after the text"
        ),
        RealFile(
            name: "libreoffice-ooo32780-1.odt", textutilOnlyCount: 212, ownOnlyCount: 21,
            textutilOnlyEnds: ("And", "wrists"), ownOnlyEnds: ("4", "the"),
            why: "textutil reads the text of the hidden sections, which a person does not see (212 words); the own reader reads the bodies of the notes, which textutil drops (21 words)"
        ),
        RealFile(
            name: "libreoffice-ooo77837-1.odt", textutilOnly: ["footnote1"], ownOnlyCount: 386, ownOnlyEnds: ("0", "you"),
            headings: ["1: Demo of bug", "1: References", "1: Main index"],
            why: "textutil runs the endnote's number into the word before it and drops the endnote's body, which here holds the whole bibliography; the own reader reads the word whole and the note after the text"
        ),
        RealFile(
            name: "libreoffice-referencelanguage.odt",
            headings: [
                "1: reference-language", "1: Sequence", "1: Chapter", "1: Paragraph", "1: Paragraph II", "1: Paragraph III",
                "1: „Őseinket...”", "1: A fejezetek", "1: Az egyebek", "1: 2018-asok", "1: 50-esek", "1: Isten",
            ],
            pages: (2, 1),
            why: "the own reader begins a page at the layout's soft page break, and keeps the headings at the levels the file names (textutil takes levels from sizes, 2 for most of these)"
        ),
        RealFile(name: "libreoffice-space.odt", headings: ["1: Simple spaces", "1: Spaces and <s/>"]),
        RealFile(name: "libreoffice-spellmenu-redline.odt"),
        RealFile(
            name: "libreoffice-tdf103025.odt", pages: (3, 1),
            why: "each table names a master page, which begins a page; textutil's plain text loses it"
        ),
        RealFile(
            name: "libreoffice-tdf128737.odt", pages: (4, 1),
            why: "the own reader begins pages at the breaks before a paragraph, at master pages, and at soft page breaks, which textutil's plain text loses"
        ),
        RealFile(
            name: "libreoffice-tdf152015.odt", textutilOnly: ["1", "2", "3"], ownOnlyCount: 61, ownOnlyEnds: ("04", "v"),
            headings: ["1: Das Restschuldbefreiungsverfahren in der InsO", "3: Zwischenergebnis für die Zeit während Wohlverhaltenphase"],
            why: "textutil reads the numbers of the footnotes and drops their bodies; the own reader reads the bodies after the text, without the numbers"
        ),
        RealFile(
            name: "libreoffice-tdf152710.odt",
            headings: ["1: Laisvos programos vaikų lavinimui"], pages: (2, 1),
            why: "the own reader begins a page at the layout's soft page break"
        ),
        RealFile(
            name: "libreoffice-tdf156905.odt",
            headings: ["1: [Regression] Copy and paste formula, now paste value"], pages: (4, 1),
            why: "the own reader begins pages at the layout's soft page breaks"
        ),
        RealFile(
            name: "libreoffice-tdf169882.odt",
            ownOnly: ["nibh", "eu", "sollicitudin", "molestie"],
            headings: [
                "1: Heading", "2: Heading", "3: Heading", "2: Heading", "2: Heading", "2: Heading", "1: Heading",
                "1: Heading", "2: Heading",
            ],
            pages: (7, 1),
            why: "the own reader reads the text box, which textutil drops, and begins pages at soft page breaks and master pages"
        ),
        RealFile(
            name: "libreoffice-whitespace.odt", textutilOnly: ["1"], ownOnly: ["X", "X", "X", "X"],
            why: "textutil drops the words of text boxes and shapes (four \"X\"), and reads the mark of a footnote (\"1\"); the own reader reads the words and not the mark"
        ),
    ]

    /// Every real file reads with the same words as textutil's reading, or
    /// with the differences named in `realFiles`, the same headings, and at
    /// least textutil's pages. One failure lists every difference of every
    /// file.
    func testRealFilesFromLibreOfficeMatchTextutilOrNameTheirDifferences() throws {
        var problems: [String] = []
        for file in Self.realFiles {
            let copy = try copyOfFormatSample("odt/" + file.name)
            let own = try ownMarkdown(of: copy)
            let textutil = try textutilMarkdown(of: copy)

            // The words, in order: what only one reading has.
            let found = try differences(own: own, textutil: textutil)
            if let count = file.textutilOnlyCount {
                if found.textutilOnly.count != count { problems.append("\(file.name): \(found.textutilOnly.count) words only textutil has, expected \(count)") }
                if let ends = file.textutilOnlyEnds, (found.textutilOnly.first, found.textutilOnly.last) != (ends.first, ends.last) {
                    problems.append("\(file.name): first and last words only textutil has \(found.textutilOnly.first ?? "none"), \(found.textutilOnly.last ?? "none"), expected \(ends)")
                }
            } else if found.textutilOnly != file.textutilOnly.sorted() {
                problems.append("\(file.name): words only textutil has \(found.textutilOnly), expected \(file.textutilOnly)")
            }
            if let count = file.ownOnlyCount {
                if found.ownOnly.count != count { problems.append("\(file.name): \(found.ownOnly.count) words only the own reader has, expected \(count)") }
                if let ends = file.ownOnlyEnds, (found.ownOnly.first, found.ownOnly.last) != (ends.first, ends.last) {
                    problems.append("\(file.name): first and last words only the own reader has \(found.ownOnly.first ?? "none"), \(found.ownOnly.last ?? "none"), expected \(ends)")
                }
            } else if found.ownOnly != file.ownOnly.sorted() {
                problems.append("\(file.name): words only the own reader has \(found.ownOnly), expected \(file.ownOnly)")
            }

            // The headings: the own reading's, and textutil's all among them.
            let ownHeadings = headings(of: own).map(wordsOnly)
            if ownHeadings != file.headings.map(wordsOnly) {
                problems.append("\(file.name): own headings \(ownHeadings), expected \(file.headings.map(wordsOnly))")
            }
            let missing = headingsLacking(from: ownHeadings, in: headings(of: textutil)).map(wordsOnly)
            if missing != file.textutilHeadingsNotOwn.map(wordsOnly) {
                problems.append("\(file.name): textutil's headings missing from the own reading: \(missing), expected \(file.textutilHeadingsNotOwn)")
            }

            // The pages.
            let pages = (own: pageCount(of: own), textutil: pageCount(of: textutil))
            if pages != file.pages { problems.append("\(file.name): pages own \(pages.own), textutil \(pages.textutil); expected \(file.pages)") }
        }
        XCTAssertEqual(problems, [])
    }

    /// Every difference a real file names has a reason, and a real file that
    /// reads the same as textutil's reading has none.
    func testEveryNamedDifferenceHasItsReason() {
        for file in Self.realFiles {
            let differs = !file.textutilOnly.isEmpty || !file.ownOnly.isEmpty || file.textutilOnlyCount != nil
                || file.ownOnlyCount != nil || file.pages.own != file.pages.textutil
                || !file.textutilHeadingsNotOwn.isEmpty
            XCTAssertEqual(differs, !file.why.isEmpty, file.name)
        }
    }

    /// The comparison names every real sample from LibreOffice, so that a
    /// sample added later is compared too.
    func testTheComparisonNamesEveryRealSample() throws {
        let folder = try formatSampleURL("odt")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("libreoffice-") }.sorted()
        XCTAssertEqual(Self.realFiles.map(\.name).sorted(), onDisk)
    }

    // MARK: - Routing

    /// The test hook sends OpenDocument text to textutil whatever the
    /// reader's switch says, and changes nothing when false.
    func testTheTestHookSendsOpenDocumentToTextutil() throws {
        let file = try copyOfFormatSample("odt/handwritten.odt")
        XCTAssertFalse(OwnDocumentReaders.forcesTextutil)
        let forced = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            try OwnDocumentReaders.html(of: file, as: .odt, includesPages: false)
        }
        XCTAssertNil(forced)
        // Where the reader is on, the router answers with its HTML; where it
        // is not, with nil, so that textutil reads.
        let routed = try OwnDocumentReaders.html(of: file, as: .odt, includesPages: false)
        XCTAssertEqual(routed != nil, ODTDocumentReader.isOn)
        if let routed {
            XCTAssertEqual(routed, try ODTDocumentReader.html(of: file, includesPages: false))
        }
    }
}
