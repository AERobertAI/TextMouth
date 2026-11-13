import Foundation

// MARK: - The Text Encoding Pop-up's Options (encodingchoice)

/// One of the options of Book Information's Text Encoding pop-up: read the
/// book's file again as an import does, or in one encoding.
enum TextEncodingOption: Hashable, Sendable {
    /// TextMouth's own reading, as at an import: the encoding the file names
    /// (a byte-order mark, valid UTF-8, an HTML declaration), else a guess,
    /// else Windows-1252 (`TextFileDecoder.EncodingPolicy.guess`).
    case automatic
    /// One encoding, by the identifier of the first catalog entry of its
    /// name, or UTF-8 (`TextFileDecoder.utf8Identifier`). The catalog names
    /// Windows' variant of an encoding and the standard it extends alike
    /// ("Shift JIS (Japanese)" for both CP932 and Shift_JIS), so one option
    /// stands for both (`TextEncodingChoices.identifiers(of:)`).
    case encoding(String)
}

/// The options the Text Encoding pop-up offers, and how each is named and
/// read.
enum TextEncodingChoices {
    /// The name of the option that reads the file again as an import does.
    static let automaticName = "Automatic"

    /// Every option, in order: Automatic first, then UTF-8, then each name
    /// of the catalog once, in the catalog's order and named exactly as the
    /// catalog names it (`TextEncodingCatalog.entries`). A name the catalog
    /// gives two entries is offered once, by its first entry.
    static let options: [TextEncodingOption] = {
        var options: [TextEncodingOption] = [.automatic, .encoding(TextFileDecoder.utf8Identifier)]
        var namesOffered: Set<String> = []
        for entry in TextEncodingCatalog.entries where namesOffered.insert(entry.name).inserted {
            options.append(.encoding(entry.identifier))
        }
        return options
    }()

    /// The name the pop-up lists `option` by: "Automatic", "UTF-8", or the
    /// catalog's name.
    static func name(of option: TextEncodingOption) -> String {
        switch option {
        case .automatic:
            return automaticName
        case .encoding(let identifier):
            return TextFileDecoder.chosenEncodingName(forIdentifier: identifier)
        }
    }

    /// The option that stands for the encoding recorded as `identifier`, in
    /// any letter case: UTF-8's, or the option of the catalog's name for it,
    /// which may stand for another entry of the same name ("cp950" is offered
    /// as Big5's option, "big5"). Nil for an encoding no option names.
    static func option(forIdentifier identifier: String) -> TextEncodingOption? {
        TextFileDecoder.chosenEncoding(forIdentifier: identifier).flatMap(option(for:))
    }

    /// The option of the catalog's entry for `encoding`, or UTF-8's; nil for
    /// an encoding no option names (UTF-16, or one an HTML file declares that
    /// the catalog does not hold).
    static func option(for encoding: String.Encoding) -> TextEncodingOption? {
        if encoding == .utf8 {
            return .encoding(TextFileDecoder.utf8Identifier)
        }
        return TextEncodingCatalog.entry(for: encoding).flatMap { option(named: $0.name) }
    }

    /// The option the catalog's name `name` is offered by.
    private static func option(named name: String) -> TextEncodingOption? {
        options.first { option in
            guard case .encoding(let identifier) = option else { return false }
            return TextEncodingCatalog.entry(forIdentifier: identifier)?.name == name
        }
    }

    /// The identifiers a choice of `option` is read in, tried in order until
    /// one reads every byte: every catalog entry of its name, in the
    /// catalog's order, so a Big5 file that uses Windows' extensions is read
    /// in CP950 when Big5 itself refuses it. UTF-8 alone for UTF-8's; none
    /// for Automatic, which does not choose.
    static func identifiers(of option: TextEncodingOption) -> [String] {
        guard case .encoding(let identifier) = option else { return [] }
        guard let entry = TextEncodingCatalog.entry(forIdentifier: identifier) else { return [identifier] }
        return TextEncodingCatalog.entries.filter { $0.name == entry.name }.map(\.identifier)
    }
}

// MARK: - What a Book Is Read In Now

/// The encoding a text book's file is read in now, and what decided it, as
/// Book Information's Text Encoding row shows it: the choice or the guess
/// the book records, or, for a book that records none, what its bytes say.
struct TextEncodingReading: Equatable, Sendable {
    /// What decided the encoding.
    enum Basis: Equatable, Sendable {
        /// The listener chose it.
        case chosen
        /// TextMouth guessed it, at the book's import or when the listener
        /// chose Automatic, and the book records the guess.
        case guessed
        /// The file begins with a byte-order mark.
        case byteOrderMark
        /// The file is UTF-16 or UTF-32 without a byte-order mark,
        /// recognized by the structure of its bytes.
        case unmarkedUnicode
        /// The bytes are valid UTF-8.
        case validUTF8
        /// An HTML file declares it.
        case declared
        /// Nothing in the file says otherwise, so it is read as Windows-1252.
        case defaultEncoding
    }

    /// The pop-up's option for the encoding, nil when no option names it.
    var option: TextEncodingOption?
    /// The encoding's name as a listener hears it.
    var name: String
    /// What decided it.
    var basis: Basis

    /// The reading the book's `record` gives without reading its file: its
    /// choice or its guess; nil when it records neither, and its bytes must
    /// say (`init(decoded:)`).
    init?(record: TextEncodingRecord) {
        guard let identifier = record.identifier else { return nil }
        option = TextEncodingChoices.option(forIdentifier: identifier)
        name = TextFileDecoder.chosenEncodingName(forIdentifier: identifier)
        basis = record.isChosen ? .chosen : .guessed
    }

    /// The reading a decoding of the book's file gives (`DecodedText`).
    init(decoded: DecodedText) {
        option = TextEncodingChoices.option(for: decoded.encoding)
        name = option.map(TextEncodingChoices.name(of:)) ?? TextEncodingWording.name(of: decoded.encoding)
        switch decoded.basis {
        case .chosen: basis = .chosen
        case .byteOrderMark: basis = .byteOrderMark
        case .unmarkedUnicode: basis = .unmarkedUnicode
        case .validUTF8: basis = .validUTF8
        case .declaration: basis = .declared
        case .recorded, .guess: basis = .guessed
        case .fallback: basis = .defaultEncoding
        }
    }

    /// The reading, in words, as VoiceOver speaks the pop-up's value and
    /// Speak Full Info says it: the name, then what decided it, such as
    /// "Windows-1251 (Cyrillic), guessed" (`TextEncodingWording.describe`).
    var description: String {
        TextEncodingWording.describe(name: name, basis: basis)
    }

    /// What `book`'s file is read in now: the choice or the guess its record
    /// holds (`Book.recordedTextEncodingRecord()`), read without the file;
    /// or else what the file's bytes say, read as the book's policy reads
    /// them, with dataless files left in the cloud, so nothing is downloaded
    /// to learn it. A large file is read whole, so this runs off the main
    /// thread, and Book Information shows its row while it does.
    static func current(of book: Book, access: MaintenanceFileAccess = .live) -> TextEncodingRowState {
        let record = book.recordedTextEncodingRecord()
        if let reading = TextEncodingReading(record: record) {
            return .known(reading)
        }
        let file = book.bookFileURL
        guard !access.isInCloud(file) else { return .unknown(TextEncodingWording.inCloudValue) }
        do {
            let decoded = try access.read(file) {
                try TextFileDecoder.decode(Data(contentsOf: file), fileName: file.lastPathComponent, format: book.format, policy: record.policy)
            }
            return .known(TextEncodingReading(decoded: decoded))
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .unknown(TextEncodingWording.inCloudValue)
        } catch {
            return .unknown(TextEncodingWording.unreadableValue)
        }
    }
}

/// What Book Information's Text Encoding row shows of a book's encoding.
enum TextEncodingRowState: Equatable, Sendable {
    /// The book's file is being read to learn what it says
    /// (`TextEncodingReading.current(of:access:)`).
    case checking
    /// What the book is read in now.
    case known(TextEncodingReading)
    /// What it is read in can't be learnt now: the words that say why, as
    /// the pop-up's value.
    case unknown(String)

    /// The pop-up's value, as VoiceOver speaks it: the reading in words, or
    /// why it is not known yet.
    var valueDescription: String {
        switch self {
        case .checking: return TextEncodingWording.checkingValue
        case .known(let reading): return reading.description
        case .unknown(let why): return why
        }
    }
}

// MARK: - Which Books Offer a Choice

extension Book {
    /// Whether Book Information offers this book the Text Encoding pop-up: a
    /// plain-text, Markdown, or HTML book (`BookFormat.usesTextFileDecoder`)
    /// whose file the listener added, which an import notes by where it came
    /// from (`sourceFilePath`), or whose encoding a guess or a choice records
    /// already. Not a feed's article, whose HTML TextMouth writes itself, as
    /// UTF-8; not text typed in (New from Text), which TextMouth writes as
    /// UTF-8 too, with no file it came from; and not a recording, which is
    /// audio.
    var offersTextEncodingChoice: Bool {
        format.usesTextFileDecoder && !isFeedItem && (sourceFilePath != nil || !textEncodingRecord.isEmpty)
    }

    /// Whether Book Information offers this book the choice of the braille
    /// file characters its file is read with (braillecodes): a braille book
    /// whose file is a BRF or a BRL (`BrailleBookReader.kind(of:)`), which
    /// may write its cells in any braille file code (`BrailleFileCode`), and
    /// whose seven-bit codes no byte tells apart. Not a PEF, whose rows are
    /// always Unicode braille patterns, and never a feed's item.
    var offersBrailleFileCodeChoice: Bool {
        format == .braille && !isFeedItem && BrailleBookReader.kind(of: bookFileURL) != .pef
    }

    /// Whether Book Information offers this book the choice of the braille
    /// code its text is read in (`brailleTable`, FMT21): any braille book,
    /// whatever its file (a PEF's cells are translated to print by a table
    /// too), but never a feed's item.
    var offersBrailleTableChoice: Bool {
        format == .braille && !isFeedItem
    }
}
