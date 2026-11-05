import Foundation

// MARK: - Code Pages of Rich Text Format

/// The code pages a Rich Text Format document's bytes (`\'hh`, and raw
/// bytes above 127) are in, and how they are read (FMT47).
///
/// The document names a default code page (`\ansi` is Windows-1252, `\mac`
/// Mac Roman, `\pc` code page 437, `\pca` 850, or `\ansicpgN` for any), and
/// each font of the font table can name a character set (`\fcharsetN`)
/// whose code page applies to the text set in that font. RTF 1.9.1 gives
/// the numbers.
enum RTFEncodings {
    /// Windows-1252, the code page of `\ansi` and the fallback for any code
    /// page this system has no encoding for.
    static let windows1252 = 1252

    /// The code page each `\fcharsetN` of the font table names, for the
    /// character sets that have one of their own. Character set 0 (ANSI) is
    /// Windows-1252 whatever `\ansicpg` says: that is how Windows defines
    /// ANSI_CHARSET, and it is how Word, LibreOffice, and textutil read a
    /// font marked so, even in a document whose default is another code page.
    /// Character sets 1 (default) and 2 (symbol) name none, so the text keeps
    /// the document's code page.
    private static let codePageOfCharset: [Int: Int] = [
        0: 1252,     // ANSI
        77: 10000,   // Mac Roman
        128: 932,    // Shift-JIS
        129: 949,    // Korean (Hangul)
        130: 1361,   // Korean (Johab)
        134: 936,    // Simplified Chinese
        136: 950,    // Traditional Chinese
        161: 1253,   // Greek
        162: 1254,   // Turkish
        163: 1258,   // Vietnamese
        177: 1255,   // Hebrew
        178: 1256,   // Arabic
        186: 1257,   // Baltic
        204: 1251,   // Cyrillic
        222: 874,    // Thai
        238: 1250,   // Eastern European
        254: 437,    // PC (IBM)
        255: 850     // OEM
    ]

    /// The code page that character set `charset` names, or nil when it
    /// names none (so the document's code page applies).
    static func codePage(forCharset charset: Int) -> Int? {
        codePageOfCharset[charset]
    }

    /// The code page the control word `name` (`ansi`, `mac`, `pc`, or `pca`)
    /// sets for the document, or nil for any other word.
    static func codePage(forDocumentWord name: String) -> Int? {
        switch name {
        case "ansi": return windows1252
        case "mac": return 10000
        case "pc": return 437
        case "pca": return 850
        default: return nil
        }
    }

    /// The code pages whose characters are one or two bytes, the second of a
    /// pair possibly in the ASCII range: Shift-JIS (932), GBK (936), Korean
    /// (949), Big5 (950), Johab (1361), the Mac Japanese, Traditional
    /// Chinese, Korean, and Simplified Chinese pages (10001 to 10003 and
    /// 10008), and the EUC and GB 18030 pages. UTF-8 is not listed: every
    /// byte of its multibyte characters is above ASCII.
    private static let multibyteCodePages: Set<Int> = [
        932, 936, 949, 950, 1361, 10001, 10002, 10003, 10008, 20932, 51932, 51936, 51949, 54936
    ]

    /// Whether code page `codePage` has two-byte characters, whose second
    /// byte can be an ASCII byte, so that a run of bytes must be decoded
    /// whole, ASCII bytes included.
    static func isMultibyte(codePage: Int) -> Bool {
        multibyteCodePages.contains(codePage)
    }

    /// The Foundation encoding of Windows code page `codePage`, or nil when
    /// this system knows none (an unknown number in a hostile file).
    /// 65001 is UTF-8 and 1200 UTF-16; CoreFoundation knows the rest.
    static func encoding(forCodePage codePage: Int) -> String.Encoding? {
        switch codePage {
        case 65001: return .utf8
        case 1252: return .windowsCP1252
        case 0...0xFFFF:
            let converted = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
            guard converted != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
        default:
            return nil
        }
    }

    /// The text `bytes` stand for in code page `codePage`.
    ///
    /// A run is decoded whole, so the two bytes of a double-byte character
    /// (`\'83\'41` in Shift-JIS) make one character. A run that is not valid
    /// in its code page (a lone lead byte, or a byte the page leaves
    /// undefined) is read byte by byte as Windows-1252, and a byte that is
    /// undefined there is read as Latin-1, so no byte is dropped and none
    /// is ever an error. An unknown code page is read as Windows-1252.
    static func decode(_ bytes: [UInt8], codePage: Int) -> String {
        guard !bytes.isEmpty else { return "" }
        let encoding = Self.encoding(forCodePage: codePage) ?? .windowsCP1252
        if let text = String(bytes: bytes, encoding: encoding) { return text }
        var text = ""
        for byte in bytes {
            if let single = String(bytes: [byte], encoding: .windowsCP1252) {
                text += single
            } else {
                text.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return text
    }
}
