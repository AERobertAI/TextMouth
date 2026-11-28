import Foundation

// MARK: - Summary Information

/// The title and author a Word 97-2003 document names in its
/// SummaryInformation stream, a property set ([MS-OLEPS]) that every Office
/// application writes: a list of numbered properties (2 is the title, 4 the
/// author), each a typed value, the strings in the code page the set names.
///
/// A document's names are a convenience, so reading them never fails: a
/// stream that does not fit the format gives no names. Every offset and
/// length in it is still checked against the stream.
enum WordSummaryInformation {

    /// The property numbers of the title and the author (`PIDSI_TITLE`, `PIDSI_AUTHOR`).
    private static let titleIdentifier = 2
    private static let authorIdentifier = 4
    /// The property that holds the code page of the set's strings.
    private static let codePageIdentifier = 1
    /// The value types of the properties read here.
    private static let integerType = 0x0002
    private static let byteStringType = 0x001E
    private static let wideStringType = 0x001F
    /// The most properties one set is read for, and the longest name kept.
    private static let maximumProperties = 1_000
    private static let maximumNameLength = 4_096

    /// The title and author in the SummaryInformation `stream`, each empty
    /// when the stream names none (or is nil, or is damaged).
    static func names(in stream: Data?) -> (title: String, author: String) {
        guard let stream, let names = try? read(OLEBytes(stream)) else { return ("", "") }
        return names
    }

    /// Reads the names from the first property set of `bytes`.
    private static func read(_ bytes: OLEBytes) throws -> (title: String, author: String) {
        // The stream's header: byte order, version, system, a class ID, and
        // the count of sets; then each set's format ID and offset.
        guard try bytes.u16(0) == 0xFFFE, try bytes.u32(24) >= 1 else { return ("", "") }
        let setStart = try bytes.u32(44)
        // The set: its size, the count of properties, and for each its
        // identifier and its offset in the set.
        let count = min(try bytes.u32(setStart + 4), maximumProperties)
        var codePage = 1252
        var title = ""
        var author = ""
        var strings: [(identifier: Int, offset: Int)] = []
        for index in 0..<count {
            let identifier = try bytes.u32(setStart + 8 + index * 8)
            let offset = setStart + (try bytes.u32(setStart + 12 + index * 8))
            switch identifier {
            case codePageIdentifier:
                if try bytes.u16(offset) == integerType { codePage = try bytes.u16(offset + 4) }
            case titleIdentifier, authorIdentifier:
                strings.append((identifier, offset))
            default:
                break
            }
        }
        // The code page can follow the strings in the set, so the strings are read last.
        for (identifier, offset) in strings {
            let text = clean((try? string(at: offset, codePage: codePage, in: bytes)) ?? "")
            if identifier == titleIdentifier { title = text } else { author = text }
        }
        return (title, author)
    }

    /// The string value at `offset`.
    private static func string(at offset: Int, codePage: Int, in bytes: OLEBytes) throws -> String {
        let type = try bytes.u16(offset)
        let length = try bytes.u32(offset + 4)
        switch type {
        case byteStringType:
            let raw = try bytes.slice(offset: offset + 8, length: min(length, maximumNameLength))
            return decode(Data(raw), codePage: codePage)
        case wideStringType:
            let raw = try bytes.slice(offset: offset + 8, length: min(length, maximumNameLength) * 2)
            let units = stride(from: raw.startIndex, to: raw.endIndex - 1, by: 2).map {
                UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8
            }
            return String(decoding: units, as: UTF16.self)
        default:
            return ""
        }
    }

    /// `data` read in the Windows code page `codePage` (Windows-1252 when the
    /// page is not one this system knows).
    private static func decode(_ data: Data, codePage: Int) -> String {
        if codePage == 65001 { return String(decoding: data, as: UTF8.self) }
        var encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        if encoding == kCFStringEncodingInvalidId { encoding = CFStringConvertWindowsCodepageToEncoding(1252) }
        let native = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        return String(data: data, encoding: native) ?? String(decoding: data, as: UTF8.self)
    }

    /// `text` with every control character, the null that ends a string
    /// among them, taken out, and every run of white space as one space,
    /// trimmed at both ends.
    private static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.properties.generalCategory == .control && !scalar.properties.isWhitespace ? " " : scalar
        }
        return String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
