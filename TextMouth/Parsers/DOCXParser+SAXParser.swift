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
            malformedXMLError: DOCXParserError.malformedXML,
            refusedXMLError: DOCXParserError.unsafeXML
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
///
/// The pass is `XMLInputGuard.walkStartTags`, the scan the guard counts
/// attributes with: comments, CDATA sections, processing instructions,
/// declarations, end tags, and the text between tags are skipped, so the words
/// of a document that quote the attribute are kept, and a start tag is read to
/// its `>` outside quotes.
enum DOCXPictureAttribute {
    /// The attribute's name as it is written in a start tag.
    private static let name = Array("o:gfxdata".utf8)

    /// `data` with the value of every `o:gfxdata` attribute of a start tag
    /// emptied; `data` itself when it has none, or is not in an encoding that
    /// keeps ASCII's bytes (a UTF-16 or UTF-32 part, which Word does not
    /// write). An attribute is cut only when its name is exactly `o:gfxdata`
    /// after white space, then `=`, then a quoted value, so `x:o:gfxdata` and
    /// `fo:gfxdata` are left alone. Each byte is read once (the look back at
    /// a name stops at the first byte that is not white space or the name), so
    /// the pass is linear.
    static func removingValues(from data: Data) -> Data {
        // Almost no part has one: look for the name before anything else.
        guard data.count > name.count, data.range(of: Data(name)) != nil else { return data }
        let cuts = data.withUnsafeBytes { raw -> [Range<Int>] in
            let units = XMLInputGuard.CodeUnits(raw.bindMemory(to: UInt8.self))
            // The cut ranges are byte offsets, which are code units only in a one-byte shape.
            guard units.width == 1 else { return [] }
            return valueRanges(in: units)
        }
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

    /// Whether `unit` is white space in markup.
    private static func isSpace(_ unit: UInt8) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    /// The byte ranges of the values (between the quotes) of the `o:gfxdata`
    /// attributes of the start tags of `units`, in order.
    private static func valueRanges(in units: XMLInputGuard.CodeUnits) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        XMLInputGuard.walkStartTags(
            in: units,
            begin: { _ in },
            attribute: { equals, nameStart in
                guard namesPicture(endingBefore: equals, from: nameStart, in: units) else { return .proceed }
                var k = equals + 1
                while k < units.count, isSpace(units.unit(k)) { k += 1 }
                guard k < units.count, units.unit(k) == UInt8(ascii: "\"") || units.unit(k) == UInt8(ascii: "'") else {
                    return .proceed
                }
                let quote = units.unit(k)
                let start = k + 1
                var end = start
                while end < units.count, units.unit(end) != quote { end += 1 }
                if end < units.count, end > start { ranges.append((units.start + start)..<(units.start + end)) }
                return .continueAt(end + 1)
            })
        return ranges
    }

    /// Whether the name just before the `=` at `equals` (white space allowed
    /// between) is `o:gfxdata`, after white space: the tag's name, which begins
    /// at `nameStart`, is not it.
    private static func namesPicture(endingBefore equals: Int, from nameStart: Int, in units: XMLInputGuard.CodeUnits) -> Bool {
        var end = equals
        while end > nameStart, isSpace(units.unit(end - 1)) { end -= 1 }
        let start = end - name.count
        guard start > nameStart, isSpace(units.unit(start - 1)) else { return false }
        for offset in 0..<name.count where units.unit(start + offset) != name[offset] { return false }
        return true
    }
}
