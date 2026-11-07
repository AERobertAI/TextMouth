import Foundation

// MARK: - DOCX SAX Parsing

/// Common base for the SAX parsers that read the XML parts of a DOCX
/// package.
///
/// `PackageSAXParser` drives the parse and describes any damage; this class
/// reports a damaged part as `DOCXParserError.malformedXML`, naming it by its
/// path inside the package, so every DOCX caller handles one error type
/// whatever part failed. The pictures Word keeps in `o:gfxdata` attributes,
/// which no reader uses, are taken out before the parser sees the part
/// (`DOCXPictureAttribute`).
class DOCXSAXParser: PackageSAXParser {
    /// Prepare to parse `data`, reporting problems under the part path `file`.
    init(data: Data, file: String) {
        super.init(
            data: DOCXPictureAttribute.removingValues(from: data),
            file: file,
            malformedXMLError: DOCXParserError.malformedXML
        )
    }
}

// MARK: - Pictures in Attributes

/// The `o:gfxdata` attribute, in which Word keeps a drawn shape or group as a
/// base64 ZIP, pictures included (`<v:group … o:gfxdata="…">`): a photo makes
/// it megabytes long. No reader uses it (the shape's text and fallback are
/// read from elsewhere), and `XMLParser` stops, losing every word after it,
/// at an attribute of more than 10 MB (9 MB read, 11 MB stopped), which a photo
/// of about 7.5 MB reaches once encoded. So its value is cut out, leaving
/// `o:gfxdata=""`, in one pass over the bytes before the part is parsed.
enum DOCXPictureAttribute {
    /// The attribute's name as it is written in a start tag.
    private static let name = Array("o:gfxdata".utf8)

    /// `data` with the value of every `o:gfxdata` attribute of a start tag
    /// emptied; `data` itself when it has none, or is not in an encoding that
    /// keeps ASCII's bytes (a UTF-16 or UTF-32 part, which Word does not
    /// write).
    ///
    /// One pass: comments, CDATA sections, processing instructions,
    /// declarations, and end tags are skipped whole, as is the text between
    /// tags, so the words of a document that quote the attribute are kept; a
    /// start tag is read to its `>` outside quotes. An attribute is cut only
    /// when its name is exactly `o:gfxdata` after white space, then `=`, then
    /// a quoted value, so `x:o:gfxdata` and `fo:gfxdata` are left alone. Each
    /// byte is read once (the look back at a name stops at the first byte
    /// that is not white space or the name), so the pass is linear.
    static func removingValues(from data: Data) -> Data {
        // Almost no part has one: look for the name before anything else.
        guard data.count > name.count, data.range(of: Data(name)) != nil,
              !data.starts(with: [0xFF, 0xFE]), !data.starts(with: [0xFE, 0xFF]),
              !(data.count >= 2 && (data[data.startIndex] == 0 || data[data.startIndex + 1] == 0)) else { return data }
        let cuts = data.withUnsafeBytes { raw in valueRanges(in: raw.bindMemory(to: UInt8.self)) }
        guard !cuts.isEmpty else { return data }
        var result = Data()
        result.reserveCapacity(data.count - cuts.reduce(0) { $0 + $1.count })
        var copied = 0
        for cut in cuts {
            result.append(data[data.startIndex + copied ..< data.startIndex + cut.lowerBound])
            copied = cut.upperBound
        }
        result.append(data[data.startIndex + copied ..< data.endIndex])
        return result
    }

    /// Whether `byte` is white space in markup.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Whether `bytes` holds `text` at `index`.
    private static func has(_ text: StaticString, at index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let length = text.utf8CodeUnitCount
        guard index + length <= bytes.count else { return false }
        return text.withUTF8Buffer { expected in
            for offset in 0..<length where bytes[index + offset] != expected[offset] { return false }
            return true
        }
    }

    /// The index just after the first `terminator` at or after `index`, or the end.
    private static func skip(to terminator: StaticString, from index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var i = index
        while i < bytes.count {
            if has(terminator, at: i, in: bytes) { return i + terminator.utf8CodeUnitCount }
            i += 1
        }
        return bytes.count
    }

    /// The byte ranges of the values (between the quotes) of the `o:gfxdata`
    /// attributes of the start tags in `bytes`, in order.
    private static func valueRanges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<") else { i += 1; continue }
            if has("<!--", at: i, in: bytes) {
                i = skip(to: "-->", from: i + 4, in: bytes)
            } else if has("<![CDATA[", at: i, in: bytes) {
                i = skip(to: "]]>", from: i + 9, in: bytes)
            } else if has("<?", at: i, in: bytes) {
                i = skip(to: "?>", from: i + 2, in: bytes)
            } else if has("<!", at: i, in: bytes) || has("</", at: i, in: bytes) {
                i = skip(to: ">", from: i + 2, in: bytes)
            } else {
                i = scanStartTag(from: i + 1, in: bytes, adding: &ranges)
            }
        }
        return ranges
    }

    /// Reads the start tag whose name begins at `index` to its `>` outside
    /// quotes, adding the value range of an `o:gfxdata` attribute to `ranges`,
    /// and returns the index after the tag.
    private static func scanStartTag(from index: Int, in bytes: UnsafeBufferPointer<UInt8>, adding ranges: inout [Range<Int>]) -> Int {
        var j = index
        while j < bytes.count {
            let c = bytes[j]
            if c == UInt8(ascii: ">") { return j + 1 }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                // A quoted value that is not the picture's: to its closing quote.
                j += 1
                while j < bytes.count, bytes[j] != c { j += 1 }
                j += 1
                continue
            }
            if c == UInt8(ascii: "="), namesPicture(endingBefore: j, from: index, in: bytes) {
                var k = j + 1
                while k < bytes.count, isSpace(bytes[k]) { k += 1 }
                if k < bytes.count, bytes[k] == UInt8(ascii: "\"") || bytes[k] == UInt8(ascii: "'") {
                    let quote = bytes[k]
                    let start = k + 1
                    var end = start
                    while end < bytes.count, bytes[end] != quote { end += 1 }
                    if end < bytes.count, end > start { ranges.append(start..<end) }
                    j = end + 1
                    continue
                }
            }
            j += 1
        }
        return j
    }

    /// Whether the name just before the `=` at `equals` (white space allowed
    /// between) is `o:gfxdata`, after white space: the tag's name, which begins
    /// at `tagStart`, is not it.
    private static func namesPicture(endingBefore equals: Int, from tagStart: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var end = equals
        while end > tagStart, isSpace(bytes[end - 1]) { end -= 1 }
        let start = end - name.count
        guard start > tagStart, isSpace(bytes[start - 1]) else { return false }
        for offset in 0..<name.count where bytes[start + offset] != name[offset] { return false }
        return true
    }
}
