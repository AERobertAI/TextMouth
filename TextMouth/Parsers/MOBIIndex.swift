import Foundation

/// One entry of a Kindle (MOBI) book's table of contents (its NCX index):
/// a label, the place in the text it names, and how deep it lies.
struct MOBIIndexEntry: Equatable {
    /// The entry's label, as the book spells it; empty when its label could
    /// not be found.
    var label: String
    /// The byte offset into the decompressed text where the entry's section
    /// begins: the same coordinates `filepos` attributes use.
    var offset: Int
    /// 0 for a chapter, 1 for a section of a chapter, and so on.
    var depth: Int
}

/// Reads a Kindle (MOBI) book's NCX index: the table of contents the book
/// keeps in INDX records, with the tag table (TAGX) that says how each entry
/// is packed and the strings (CNCX) that hold the labels.
///
/// Written from the format's specification (the MobileRead wiki's "MOBI"
/// page), with foliate-js's `mobi.js` (MIT) read as a map of the layout:
/// `getIndexData` and `getNCX` there are the model of `entries(...)` here.
/// The code is not copied; it is written again in Swift with every offset,
/// length, and count checked, and a cap on everything the file can make
/// large.
enum MOBIIndex {

    /// Most entries a book may hold, and most label strings (CNCX records)
    /// and tags it may name. A real book has dozens of entries.
    private static let maximumEntries = 100_000
    private static let maximumStringRecords = 32
    private static let maximumTags = 64

    /// One tag of the tag table: which value it is, how many numbers make
    /// one value, the mask that picks its bits from the entry's control
    /// byte, and whether it ends a control byte rather than being a tag.
    private struct Tag {
        var number: Int
        var valuesPerCount: Int
        var mask: Int
        var endsControlByte: Bool
    }

    /// The entries of the index that begins at record `indexRecord`.
    /// - Throws: `MOBIError.damaged` when a record the index needs is not in
    ///   the book, a header or table is cut short, or an offset or length
    ///   points outside its record.
    static func entries(startingAt indexRecord: Int, in database: MOBIPalmDatabase) throws -> [MOBIIndexEntry] {
        let first = try database.record(indexRecord, "The index")
        guard first.hasTag("INDX", at: 0) else { throw MOBIError.damaged("the index does not begin with INDX") }
        let headerLength = try first.uint32(4, "The index header's length")
        let dataRecordCount = try first.uint32(24, "The index's record count")
        let encoding = try first.uint32(28, "The index's encoding")
        let stringRecordCount = try first.uint32(52, "The index's string record count")
        guard stringRecordCount <= maximumStringRecords, dataRecordCount <= database.recordCount else {
            throw MOBIError.damaged("the index names more records than the book has")
        }

        let tags = try tagTable(in: first, at: headerLength)
        let controlByteCount = try first.uint32(headerLength + 8, "The tag table's control byte count")
        let labels = try strings(
            inRecords: (indexRecord + dataRecordCount + 1)..<(indexRecord + dataRecordCount + 1 + stringRecordCount),
            of: database, encoding: encoding
        )

        var entries: [MOBIIndexEntry] = []
        for index in 0..<dataRecordCount {
            let record = try database.record(indexRecord + 1 + index, "An index record")
            guard record.hasTag("INDX", at: 0) else { throw MOBIError.damaged("an index record does not begin with INDX") }
            let tableOffset = try record.uint32(20, "An index record's entry table")
            let count = try record.uint32(24, "An index record's entry count")
            // The entry table: "IDXT", then one 16-bit offset for each entry.
            guard record.hasTag("IDXT", at: tableOffset) else { throw MOBIError.damaged("an index record's entry table is missing") }
            try record.require(tableOffset + 4, count * 2, "An index record's entry table")
            for position in 0..<count {
                guard entries.count < maximumEntries else { throw MOBIError.damaged("the index holds too many entries") }
                let entryOffset = try record.uint16(tableOffset + 4 + position * 2, "An index entry's offset")
                let values = try tagValues(of: record, at: entryOffset, tags: tags, controlByteCount: controlByteCount)
                // Tag 1 is the entry's offset into the text, 3 its label's
                // place among the strings, and 4 its depth. An entry with no
                // offset names no place, so it is passed over.
                guard let offset = values[1]?.first else { continue }
                entries.append(MOBIIndexEntry(
                    label: values[3]?.first.flatMap { labels[$0] } ?? "",
                    offset: offset,
                    depth: values[4]?.first ?? 0
                ))
            }
        }
        return entries
    }

    // MARK: The Tag Table

    /// The tags of the table (TAGX) that follows the index header at `offset`.
    private static func tagTable(in record: MOBIView, at offset: Int) throws -> [Tag] {
        guard record.hasTag("TAGX", at: offset) else { throw MOBIError.damaged("the index has no tag table") }
        let length = try record.uint32(offset + 4, "The tag table's length")
        try record.require(offset, length, "The tag table")
        guard length >= 12 else { throw MOBIError.damaged("the tag table is too short") }
        let count = (length - 12) / 4
        guard count <= maximumTags else { throw MOBIError.damaged("the tag table names too many tags") }
        return try (0..<count).map { index in
            let at = offset + 12 + index * 4
            return Tag(
                number: try record.uint8(at, "A tag's number"),
                valuesPerCount: try record.uint8(at + 1, "A tag's value count"),
                mask: try record.uint8(at + 2, "A tag's mask"),
                endsControlByte: try record.uint8(at + 3, "A tag's end flag") & 1 != 0
            )
        }
    }

    // MARK: One Entry

    /// The numbers an index entry holds, by tag, read from the entry that
    /// begins at `offset` in `record`: a name (1 length byte and its bytes),
    /// `controlByteCount` control bytes saying how many values each tag has,
    /// and the values, as variable-width numbers.
    private static func tagValues(
        of record: MOBIView, at offset: Int, tags: [Tag], controlByteCount: Int
    ) throws -> [Int: [Int]] {
        let nameLength = try record.uint8(offset, "An index entry's name length")
        let controlStart = offset + 1 + nameLength
        try record.require(controlStart, controlByteCount, "An index entry's control bytes")
        var position = controlStart + controlByteCount

        // First, how many values each tag has. A control byte whose masked
        // bits are all set says the count is not in the byte: it follows as
        // a number of bytes (if the mask has several bits) or is one value.
        var plans: [(tag: Tag, count: Int?, byteLength: Int?)] = []
        var controlIndex = 0
        for tag in tags {
            if tag.endsControlByte {
                controlIndex += 1
                continue
            }
            guard tag.mask != 0, controlIndex < controlByteCount else { continue }
            let masked = try record.uint8(controlStart + controlIndex, "An index entry's control byte") & tag.mask
            if masked == tag.mask {
                if tag.mask.nonzeroBitCount > 1 {
                    let (length, size) = try variableNumber(in: record, at: position)
                    plans.append((tag, nil, length))
                    position += size
                } else {
                    plans.append((tag, 1, nil))
                }
            } else {
                plans.append((tag, masked >> tag.mask.trailingZeroBitCount, nil))
            }
        }

        // Then the values themselves, in the order of the tags.
        var values: [Int: [Int]] = [:]
        for plan in plans {
            var numbers: [Int] = []
            if let count = plan.count {
                for _ in 0..<(count * plan.tag.valuesPerCount) {
                    let (number, size) = try variableNumber(in: record, at: position)
                    numbers.append(number)
                    position += size
                }
            } else if let byteLength = plan.byteLength {
                var consumed = 0
                while consumed < byteLength {
                    let (number, size) = try variableNumber(in: record, at: position)
                    numbers.append(number)
                    position += size
                    consumed += size
                }
            }
            values[plan.tag.number] = numbers
        }
        return values
    }

    /// The variable-width number at `offset` in `record` and its size in
    /// bytes: 7-bit groups, most significant first, the last group with its
    /// high bit set; at most four bytes.
    /// - Throws: `MOBIError.damaged` when the record ends before the number does.
    private static func variableNumber(in record: MOBIView, at offset: Int) throws -> (value: Int, size: Int) {
        var value = 0
        for size in 1...4 {
            let byte = try record.uint8(offset + size - 1, "A number in the index")
            value = value << 7 | byte & 0x7F
            if byte & 0x80 != 0 { return (value, size) }
        }
        return (value, 4)
    }

    // MARK: The Labels

    /// The label strings of the CNCX records `records`, by their place: a
    /// record's strings are keyed by their offset in the record, plus 0x10000
    /// for each record before it. A string is a length (a number as above)
    /// and its bytes in the index's encoding. A string that runs past its
    /// record ends the record's strings, as the zero padding there does.
    private static func strings(
        inRecords records: Range<Int>, of database: MOBIPalmDatabase, encoding: Int
    ) throws -> [Int: String] {
        var labels: [Int: String] = [:]
        for (number, recordIndex) in records.enumerated() {
            let record = try database.record(recordIndex, "A label record")
            var position = 0
            while position < record.count {
                let start = position
                guard let (length, size) = try? variableNumber(in: record, at: position) else { break }
                position += size
                guard let bytes = try? record.slice(position, length, "A label") else { break }
                position += length
                // Zero padding reads as empty strings, which name nothing.
                if length > 0 { labels[number * 0x10000 + start] = MOBIText.decode(bytes, encoding: encoding) }
            }
        }
        return labels
    }
}
