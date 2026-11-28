import Foundation

// MARK: - The Tokens of Rich Text Format

/// One token of a Rich Text Format document (FMT47), as RTF 1.9.1 (Microsoft,
/// 2008, under the Open Specification Promise) defines them.
enum RTFToken: Equatable {
    /// `{`: a group begins.
    case groupStart
    /// `}`: a group ends.
    case groupEnd
    /// A control word such as `\par` or `\fs24`: its name (letters only) and
    /// its numeric parameter, nil when it has none. The parameter is clamped
    /// to the range of a 32-bit integer, so a hostile run of digits never
    /// overflows.
    case controlWord(name: String, parameter: Int?)
    /// A control symbol such as `\~` or `\*`: the one character after the
    /// backslash. (`\'hh` is `.hexByte` and a backslash before a line break
    /// is the control word `par`.)
    case controlSymbol(Character)
    /// `\'hh`: one byte, in the code page that applies where it stands.
    /// Nil when fewer than two hexadecimal digits followed the quote: the
    /// escape is invalid and stands for no byte.
    case hexByte(UInt8?)
    /// A run of text bytes, as the range of the document's bytes that holds
    /// them. Line breaks in the file are not text (RTF ignores them), so a
    /// run never holds one.
    case text(Range<Int>)
}

// MARK: - The Tokenizer

/// Reads the tokens of a Rich Text Format document, one at a time, from its
/// bytes. The document is untrusted input: nothing here recurses, every
/// index is checked against the bytes, and a `\binN` that claims more bytes
/// than remain ends the document instead of being believed.
///
/// It does not know what any control word means, except `\bin`, whose
/// binary data it must skip to stay in step with the document.
struct RTFTokenizer {
    /// The document's bytes.
    let bytes: [UInt8]
    /// The index of the next byte to read.
    private(set) var position = 0

    /// The longest control word name read: the specification allows 32
    /// letters. A longer run of letters is read to its end and keeps its
    /// first 32, which no control word is.
    private static let longestName = 32

    /// The most digits of a parameter that count; further digits are read
    /// and ignored, with the value clamped.
    private static let mostParameterDigits = 10

    /// The largest magnitude a parameter takes.
    private static let parameterLimit = Int(Int32.max)

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Byte classes

    /// Whether `byte` is an ASCII letter (a control word's name).
    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// Whether `byte` is an ASCII digit.
    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    /// The value of the hexadecimal digit `byte`, or nil when it is not one.
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// Whether `byte` ends a run of text: a backslash or a brace. Carriage
    /// returns and line feeds are skipped by the run itself.
    private static func endsText(_ byte: UInt8) -> Bool {
        byte == 0x5C || byte == 0x7B || byte == 0x7D
    }

    // MARK: Reading

    /// The next token, or nil at the end of the document.
    mutating func next() -> RTFToken? {
        // Line breaks and NULs between tokens are ignored by RTF; skip them
        // so a run of text never starts on one.
        while position < bytes.count, [0x0A, 0x0D, 0x00].contains(bytes[position]) {
            position += 1
        }
        guard position < bytes.count else { return nil }
        let byte = bytes[position]
        switch byte {
        case 0x7B:
            position += 1
            return .groupStart
        case 0x7D:
            position += 1
            return .groupEnd
        case 0x5C:
            position += 1
            return readControl()
        default:
            return readText()
        }
    }

    /// A run of text bytes from the current position to the next backslash,
    /// brace, or end. Line breaks inside it are skipped by splitting the
    /// run, which this does by stopping at one: the next call skips it.
    private mutating func readText() -> RTFToken {
        let start = position
        while position < bytes.count {
            let byte = bytes[position]
            if Self.endsText(byte) || byte == 0x0A || byte == 0x0D || byte == 0x00 { break }
            position += 1
        }
        return .text(start..<position)
    }

    /// The token after a backslash: a control word, a hex byte, or a
    /// control symbol. A backslash that ends the document is nothing.
    private mutating func readControl() -> RTFToken? {
        guard position < bytes.count else { return nil }
        let byte = bytes[position]

        if Self.isLetter(byte) {
            return readControlWord()
        }
        position += 1
        switch byte {
        case 0x27:
            // \'hh: two hexadecimal digits. Each digit is taken only if it
            // is one, so an invalid escape never swallows the text after it.
            guard let high = hexDigit() else { return .hexByte(nil) }
            guard let low = hexDigit() else { return .hexByte(nil) }
            return .hexByte(high << 4 | low)
        case 0x0A, 0x0D:
            // A backslash before a line break is a paragraph break (the
            // way Apple's writer ends each paragraph). A CR LF pair is one.
            if byte == 0x0D, position < bytes.count, bytes[position] == 0x0A { position += 1 }
            return .controlWord(name: "par", parameter: nil)
        default:
            return .controlSymbol(Character(Unicode.Scalar(byte)))
        }
    }

    /// Consumes the next byte if it is a hexadecimal digit and returns its
    /// value; consumes nothing and returns nil otherwise.
    private mutating func hexDigit() -> UInt8? {
        guard position < bytes.count, let value = Self.hexValue(bytes[position]) else { return nil }
        position += 1
        return value
    }

    /// A control word: its letters, an optional signed number, and the one
    /// space that ends it, which belongs to the word and is not text.
    private mutating func readControlWord() -> RTFToken {
        let start = position
        while position < bytes.count, Self.isLetter(bytes[position]) {
            position += 1
        }
        // The name is made in one piece, of at most `longestName` letters.
        let name = String(decoding: bytes[start..<min(position, start + Self.longestName)], as: UTF8.self)
        let parameter = readParameter()
        // The single space after a word (or its number) is its delimiter.
        if position < bytes.count, bytes[position] == 0x20 { position += 1 }
        if name == "bin", let count = parameter, count > 0 {
            // \binN is followed by N bytes of binary data that must not be
            // read as RTF. N is held to the bytes that remain.
            position += min(count, bytes.count - position)
        }
        return .controlWord(name: name, parameter: parameter)
    }

    /// The signed decimal parameter at the current position, or nil when
    /// there is none. A minus sign with no digit after it is not a
    /// parameter and is left as text.
    private mutating func readParameter() -> Int? {
        var index = position
        var isNegative = false
        if index < bytes.count, bytes[index] == 0x2D {
            isNegative = true
            index += 1
        }
        guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
        var value = 0
        var digits = 0
        while index < bytes.count, Self.isDigit(bytes[index]) {
            digits += 1
            // Digits past the tenth cannot change a clamped value.
            if digits <= Self.mostParameterDigits {
                value = value * 10 + Int(bytes[index] - 0x30)
            }
            index += 1
        }
        position = index
        value = min(value, Self.parameterLimit)
        return isNegative ? -value : value
    }
}
