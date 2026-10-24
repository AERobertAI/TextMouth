import Foundation

// MARK: - Guessing an Encoding

/// Guesses the encoding of a text file whose bytes name none (FMT16): not
/// UTF-8, not a Unicode encoding with a byte-order mark or the zeros of
/// unmarked UTF-16, and not an HTML file that declares one. Until now such
/// bytes were read as Windows-1252 (`TextFileDecoder`'s fallback), which
/// garbled a Mac Roman, Central European, Cyrillic, Japanese, Chinese, or
/// Korean file without a word to the listener.
///
/// The guess is the reading of the bytes that holds the fewest surprises
/// (`TextPlausibility`), among:
/// - Windows-1252, the default, whose reading is the one to beat;
/// - the encodings of the catalog that are always tried (`TextEncodingCatalog`:
///   Mac Roman, ISO 8859-15, the Central European and Cyrillic encodings),
///   which Foundation's own guesser reads wrongly (it named a Mac Roman file
///   Windows-1251, and a KOI8-R file ISO 8859-5);
/// - the encoding Foundation's guess names, when the catalog has it: Greek,
///   Turkish, Hebrew, Arabic, Baltic, Thai, and the Japanese, Chinese, and
///   Korean encodings, which Foundation tells apart well.
///
/// A guess is made only when it can be trusted more than the default:
/// - The reading must be nearly free of anomalies and excess uppercase.
/// - The default reading must be worse by at least three surprises, at a
///   rate of at least three in a hundred of its non-ASCII characters. A text
///   read well in Windows-1252, curly quotation marks and loanwords and
///   all, is never guessed at.
/// - No other reading of the bytes may be as good and read differently,
///   unless it is Foundation's own pick between exactly two. A few accented
///   letters in a short file can fit several encodings alike, and then the
///   default stays.
/// - The whole file, not only the part examined, must read in the encoding
///   without a byte dropped or replaced, and write back to the same bytes.
///
/// The limits below were tuned on thousands of windows of real prose in 30
/// languages, each converted to the encodings it is written in. Reading well
/// in Windows-1252 was never lost to a guess, and the texts it garbled were
/// read right or left as they were, all but a small share of the very short
/// ones (one or two lines), whose few accented letters fit several
/// encodings alike.
enum TextEncodingGuesser {

    /// A guess: the encoding, and the whole file read in it.
    struct Guess: Equatable, Sendable {
        /// The catalog's entry for the encoding.
        let entry: TextEncodingCatalog.Entry
        /// The whole file, read in the encoding.
        let text: String

        /// The encoding the file was read in.
        var encoding: String.Encoding { entry.encoding }
        /// The identifier a book records for it (`Book.textEncoding`).
        var identifier: String { entry.identifier }
    }

    // MARK: Limits

    /// The most bytes of the file examined: whole lines that hold a byte of
    /// 0x80 or more, taken from the start until this many are gathered.
    static let sampleLimit = 64 * 1024

    /// The fewest surprises by which a reading must beat the default.
    static let minimumGain = 3
    /// The smallest share of the default reading's non-ASCII characters its
    /// surprises must be: fewer is a text that merely holds a few oddities.
    static let minimumDefaultSurpriseShare = 0.03
    /// The most anomalies and excess uppercase letters a reading may hold,
    /// as a share of its non-ASCII characters (and always at least one).
    static let maximumDisorderShare = 0.03
    /// The share of the bytes examined that may be control characters (other
    /// than white space and escape) before the file is taken for no text.
    static let maximumControlByteShare = 0.02

    // MARK: Guessing

    /// The guess for `data`, or nil when the Windows-1252 reading stays
    /// (see the type's description).
    static func guess(_ data: Data) -> Guess? {
        guard let sample = examinedBytes(of: data) else { return nil }
        let defaultSurprise = surprises(ofDefaultReadingOf: sample)

        let hint = foundationHint(for: sample)
        var entries = TextEncodingCatalog.entries.filter(\.isAlwaysTried)
        if let hint, !entries.contains(hint) { entries.append(hint) }

        // Every reading of the examined bytes that exists, with its surprises.
        var readings: [Reading] = []
        for entry in entries {
            guard let text = TextFileDecoder.decodedText(sample, in: entry.encoding),
                  !text.unicodeScalars.contains("\u{FFFD}") else { continue }
            readings.append(Reading(entry: entry, text: text, plausibility: TextPlausibility(reading: text)))
        }
        // The fewest surprises first; readings with as many keep the catalog's order.
        let ranked = readings.enumerated().sorted { first, second in
            let (a, b) = (first.element.plausibility.surprise, second.element.plausibility.surprise)
            return a != b ? a < b : first.offset < second.offset
        }.map(\.element)

        for best in ranked {
            let plausibility = best.plausibility
            // The reading itself must be nearly free of anomalies.
            let disorderAllowed = max(1, Int((Double(plausibility.nonASCIICharacters) * maximumDisorderShare).rounded(.down)))
            guard plausibility.disorder <= disorderAllowed else { continue }
            // The default must be clearly worse, or the default stays.
            guard defaultSurprise.gain(over: plausibility.surprise) >= minimumGain,
                  defaultSurprise.isRateAtLeast(minimumDefaultSurpriseShare) else { return nil }

            guard let chosen = settle(on: best, among: ranked, hint: hint) else { return nil }
            // The whole file must read in it, byte for byte.
            guard let text = TextFileDecoder.decodedText(data, in: chosen.entry.encoding),
                  text.data(using: chosen.entry.encoding, allowLossyConversion: false) == data else { continue }
            return Guess(entry: chosen.entry, text: text)
        }
        return nil
    }

    /// One reading of the examined bytes in an encoding of the catalog.
    private struct Reading {
        let entry: TextEncodingCatalog.Entry
        let text: String
        let plausibility: TextPlausibility
    }

    /// The reading to take when `best` has the fewest surprises: `best`
    /// itself, unless other readings that read differently have as few
    /// (`ranked` holds them all). Among readings that read alike the
    /// hint's name, otherwise the catalog's first, is used. Nil when the
    /// tie cannot be settled.
    private static func settle(on best: Reading, among ranked: [Reading], hint: TextEncodingCatalog.Entry?) -> Reading? {
        // The distinct readings that tie with `best`, one for each text.
        var tied: [Reading] = []
        for other in ranked where other.plausibility.surprise == best.plausibility.surprise {
            if !tied.contains(where: { $0.text == other.text }) { tied.append(other) }
        }
        var chosen = best
        if tied.count > 1 {
            // Foundation's pick decides between exactly two; more are too many to call.
            guard tied.count == 2, let hint, let hinted = tied.first(where: { $0.entry == hint }) else { return nil }
            chosen = hinted
        }
        // Readings that read the same differ only in name: the hint's, if it is one of them.
        if let hint, chosen.entry != hint,
           let sameText = ranked.first(where: { $0.entry == hint && $0.text == chosen.text }) {
            chosen = sameText
        }
        return chosen
    }

    // MARK: The Default Reading

    /// The surprises of the default (Windows-1252) reading of the examined
    /// bytes, with what they are measured against.
    private struct DefaultSurprise {
        let surprise: Int
        let nonASCIICharacters: Int

        /// How many surprises fewer than this a reading with `other` has.
        func gain(over other: Int) -> Int { surprise - other }

        /// Whether the surprises are at least `share` of the non-ASCII characters.
        func isRateAtLeast(_ share: Double) -> Bool {
            nonASCIICharacters > 0 && Double(surprise) / Double(nonASCIICharacters) >= share
        }
    }

    /// The surprises of reading `sample` as Windows-1252.
    private static func surprises(ofDefaultReadingOf sample: Data) -> DefaultSurprise {
        let plausibility = TextPlausibility(reading: TextFileDecoder.windows1252Text(sample))
        return DefaultSurprise(surprise: plausibility.surprise, nonASCIICharacters: plausibility.nonASCIICharacters)
    }

    // MARK: Foundation's Guess

    /// The catalog's entry for the encoding Foundation's own guesser names
    /// for `sample`, or nil when it names none, Windows-1252 or another
    /// that the default stands for, or one the catalog does not hold.
    private static func foundationHint(for sample: Data) -> TextEncodingCatalog.Entry? {
        var converted: NSString?
        var usedLossyConversion = ObjCBool(false)
        let raw = NSString.stringEncoding(
            for: sample, encodingOptions: nil, convertedString: &converted, usedLossyConversion: &usedLossyConversion
        )
        guard raw != 0,
              let entry = TextEncodingCatalog.entry(for: String.Encoding(rawValue: raw)),
              entry.identifier != TextEncodingCatalog.windows1252Identifier else { return nil }
        return entry
    }

    // MARK: Sampling

    /// The part of a file the guess examines: the lines of `data` that hold
    /// a byte of 0x80 or more, taken in order until `sampleLimit` bytes are
    /// gathered; nil when there is none, or when more than
    /// `maximumControlByteShare` of what is gathered is control characters,
    /// which no text holds. A line ends at a line feed or a carriage return,
    /// which no multi-byte encoding the guess reads uses inside a
    /// character, so a line is never cut inside one; a single line longer
    /// than four limits is cut at a byte below 0x40, which no such encoding
    /// uses inside a character either (`lastByte(ofLineFrom:to:in:)`).
    private static func examinedBytes(of data: Data) -> Data? {
        var gathered = Data()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var lineStart = 0
            var holdsHighByte = false
            for index in bytes.indices {
                let byte = bytes[index]
                if byte >= 0x80 { holdsHighByte = true }
                guard byte == 0x0A || byte == 0x0D || index == bytes.count - 1 else { continue }
                if holdsHighByte, let lineEnd = lastByte(ofLineFrom: lineStart, to: index, in: bytes) {
                    gathered.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[lineStart...lineEnd]))
                    if gathered.count >= sampleLimit { return }
                }
                lineStart = index + 1
                holdsHighByte = false
            }
        }
        guard !gathered.isEmpty else { return nil }
        let controls = gathered.reduce(0) { $1.isTextControl ? $0 + 1 : $0 }
        return Double(controls) <= Double(gathered.count) * maximumControlByteShare ? gathered : nil
    }

    /// The index of the last byte to take of the line that runs from
    /// `lineStart` to `lineEnd`: `lineEnd` itself for a line of up to four
    /// limits, which ends at a line ending or at the end of the file, where
    /// no character is split; for a longer one, the last byte below 0x40
    /// within the limit, or nil when there is none, and the line is left out.
    private static func lastByte(ofLineFrom lineStart: Int, to lineEnd: Int, in bytes: UnsafeRawBufferPointer) -> Int? {
        guard lineEnd - lineStart + 1 > 4 * sampleLimit else { return lineEnd }
        var cut = lineStart + sampleLimit - 1
        while cut > lineStart, bytes[cut] >= 0x40 { cut -= 1 }
        return cut > lineStart ? cut : nil
    }
}

// MARK: - Control Bytes

private extension UInt8 {
    /// Whether the byte is a control character that text does not hold:
    /// below 0x20 but not tab, line feed, vertical tab, form feed, carriage
    /// return, or escape; or delete.
    var isTextControl: Bool {
        if self == 0x7F { return true }
        guard self < 0x20 else { return false }
        return !((0x09...0x0D).contains(self) || self == 0x1B)
    }
}
