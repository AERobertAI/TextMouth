import Foundation

/// What record 0 of a Kindle (MOBI) book says about the book: the PalmDOC
/// header (how the text is compressed and cut into records), the MOBI
/// header (its encoding, version, DRM, and where its index is), and the
/// EXTH records (author, title, language, and the like).
///
/// Written from the format's specification (the MobileRead wiki's "MOBI"
/// page), with foliate-js's `mobi.js` (MIT) read as a map of the fields'
/// offsets. Every field is read through `MOBIView`, so a header that is cut
/// short or points outside its record throws `MOBIError.damaged`.
struct MOBIHeaders {
    // MARK: PalmDOC header (record 0, bytes 0 to 15)

    /// 1 none, 2 PalmDOC (LZ77), 17480 HUFF/CDIC.
    let compression: Int
    /// The length of the whole text once decompressed.
    let textLength: Int
    /// How many records after record 0 hold the text.
    let textRecordCount: Int
    /// The length each record decompresses to, 4096 in every real book.
    let recordSize: Int
    /// 0 for a book that is not encrypted.
    let encryption: Int

    // MARK: MOBI header (from byte 16)

    /// Whether the record holds a MOBI header. A plain PalmDOC book's
    /// record 0 is the PalmDOC header alone, and the fields below are then
    /// their defaults.
    let hasMOBIHeader: Bool
    /// 65001 for UTF-8, 1252 for Windows-1252.
    let encoding: Int
    /// The format's version: 6 and under for MOBI 6, 8 for KF8.
    let version: Int
    /// The book's full name, from the header; nil when it holds none that
    /// lies inside the record.
    let fullName: String?
    /// Whether the header says the book carries DRM: its DRM offset is
    /// anything but 0xFFFFFFFF.
    let hasDRM: Bool
    /// The record the Huffman table is in, and how many records the table
    /// and its dictionaries fill; only for compression 17480.
    let huffmanFirstRecord: Int
    let huffmanRecordCount: Int
    /// The extra-data flags: bit 0 is the multibyte overlap at the end of
    /// each text record, and each other set bit one more trailing entry.
    let extraDataFlags: Int
    /// The record the NCX index starts at (INDX); nil for a book with none.
    let indexRecord: Int?

    // MARK: KF8 fields (from byte 192, in a header of version 8)

    /// The record the flow table (FDST) is in; nil when the header names
    /// none, as a MOBI 6 header does not.
    let flowTableRecord: Int?
    /// The record the skeleton index (SKEL) starts at; nil for a book with none.
    let skeletonIndexRecord: Int?
    /// The record the fragment index (FRAG) starts at; nil for a book with none.
    let fragmentIndexRecord: Int?
    /// The record the guide index starts at, which names the book's cover,
    /// contents page, and start; nil for a book with none.
    let guideIndexRecord: Int?

    // MARK: EXTH

    /// The EXTH records by type, each type's values in the order they
    /// appear. Empty for a book without an EXTH header.
    let exth: [Int: [[UInt8]]]

    /// The EXTH types this reader uses.
    enum EXTHType {
        static let author = 100
        static let publisher = 101
        static let isbn = 104
        static let kf8Boundary = 121
        static let title = 503
        static let language = 524
    }

    /// Most EXTH records a book may hold. A real book has a few dozen.
    private static let maximumEXTHRecords = 10_000

    /// Where the MOBI header starts in record 0: right after the PalmDOC header.
    private static let mobiMagicOffset = 16

    /// Reads record 0.
    /// - Parameter requiresMOBIHeader: True for a `BOOKMOBI` book, whose
    ///   record 0 must hold a MOBI header; false for a PalmDOC book, whose
    ///   record 0 may be the PalmDOC header alone.
    init(record0: MOBIView, requiresMOBIHeader: Bool) throws {
        compression = try record0.uint16(0, "The compression type")
        textLength = try record0.uint32(4, "The text length")
        textRecordCount = try record0.uint16(8, "The text record count")
        recordSize = try record0.uint16(10, "The text record size")
        encryption = try record0.uint16(12, "The encryption type")

        let hasHeader = record0.hasTag("MOBI", at: Self.mobiMagicOffset)
        guard hasHeader || !requiresMOBIHeader else { throw MOBIError.notAKindleBook }
        hasMOBIHeader = hasHeader
        guard hasHeader else {
            // A plain PalmDOC book: Windows-1252 text, no index, no EXTH.
            encoding = 1252
            version = 0
            fullName = nil
            hasDRM = false
            huffmanFirstRecord = 0
            huffmanRecordCount = 0
            extraDataFlags = 0
            indexRecord = nil
            flowTableRecord = nil
            skeletonIndexRecord = nil
            fragmentIndexRecord = nil
            guideIndexRecord = nil
            exth = [:]
            return
        }

        // The header's length counts from byte 16. A field is in the header
        // only when the header is long enough to hold it; an older, shorter
        // header leaves the later fields out.
        let headerLength = try record0.uint32(20, "The MOBI header's length")
        guard headerLength >= 8, headerLength <= record0.count - Self.mobiMagicOffset else {
            throw MOBIError.damaged("the MOBI header is longer than its record")
        }
        let headerEnd = Self.mobiMagicOffset + headerLength
        /// The 32-bit field at `offset`, or nil when the header ends before it.
        func field(_ offset: Int, _ what: String) throws -> Int? {
            guard headerEnd >= offset + 4 else { return nil }
            return try record0.uint32(offset, what)
        }

        encoding = try field(28, "The text encoding") ?? 1252
        version = try field(36, "The format version") ?? 0
        huffmanFirstRecord = try field(112, "The Huffman table's record") ?? 0
        huffmanRecordCount = try field(116, "The Huffman table's record count") ?? 0
        let exthFlags = try field(128, "The EXTH flags") ?? 0
        // DRM: the offset is 0xFFFFFFFF when there is none.
        hasDRM = (try field(168, "The DRM offset") ?? 0xFFFF_FFFF) != 0xFFFF_FFFF
        // Only the low 16 bits are flags.
        extraDataFlags = (try field(240, "The extra-data flags") ?? 0) & 0xFFFF
        let index = try field(244, "The index record")
        indexRecord = index.flatMap { $0 == 0xFFFF_FFFF ? nil : $0 }
        // The KF8 fields are read only from a header of version 8: in a
        // MOBI 6 header the same bytes are other fields (or padding).
        let isKF8 = version >= 8
        flowTableRecord = isKF8 ? Self.record(try field(192, "The flow table's record")) : nil
        fragmentIndexRecord = isKF8 ? Self.record(try field(248, "The fragment index's record")) : nil
        skeletonIndexRecord = isKF8 ? Self.record(try field(252, "The skeleton index's record")) : nil
        guideIndexRecord = isKF8 ? Self.record(try field(260, "The guide index's record")) : nil

        fullName = Self.fullName(in: record0, encoding: encoding)
        // Bit 6 of the EXTH flags says an EXTH header follows the MOBI header.
        if exthFlags & 0x40 != 0 {
            exth = try Self.exthRecords(in: record0, at: headerEnd)
        } else {
            exth = [:]
        }
    }

    // MARK: Fields

    /// The text of the first value of EXTH `type`, decoded with the book's
    /// encoding, or nil when there is none.
    func exthText(_ type: Int) -> String? {
        exth[type]?.first.map { MOBIText.decode($0, encoding: encoding) }
    }

    /// Every value of EXTH `type` as text (a book may have several authors).
    func exthTexts(_ type: Int) -> [String] {
        (exth[type] ?? []).map { MOBIText.decode($0, encoding: encoding) }
    }

    /// The record number `field` names, or nil when the header has no such
    /// field or it holds 0xFFFFFFFF, which means "none".
    private static func record(_ field: Int?) -> Int? {
        guard let field, field != 0xFFFF_FFFF else { return nil }
        return field
    }

    /// Where the KF8 half of a hybrid file begins (EXTH 121), a record
    /// number counted from the start of the file; nil for a book that names
    /// none.
    var kf8BoundaryRecord: Int? {
        Self.record(exthNumber(EXTHType.kf8Boundary))
    }

    /// The first value of EXTH `type` as a big-endian number, or nil when
    /// there is none or it is not 4 bytes.
    func exthNumber(_ type: Int) -> Int? {
        guard let value = exth[type]?.first, value.count == 4 else { return nil }
        return value.reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: Reading

    /// The full name the header gives (offset at 84, length at 88, both
    /// into record 0), or nil when the header gives none that lies inside
    /// the record. A name is metadata with fallbacks (the EXTH title, the
    /// database name), so a bad one is passed over rather than refused.
    private static func fullName(in record0: MOBIView, encoding: Int) -> String? {
        guard let offset = try? record0.uint32(84, "The title's offset"),
              let length = try? record0.uint32(88, "The title's length"),
              length > 0, let bytes = try? record0.slice(offset, length, "The title") else { return nil }
        return MOBIText.decode(bytes, encoding: encoding)
    }

    /// The EXTH records that follow the MOBI header at `offset` in record 0.
    /// - Throws: `MOBIError.damaged` when the header is not there, or its
    ///   length, count, or a record's length does not fit.
    private static func exthRecords(in record0: MOBIView, at offset: Int) throws -> [Int: [[UInt8]]] {
        guard record0.hasTag("EXTH", at: offset) else {
            throw MOBIError.damaged("the header says there is an EXTH header, and there is not")
        }
        let length = try record0.uint32(offset + 4, "The EXTH header's length")
        let count = try record0.uint32(offset + 8, "The EXTH record count")
        // The header, then `count` records of 8 bytes at least, all inside
        // the record. A count that cannot fit is refused before any loop.
        try record0.require(offset, length, "The EXTH header")
        guard length >= 12, count <= maximumEXTHRecords, count <= (length - 12) / 8 else {
            throw MOBIError.damaged("the EXTH header's record count does not fit its length")
        }

        var records: [Int: [[UInt8]]] = [:]
        var position = offset + 12
        let end = offset + length
        for _ in 0..<count {
            let type = try record0.uint32(position, "An EXTH record's type")
            let recordLength = try record0.uint32(position + 4, "An EXTH record's length")
            guard recordLength >= 8, recordLength <= end - position else {
                throw MOBIError.damaged("an EXTH record's length does not fit the header")
            }
            records[type, default: []].append(try record0.slice(position + 8, recordLength - 8, "An EXTH record"))
            position += recordLength
        }
        return records
    }
}
