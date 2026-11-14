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
///   Mac Roman, ISO 8859-15, the Central European and Cyrillic encodings, and
///   Windows-1255 for Hebrew), which Foundation's own guesser reads wrongly
///   (it named a Mac Roman file Windows-1251, a KOI8-R file ISO 8859-5, and
///   short Hebrew text Windows-1251);
/// - the encoding Foundation's guess names, when the catalog has it: Greek,
///   Turkish, Hebrew, Arabic, Baltic, Thai, and the Japanese, Chinese, and
///   Korean encodings, which Foundation tells apart well.
///
/// A guess is made only when it can be trusted more than the default, and
/// the rule is that a missed guess costs less than a wrong one: the default
/// is today's reading, and a book that is garbled in it is as garbled as it
/// was, while a guess that is wrong turns text that was right into text that
/// is not, and the book keeps it.
/// - The reading must be nearly free of anomalies and excess uppercase. A
///   rival is judged strictly, and the Windows-1252 reading leniently
///   (`TextPlausibility.Judging`): everything Windows-1252 has is ordinary in
///   its own reading, but is only what decoding made of other bytes in a
///   rival, so a rival cannot look clean by the same characters ("zeige‹bersicht"
///   is Mac Roman's reading of "zeigeÜbersicht").
/// - The default reading must be worse by at least three surprises, at a
///   rate of at least three in a hundred of its non-ASCII characters.
/// - The default reading must show that it is wrong, by more than a rival
///   looking better: anomalies of several different characters, case flips,
///   or dense letters that fit no language where the rival's do
///   (`TextPlausibility.isGarbled(comparedTo:)`). A Windows-1252 text full
///   of curly quotation marks, loanwords, and every strange character
///   Windows-1252 has is not shown wrong by any of them.
/// - No other reading of the bytes may be as good and read differently,
///   unless it is Foundation's own pick between exactly two. A few accented
///   letters in a short file can fit several encodings alike, and then the
///   default stays.
/// - A Hebrew reading is called only when Foundation names Hebrew, whether
///   it stands alone or ties with a Cyrillic one: Hebrew has no case, so its
///   reading is clean of many texts in other encodings (the capitals of
///   KOI8-R are Hebrew letters), and Foundation names short Hebrew
///   Windows-1251. Read always, Hebrew still keeps a Cyrillic reading from
///   being called when it is as clean.
/// - The whole file, not only the part examined, must read in the encoding
///   without a byte dropped or replaced, and write back to the same bytes.
///
/// The limits were tuned on thousands of windows of real prose in 30
/// languages, each converted to the encodings it is written in, and on tens
/// of thousands of Windows-1252 texts built to look odd. None of the texts
/// that Windows-1252 reads right was guessed away from it. Whole paragraphs
/// that it garbles were read right in nearly every case, and about four
/// windows of a few lines in five. The rest were left as they were: texts
/// too short for the oddities to be more than a few, and texts whose
/// Windows-1252 reading is only a few letters off (Hungarian's "ő" and
/// "ű", French "œ" and "€" in Latin 9).
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
        let defaultReading = TextPlausibility(reading: TextFileDecoder.windows1252Text(sample), judging: .windows1252)

        let hint = foundationHint(for: sample)
        var entries = TextEncodingCatalog.entries.filter(\.isAlwaysTried)
        if let hint, !entries.contains(hint) { entries.append(hint) }

        // Every reading of the examined bytes that exists, with its surprises.
        var readings: [Reading] = []
        for entry in entries {
            guard let text = TextFileDecoder.decodedText(sample, in: entry.encoding),
                  !text.unicodeScalars.contains("\u{FFFD}") else { continue }
            readings.append(Reading(entry: entry, text: text, plausibility: TextPlausibility(reading: text, judging: .rival)))
        }
        // The fewest surprises first; readings with as many keep the catalog's order.
        let ranked = readings.enumerated().sortedStably { first, second in
            let (a, b) = (first.element.plausibility.surprise, second.element.plausibility.surprise)
            return a != b ? a < b : first.offset < second.offset
        }.map(\.element)

        for best in ranked {
            let plausibility = best.plausibility
            // The reading itself must be nearly free of anomalies.
            let disorderAllowed = max(1, Int((Double(plausibility.nonASCIICharacters) * maximumDisorderShare).rounded(.down)))
            guard plausibility.disorder <= disorderAllowed else { continue }
            // The default must be clearly worse, and show that it is wrong
            // (`TextPlausibility.isGarbled(comparedTo:)`), or the default stays.
            guard defaultReading.surprise - plausibility.surprise >= minimumGain,
                  defaultReading.surpriseShare >= minimumDefaultSurpriseShare,
                  defaultReading.isGarbled(comparedTo: plausibility) else { return nil }

            guard let chosen = settle(on: best, among: ranked, hint: hint) else { return nil }
            // The whole file must read in it, byte for byte.
            guard let text = TextFileDecoder.decodedText(data, in: chosen.entry.encoding),
                  text.data(using: chosen.entry.encoding, allowLossyConversion: false) == data else { continue }
            return Guess(entry: chosen.entry, text: text)
        }
        return nil
    }

    // MARK: ISO-2022-JP

    /// The guess for a file in ISO-2022-JP, the 7-bit encoding Japanese mail
    /// and older Japanese text files use, which `guess(_:)` cannot find:
    /// every byte of the file is ASCII, so it is valid UTF-8, and read as
    /// UTF-8 its kanji are escape sequences and letters. It is recognized by
    /// its structure instead, as RFC 1468 defines it, with at least one shift
    /// into JIS X 0208 (`TextEncodingByteGrammar.isWellFormedISO2022JP(_:requiringAShift:)`).
    /// Foundation's reader lets a truncated escape or a byte above ASCII
    /// through, so it is not trusted to decide that.
    /// - Returns: nil for any other file.
    static func guessSevenBit(_ data: Data) -> Guess? {
        guard data.contains(0x1B),
              let entry = TextEncodingCatalog.entry(forIdentifier: "iso-2022-jp"),
              TextEncodingByteGrammar.isWellFormedISO2022JP(data, requiringAShift: true),
              let text = TextFileDecoder.decodedText(data, in: entry.encoding),
              !text.unicodeScalars.contains("\u{FFFD}") else { return nil }
        return Guess(entry: entry, text: text)
    }

    /// One reading of the examined bytes in an encoding of the catalog.
    private struct Reading {
        let entry: TextEncodingCatalog.Entry
        let text: String
        let plausibility: TextPlausibility
    }

    /// The identifiers of the Hebrew encodings of the catalog.
    private static let hebrewIdentifiers: Set<String> = ["windows-1255", "iso-8859-8"]

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
        // Hebrew is called only on Foundation's word, alone or in a tie: its
        // letters are bytes that read as clean lowercase Cyrillic, and its
        // reading as clean text in many encodings, for it has no case.
        let involvesHebrew = tied.contains { hebrewIdentifiers.contains($0.entry.identifier) }
        if involvesHebrew, !(hint.map { hebrewIdentifiers.contains($0.identifier) } ?? false) { return nil }
        var chosen = best
        if tied.count > 1 {
            // Foundation's pick decides between exactly two; more are too many to call.
            // The tied reading that reads as the pick does, whichever encoding stands for it.
            guard tied.count == 2, let hint, let picked = ranked.first(where: { $0.entry == hint }),
                  let hinted = tied.first(where: { $0.text == picked.text }) else { return nil }
            chosen = hinted
        }
        // Readings that read the same differ only in name: the hint's, if it is one of them.
        if let hint, chosen.entry != hint,
           let sameText = ranked.first(where: { $0.entry == hint && $0.text == chosen.text }) {
            chosen = sameText
        }
        return chosen
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
    /// than four limits is cut after a byte that ends a character in all of
    /// them (`lastByte(ofLineFrom:to:in:)`).
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
    /// no character is split; for a longer one, the last byte within the
    /// limit that ends a character, or nil when there is none, and the line
    /// is left out.
    private static func lastByte(ofLineFrom lineStart: Int, to lineEnd: Int, in bytes: UnsafeRawBufferPointer) -> Int? {
        guard lineEnd - lineStart + 1 > 4 * sampleLimit else { return lineEnd }
        var cut = lineStart + sampleLimit - 1
        while cut > lineStart, !endsACharacter(bytes[cut]) { cut -= 1 }
        return cut > lineStart ? cut : nil
    }

    /// Whether a character of every encoding the guess reads ends at `byte`:
    /// a byte below 0x40 is never the second byte of a Shift JIS, Big5, GBK,
    /// EUC, or Korean character, whose second bytes are 0x40 and above, with
    /// the exception of the digits, which are the second and fourth bytes of
    /// a four-byte GB18030 character.
    private static func endsACharacter(_ byte: UInt8) -> Bool {
        byte < 0x40 && !(0x30...0x39).contains(byte)
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
