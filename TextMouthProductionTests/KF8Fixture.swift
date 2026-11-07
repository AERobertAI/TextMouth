import XCTest

/// Builds a Kindle KF8 book in memory, byte by byte, so a test can make a
/// valid book of any shape (documents cut into any fragments, a contents of
/// any depth, a guide, a hybrid with a MOBI 6 half) and then damage it at a
/// known place. The bytes are laid out as the MobileRead wiki's "KF8" page
/// describes, the way the real files of calibre and kindlegen are (their
/// skeleton rows hold the fragment count twice and the place twice, their
/// fragment rows are named for the place in the document the fragment goes
/// back to), so the fixture also proves `KF8Layout` and `KF8Book` agree with
/// the real layout and not only with each other. Builds on `MOBIFixture`'s
/// number and database helpers.
struct KF8Fixture {

    /// One XHTML document of the book: its markup, and the stretches of it
    /// (byte ranges of the markup, ascending and apart) that the book cuts
    /// out of it into fragments.
    struct Document {
        var html: String
        var chunks: [Range<Int>] = []

        /// The document with each of `texts` (found in order) cut out as a fragment.
        init(html: String, cutting texts: [String] = []) {
            self.html = html
            var from = html.startIndex
            for text in texts {
                guard let found = html.range(of: text, range: from..<html.endIndex) else {
                    XCTFail("The fixture's document does not hold \(text)")
                    continue
                }
                chunks.append(html.utf8.distance(from: html.startIndex, to: found.lowerBound)
                    ..< html.utf8.distance(from: html.startIndex, to: found.upperBound))
                from = found.upperBound
            }
        }
    }

    /// One contents entry: its label, the fragment it names (by the
    /// document's index and the fragment's place among that document's),
    /// the place in the fragment, and its depth.
    struct Entry {
        var label: String
        var document: Int
        var fragment = 0
        var offset = 0
        var depth = 0
    }

    // MARK: What the book holds

    var documents: [Document]
    var entries: [Entry] = []
    /// Guide entries: a type ("toc") and the document whose first fragment it names.
    var guide: [(type: String, document: Int)] = []
    /// The flows that follow the markup flow, each a flow of its own in the
    /// flow table: flow 1 is a style sheet, and an SVG picture is a flow
    /// that markup names (`kindle:flow:0002?mime=image/svg+xml`). A book with
    /// no flows after the markup has no text after it.
    var flows = ["p { margin: 0 }"]
    var title: String? = "Fixture KF8 Book"
    var authors = ["Imre Falk"]
    var language: String? = "en"
    var extraEXTH: [Int: [UInt8]] = [:]
    var fullName = "Fixture KF8 Book Full Name"
    var compression = 1
    var recordSize = 4096
    var encryption = 0
    var drmOffset = 0xFFFF_FFFF
    var version = 8
    /// Rows to write in place of the sound ones, for a test that damages an index.
    var skeletonRowsOverride: [Row]?
    var fragmentRowsOverride: [Row]?
    /// Rows and label strings to write as the contents in place of the entries', for a test that makes
    /// the contents lie (one label shared by a thousand rows, a depth past six).
    var contentsOverride: (rows: [Row], strings: [String])?
    /// The place in its fragment that a guide entry names (0 for the start of a document).
    var guideOffset = 0

    // MARK: Layout

    static let mobiHeaderLength = 264

    init(documents: [Document]) {
        self.documents = documents
    }

    /// A book of one document with `body` in it, cut at each of `cuts` (texts in the body).
    init(body: String, cutting cuts: [String] = []) {
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Part</title></head><body>\(body)</body></html>"
        self.init(documents: [Document(html: html, cutting: cuts)])
    }

    /// The sequence number of fragment `fragment` of document `document`: the
    /// fragments are numbered from 0 through the whole book.
    func fid(document: Int, fragment: Int) -> Int {
        documents[..<document].reduce(0) { $0 + $1.chunks.count } + fragment
    }

    /// What the markup flow holds, document by document, with where each
    /// piece is: skeleton, then fragments.
    struct Placed {
        var text: [UInt8] = []
        /// Each document's skeleton range and its fragments' ranges.
        var skeletons: [Range<Int>] = []
        var fragments: [[Range<Int>]] = []
        var insertOffsets: [[Int]] = []
    }

    /// The markup flow laid out as the text holds it.
    func placed() -> Placed {
        var result = Placed()
        for document in documents {
            let bytes = Array(document.html.utf8)
            let base = result.text.count
            // The skeleton: the document without its chunks.
            var skeleton: [UInt8] = []
            var cursor = 0
            for chunk in document.chunks {
                skeleton += bytes[cursor..<chunk.lowerBound]
                cursor = chunk.upperBound
            }
            skeleton += bytes[cursor...]
            result.text += skeleton
            result.skeletons.append(base..<(base + skeleton.count))
            var ranges: [Range<Int>] = []
            var inserts: [Int] = []
            for chunk in document.chunks {
                let start = result.text.count
                result.text += bytes[chunk]
                ranges.append(start..<result.text.count)
                // The fragments before this one are already in, so the place is the chunk's own.
                inserts.append(base + chunk.lowerBound)
            }
            result.fragments.append(ranges)
            result.insertOffsets.append(inserts)
        }
        return result
    }

    // MARK: Building

    /// The book as a file's bytes.
    func data() -> [UInt8] {
        MOBIFixture.database(named: "Fixture_KF8", type: "BOOK", creator: "MOBI", records: records())
    }

    /// A hybrid file: `mobi6`'s records, a boundary record, and this book's
    /// records, with EXTH 121 in the MOBI 6 half naming the record the KF8
    /// half begins at.
    func hybrid(mobi6: MOBIFixture) -> [UInt8] {
        var first = mobi6
        let firstRecords = Self.records(of: first.data())
        let boundary = firstRecords.count + 1
        first.extraEXTH[121] = MOBIFixture.be32(boundary)
        let firstWithBoundary = Self.records(of: first.data())
        XCTAssertEqual(firstWithBoundary.count + 1, boundary, "the EXTH record does not change the record count")
        return MOBIFixture.database(
            named: "Fixture_Hybrid", type: "BOOK", creator: "MOBI",
            records: firstWithBoundary + [Array("BOUNDARY".utf8)] + records()
        )
    }

    /// The records of the Palm database `file`.
    static func records(of file: [UInt8]) -> [[UInt8]] {
        var offsets = MOBIFixture.recordOffsets(of: file)
        offsets.append(file.count)
        return (0..<(offsets.count - 1)).map { Array(file[offsets[$0]..<offsets[$0 + 1]]) }
    }

    /// The KF8 book's records, numbered from 0: record 0, the text, the flow
    /// table, and the skeleton, fragment, contents, and guide indexes.
    func records() -> [[UInt8]] {
        let laid = placed()
        let markupEnd = laid.text.count
        var text = laid.text
        var flowRanges = [0..<markupEnd]
        for flow in flows {
            let start = text.count
            text += Array(flow.utf8)
            flowRanges.append(start..<text.count)
        }
        var records: [[UInt8]] = []

        // The text, cut into records and compressed.
        var textRecords: [[UInt8]] = []
        var start = 0
        while start < text.count {
            let chunk = Array(text[start..<min(text.count, start + recordSize)])
            textRecords.append(compression == 2 ? MOBIFixture.compress(chunk) : chunk)
            start += recordSize
        }

        // The tables after the text.
        var tables: [[UInt8]] = []
        let flowTable = Self.flowTable(flowRanges)
        let first = 1 + textRecords.count
        tables.append(flowTable)
        let skeletonRecord = first + tables.count
        tables += skeletonIndex(laid)
        let fragmentRecord = first + tables.count
        tables += fragmentIndex(laid)
        var ncxRecord: Int?
        if !entries.isEmpty || contentsOverride != nil {
            ncxRecord = first + tables.count
            tables += contentsIndex(laid)
        }
        var guideRecord: Int?
        if !guide.isEmpty {
            guideRecord = first + tables.count
            tables += guideIndex(laid)
        }

        records.append(record0(
            textLength: text.count, textRecordCount: textRecords.count, flowTable: first,
            skeleton: skeletonRecord, fragment: fragmentRecord, ncx: ncxRecord, guide: guideRecord
        ))
        return records + textRecords + tables
    }

    /// Record 0: the PalmDOC header, the MOBI header of a KF8 book, the EXTH
    /// records, and the full name.
    private func record0(
        textLength: Int, textRecordCount: Int, flowTable: Int, skeleton: Int, fragment: Int, ncx: Int?, guide: Int?
    ) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 16 + Self.mobiHeaderLength)
        MOBIFixture.put16(&record, 0, compression)
        MOBIFixture.put32(&record, 4, textLength)
        MOBIFixture.put16(&record, 8, textRecordCount)
        MOBIFixture.put16(&record, 10, recordSize)
        MOBIFixture.put16(&record, 12, encryption)
        record.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        MOBIFixture.put32(&record, 20, Self.mobiHeaderLength)
        MOBIFixture.put32(&record, 24, 2)
        MOBIFixture.put32(&record, 28, 65001)
        MOBIFixture.put32(&record, 36, version)
        MOBIFixture.put32(&record, 112, 0xFFFF_FFFF)
        MOBIFixture.put32(&record, 168, drmOffset)
        MOBIFixture.put32(&record, 192, flowTable)
        MOBIFixture.put32(&record, 196, 1 + flows.count)
        MOBIFixture.put32(&record, 240, 0)
        MOBIFixture.put32(&record, 244, ncx ?? 0xFFFF_FFFF)
        MOBIFixture.put32(&record, 248, fragment)
        MOBIFixture.put32(&record, 252, skeleton)
        MOBIFixture.put32(&record, 260, guide ?? 0xFFFF_FFFF)

        var exth: [(type: Int, data: [UInt8])] = authors.map { (type: 100, data: Array($0.utf8)) }
        if let title { exth.append((type: 503, data: Array(title.utf8))) }
        if let language { exth.append((type: 524, data: Array(language.utf8))) }
        exth += extraEXTH.sorted { $0.key < $1.key }.map { (type: $0.key, data: $0.value) }
        if !exth.isEmpty {
            MOBIFixture.put32(&record, 128, 0x40)
            var body: [UInt8] = []
            for item in exth { body += MOBIFixture.be32(item.type) + MOBIFixture.be32(item.data.count + 8) + item.data }
            let length = 12 + body.count
            let padding = (4 - length % 4) % 4
            record += Array("EXTH".utf8) + MOBIFixture.be32(length + padding) + MOBIFixture.be32(exth.count)
                + body + [UInt8](repeating: 0, count: padding)
        }
        let name = Array(fullName.utf8)
        MOBIFixture.put32(&record, 84, record.count)
        MOBIFixture.put32(&record, 88, name.count)
        return record + name + [0, 0]
    }

    /// The flow table: FDST, the offset of the entries, their count, and a
    /// start and end for each flow.
    static func flowTable(_ flows: [Range<Int>]) -> [UInt8] {
        var table = Array("FDST".utf8) + MOBIFixture.be32(12) + MOBIFixture.be32(flows.count)
        for flow in flows { table += MOBIFixture.be32(flow.lowerBound) + MOBIFixture.be32(flow.upperBound) }
        return table
    }

    // MARK: The Indexes

    /// A tag of an index: its number, how many numbers one value has, and the
    /// mask of the control byte that holds how many values an entry has.
    struct Tag {
        var number: Int
        var valuesPerCount: Int
        var mask: Int
    }

    /// One row of an index: its name and the numbers it holds by tag.
    struct Row {
        var name: [UInt8]
        var values: [Int: [Int]]
    }

    /// The skeleton index: for each document, its fragment count (twice, as
    /// real books write it) and its place (offset and length, twice).
    func skeletonIndex(_ laid: Placed) -> [[UInt8]] {
        Self.index(
            tags: [Tag(number: 1, valuesPerCount: 2, mask: 3), Tag(number: 6, valuesPerCount: 4, mask: 12)],
            rows: skeletonRowsOverride ?? skeletonRows(laid), strings: [])
    }

    /// The rows of the skeleton index of a sound book. A test that damages
    /// them changes these and sets `skeletonRowsOverride`.
    func skeletonRows(_ laid: Placed) -> [Row] {
        documents.indices.map { index -> Row in
            let place = laid.skeletons[index]
            let count = documents[index].chunks.count
            return Row(
                name: Array(String(format: "SKEL%010d", index).utf8),
                values: [1: [count, count], 6: [place.lowerBound, place.count, place.lowerBound, place.count]]
            )
        }
    }

    /// The fragment index: for each fragment, named for the place it goes
    /// back to, its selector (a string), its document, its number, and its
    /// place and length counted from the end of its document's skeleton.
    func fragmentIndex(_ laid: Placed) -> [[UInt8]] {
        Self.index(
            tags: [Tag(number: 2, valuesPerCount: 1, mask: 1), Tag(number: 3, valuesPerCount: 1, mask: 2),
                   Tag(number: 4, valuesPerCount: 1, mask: 4), Tag(number: 6, valuesPerCount: 2, mask: 8)],
            rows: fragmentRowsOverride ?? fragmentRows(laid), strings: ["P-//*[@aid='0']"]
        )
    }

    /// The rows of the fragment index of a sound book.
    func fragmentRows(_ laid: Placed) -> [Row] {
        var rows: [Row] = []
        var number = 0
        for (index, document) in documents.enumerated() {
            var offset = 0
            for (position, _) in document.chunks.enumerated() {
                let range = laid.fragments[index][position]
                rows.append(Row(
                    name: Array(String(format: "%010d", laid.insertOffsets[index][position]).utf8),
                    values: [2: [0], 3: [index], 4: [number], 6: [offset, range.count]]
                ))
                offset += range.count
                number += 1
            }
        }
        return rows
    }

    /// The contents: for each entry, an offset, a size, its label, its depth,
    /// and the fragment and place it names.
    func contentsIndex(_ laid: Placed) -> [[UInt8]] {
        let tags = [Tag(number: 1, valuesPerCount: 1, mask: 1), Tag(number: 2, valuesPerCount: 1, mask: 2),
                    Tag(number: 3, valuesPerCount: 1, mask: 4), Tag(number: 4, valuesPerCount: 1, mask: 8),
                    Tag(number: 6, valuesPerCount: 2, mask: 16)]
        if let contentsOverride { return Self.index(tags: tags, rows: contentsOverride.rows, strings: contentsOverride.strings) }
        var labels: [String] = []
        var rows: [Row] = []
        var place = 0
        for (position, entry) in entries.enumerated() {
            labels.append(entry.label)
            let labelPlace = place
            place += MOBIFixture.variableNumber(entry.label.utf8.count).count + entry.label.utf8.count
            let fragment = fid(document: entry.document, fragment: entry.fragment)
            rows.append(Row(
                name: Array(String(format: "%02d", position).utf8),
                values: [1: [0], 2: [0], 3: [labelPlace], 4: [entry.depth], 6: [fragment, entry.offset]]
            ))
        }
        return Self.index(tags: tags, rows: rows, strings: labels)
    }

    /// The guide: for each entry, a type for its name, a label, and the
    /// fragment it names.
    func guideIndex(_ laid: Placed) -> [[UInt8]] {
        var labels: [String] = []
        var place = 0
        let rows = guide.map { entry -> Row in
            labels.append(entry.type)
            let labelPlace = place
            place += MOBIFixture.variableNumber(entry.type.utf8.count).count + entry.type.utf8.count
            return Row(
                name: Array(entry.type.utf8),
                values: [1: [labelPlace], 6: [fid(document: entry.document, fragment: 0), guideOffset]]
            )
        }
        return Self.index(
            tags: [Tag(number: 1, valuesPerCount: 1, mask: 1), Tag(number: 6, valuesPerCount: 2, mask: 2)],
            rows: rows, strings: labels
        )
    }

    /// Most rows one record of entries holds: the entries' places are 16-bit
    /// numbers, so a record is under 64 KB, and a big index is several.
    static let rowsPerRecord = 1500

    /// An index of `rows` under `tags`: its header record (with the tag
    /// table), the records of entries (up to `rowsPerRecord` rows each), and
    /// one of `strings` (a length and its bytes each, the way labels are
    /// kept) unless there are none.
    static func index(tags: [Tag], rows: [Row], strings: [String]) -> [[UInt8]] {
        let tagBytes: [[UInt8]] = tags.map { [UInt8($0.number), UInt8($0.valuesPerCount), UInt8($0.mask), 0] } + [[0, 0, 0, 1]]
        let tagx = Array("TAGX".utf8) + MOBIFixture.be32(12 + tagBytes.count * 4) + MOBIFixture.be32(1) + tagBytes.flatMap { $0 }

        var header = [UInt8](repeating: 0, count: 192)
        header.replaceSubrange(0..<4, with: Array("INDX".utf8))
        MOBIFixture.put32(&header, 4, 192)
        MOBIFixture.put32(&header, 28, 65001)
        MOBIFixture.put32(&header, 52, strings.isEmpty ? 0 : 1)

        // The rows, in records of entries.
        var dataRecords: [[UInt8]] = []
        var start = 0
        repeat {
            let chunk = rows[start..<min(rows.count, start + rowsPerRecord)]
            var data = header
            var offsets: [Int] = []
            for row in chunk {
                offsets.append(data.count)
                data += [UInt8(row.name.count)] + row.name
                // One control byte: how many values each tag has.
                var control = 0
                for tag in tags {
                    let count = (row.values[tag.number]?.count ?? 0) / tag.valuesPerCount
                    control |= count << tag.mask.trailingZeroBitCount
                }
                data.append(UInt8(control))
                for tag in tags {
                    for value in row.values[tag.number] ?? [] { data += MOBIFixture.variableNumber(value) }
                }
            }
            let tableOffset = data.count
            data += Array("IDXT".utf8) + offsets.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            data += [UInt8](repeating: 0, count: data.count % 4 == 0 ? 0 : 4 - data.count % 4)
            MOBIFixture.put32(&data, 20, tableOffset)
            MOBIFixture.put32(&data, 24, chunk.count)
            dataRecords.append(data)
            start += rowsPerRecord
        } while start < rows.count

        MOBIFixture.put32(&header, 24, dataRecords.count)
        var result = [header + tagx] + dataRecords
        if !strings.isEmpty {
            result.append(strings.flatMap { MOBIFixture.variableNumber($0.utf8.count) + Array($0.utf8) })
        }
        return result
    }
}
