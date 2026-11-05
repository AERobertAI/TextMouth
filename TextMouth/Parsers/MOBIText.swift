import Foundation

/// The text of a Kindle (MOBI) book: its text records with their trailing
/// entries taken off, decompressed, and joined into the one byte string the
/// book's `filepos` offsets count in.
///
/// Written from the format's specification (the MobileRead wiki's "MOBI"
/// and "PalmDOC" pages), with foliate-js's `mobi.js` (MIT) read as a map of
/// the algorithm: `removeTrailingEntries`, `getVarLenFromEnd`, and
/// `decompressPalmDOC` there are the models of `usableLength(of:flags:)`,
/// `trailingEntrySize(endingAt:in:)`, and `decompressPalmDOC` here. No code
/// is copied; the functions are written again in Swift, with every read
/// checked.
enum MOBIText {

    // MARK: Decoding

    /// `bytes` as text in the book's encoding: UTF-8 for 65001, and
    /// Windows-1252 for 1252 and for anything else, which no book names. A
    /// byte that is not valid becomes U+FFFD (UTF-8) or its Windows-1252
    /// character, so a bad byte costs one character, never the book.
    static func decode(_ bytes: [UInt8], encoding: Int) -> String {
        if encoding == 65001 {
            return String(decoding: bytes, as: UTF8.self)
        }
        return TextFileDecoder.windows1252Text(Data(bytes))
    }

    // MARK: The Text Records

    /// The whole text of the book, the bytes of its text records
    /// decompressed and joined, cut at the length the header declares.
    /// - Throws: `MOBIError.damaged` for a book with fewer records than it
    ///   says hold its text, or a record that does not decompress;
    ///   `MOBIError.unsupportedCompression` for a compression this reader
    ///   does not read (not PalmDOC, HUFF/CDIC, or none);
    ///   `DocumentTooLargeError` for a text that declares
    ///   more than `DocumentByteLimit` allows; `FileImportError.noTextToRead`
    ///   for a book that declares none.
    static func bytes(of database: MOBIPalmDatabase, headers: MOBIHeaders) throws -> [UInt8] {
        let declared = headers.textLength
        guard declared > 0, headers.textRecordCount > 0 else { throw FileImportError.noTextToRead }
        // The decompressed size is held to its declared size, and that to an
        // absolute cap, before any record is read.
        try DocumentByteLimit.check(byteCount: Int64(declared))

        // The records the text lies in follow record 0. A count that passes
        // the records the book has is a truncated book, or a hostile one.
        let lastTextRecord = headers.textRecordCount
        guard lastTextRecord < database.recordCount else {
            throw MOBIError.damaged("it says \(headers.textRecordCount) records hold its text, and it has only \(database.recordCount - 1)")
        }

        let decompress = try decompressor(for: headers, in: database)
        var text: [UInt8] = []
        // Room for what the records can plausibly hold, never for what the
        // header merely claims: a hostile header may claim 64 MB of a file of 4 KB.
        text.reserveCapacity(min(declared, lastTextRecord * 8192))
        for index in 1...lastTextRecord {
            let record = try database.record(index, "A text record")
            let length = try usableLength(of: record, flags: headers.extraDataFlags)
            let bytes = record.bytes
            let start = record.range.lowerBound
            try decompress(bytes, start..<(start + length), &text, declared)
            if text.count >= declared { break }
        }
        // A book may decompress to a little more than it declares (padding
        // in its last record): the declared length is the text. One that
        // decompresses to less has lost part of its text, as a download that
        // stopped short does, and is not read as if it were whole.
        if text.count > declared { text.removeLast(text.count - declared) }
        guard text.count == declared else {
            throw MOBIError.damaged("its text records hold \(text.count) bytes of the \(declared) it says the text has")
        }
        return text
    }

    /// A function that decompresses one record's bytes (`bytes[range]`),
    /// appending to the text so far, which it brings to no more than the
    /// limit it is given, the book's declared length.
    typealias Decompressor = ([UInt8], Range<Int>, inout [UInt8], Int) throws -> Void

    /// The decompressor for the book's compression type.
    /// - Throws: `MOBIError.unsupportedCompression` for a type this reader
    ///   does not read, and `MOBIError.damaged` for HUFF/CDIC tables that do
    ///   not read.
    private static func decompressor(for headers: MOBIHeaders, in database: MOBIPalmDatabase) throws -> Decompressor {
        switch headers.compression {
        case 1:
            // No compression: the record is the text.
            return { bytes, range, output, limit in
                let room = max(0, limit - output.count)
                output.append(contentsOf: bytes[range.lowerBound..<min(range.upperBound, range.lowerBound + room)])
            }
        case 2:
            return { bytes, range, output, limit in
                try decompressPalmDOC(bytes, range, into: &output, limit: limit)
            }
        case 17480:
            // HUFF/CDIC: the tables are read once, then each record is decoded with them.
            let huffman = try MOBIHuffman(
                database: database, firstRecord: headers.huffmanFirstRecord, recordCount: headers.huffmanRecordCount
            )
            return { _, range, output, limit in
                try huffman.decompress(range, into: &output, limit: limit)
            }
        default:
            // No other compression type was ever defined.
            throw MOBIError.unsupportedCompression
        }
    }

    // MARK: Trailing Entries

    /// How many bytes of `record` are text, once the entries the extra-data
    /// flags name are taken off its end: first one entry for each set bit
    /// above bit 0, each of which ends with its own size as a variable-width
    /// number, then, when bit 0 is set, the overlap of a multibyte character
    /// that continues into the next record, `(last byte & 3) + 1` bytes.
    /// - Throws: `MOBIError.damaged` for an entry larger than the record.
    static func usableLength(of record: MOBIView, flags: Int) throws -> Int {
        var length = record.count
        // Each set bit above bit 0 is one entry. They are all taken off the
        // end, so which bit is which does not matter, only how many.
        var entryBits = flags >> 1
        while entryBits != 0 {
            if entryBits & 1 != 0 {
                let size = try trailingEntrySize(endingAt: record.range.lowerBound + length, in: record.bytes, from: record.range.lowerBound)
                guard size >= 1, size <= length else {
                    throw MOBIError.damaged("a text record's trailing entry is larger than the record")
                }
                length -= size
            }
            entryBits >>= 1
        }
        if flags & 1 != 0 {
            guard length > 0 else { throw MOBIError.damaged("a text record is too short for its multibyte overlap") }
            let overlap = Int(record.bytes[record.range.lowerBound + length - 1] & 0b11) + 1
            guard overlap <= length else { throw MOBIError.damaged("a text record is too short for its multibyte overlap") }
            length -= overlap
        }
        return length
    }

    /// The size of the trailing entry that ends at `end` (exclusive) in
    /// `bytes`, which holds nothing of the record before `lowerBound`. The
    /// size is a number of 7-bit groups, most significant first, written so
    /// that it can be read from the end: the group that starts it has its
    /// high bit set, and the size counts the number's own bytes. It is at
    /// most 4 bytes long.
    /// - Throws: `MOBIError.damaged` when no byte in the last four starts a number.
    private static func trailingEntrySize(endingAt end: Int, in bytes: [UInt8], from lowerBound: Int) throws -> Int {
        var value = 0
        var shift = 0
        var position = end - 1
        // Read backward from the last byte, the least significant group.
        while position >= lowerBound, end - position <= 4 {
            let byte = Int(bytes[position])
            value |= (byte & 0x7F) << shift
            if byte & 0x80 != 0 { return value }
            shift += 7
            position -= 1
        }
        throw MOBIError.damaged("a text record's trailing entry has no size")
    }

    // MARK: PalmDOC Compression

    /// Decompresses the PalmDOC (LZ77) record `bytes[range]`, appending to
    /// `output` until the record ends or `output` holds `limit` bytes; any
    /// excess is cut. A byte of the record is one of:
    /// - 0x00 and 0x09...0x7F: itself;
    /// - 0x01...0x08: that many bytes that follow, copied;
    /// - 0x80...0xBF: with the next byte, a 14-bit number whose upper 11
    ///   bits are a distance back into this record's output and whose lower
    ///   3 bits plus 3 are a length to copy;
    /// - 0xC0...0xFF: a space, then the byte with its high bit cleared.
    /// Every back reference is checked: a distance of 0, or one that reaches
    /// before this record's first byte of output, is refused, as is a record
    /// that ends in the middle of a run or a reference.
    /// - Throws: `MOBIError.damaged` for such a record.
    static func decompressPalmDOC(_ bytes: [UInt8], _ range: Range<Int>, into output: inout [UInt8], limit: Int) throws {
        // A reference counts back from the record's own output, never the
        // earlier records'.
        let recordStart = output.count
        var position = range.lowerBound
        let end = range.upperBound
        while position < end, output.count < limit {
            let byte = bytes[position]
            position += 1
            switch byte {
            case 0x00, 0x09...0x7F:
                output.append(byte)
            case 0x01...0x08:
                let count = Int(byte)
                guard count <= end - position else {
                    throw MOBIError.damaged("a compressed text record ends in the middle of a run of letters")
                }
                output.append(contentsOf: bytes[position..<(position + count)])
                position += count
            case 0x80...0xBF:
                guard position < end else {
                    throw MOBIError.damaged("a compressed text record ends in the middle of a repeated phrase")
                }
                let pair = Int(byte) << 8 | Int(bytes[position])
                position += 1
                let distance = (pair & 0x3FFF) >> 3
                let length = (pair & 0b111) + 3
                guard distance >= 1, distance <= output.count - recordStart else {
                    throw MOBIError.damaged("a repeated phrase in a compressed text record points before the start of the record")
                }
                // Copied one byte at a time: the phrase may overlap itself.
                for _ in 0..<length { output.append(output[output.count - distance]) }
            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
            }
        }
        if output.count > limit { output.removeLast(output.count - limit) }
    }
}
