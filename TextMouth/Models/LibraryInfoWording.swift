import Foundation

// MARK: - Speak Info's Words (October 7, 2026)

/// What Speak Info knows of a book: the facts its sentences are made of,
/// gathered by the Library window as the book's row shows them
/// (`BookInfoFacts.init(_:library:wordsPerMinute:cloudStates:keptBooks:measuresFileSize:)`).
struct BookInfoFacts: Equatable {
    /// The book's title.
    var title: String
    /// The book's author, or the placeholder `Book.unknownAuthor`, which
    /// the sentences leave out.
    var author: String
    /// The format's name as the row shows it: "EPUB", "Audio".
    var format: String
    /// The path of the book's folder, or "" for none.
    var folderPath: String
    /// The reading progress as the row speaks it, "42 percent", or
    /// "Finished" for a book resting at its end (TODO P07), or nil when the
    /// book has no measured position.
    var progress: String?
    /// The time left at the current speed, or nil when it is unknown, and
    /// for a book resting at its end, as its row says it.
    var timeRemaining: TimeInterval?
    /// Whether the book has never been opened.
    var isUnopened: Bool
    /// When the book was added.
    var dateAdded: Date
    /// When the book was last opened, or nil for never.
    var lastOpened: Date?
    /// How many bookmarks the book has.
    var bookmarkCount: Int
    /// The size of the book's file on disk, in bytes, or nil when it is
    /// unknown or was not measured.
    var fileSize: Int64?
    /// The book's cloud note as its row speaks it, "In Cloud", or nil for
    /// none, as in a library on this Mac.
    var cloudNote: String?
    /// Whether the book is kept on this Mac (Keep on This Mac).
    var isKeptOnThisMac: Bool
    /// Whether a reader window has the book open.
    var isOpenInWindow: Bool
    /// Whether the book is kept on this Mac only because it is on the
    /// reading list, which this Mac keeps downloaded, not by the listener's
    /// own choice: Book Information then says "for the reading list".
    var isKeptOnlyForReadingList: Bool = false
    /// The title of the feed an episode or an article in its feed's folder
    /// belongs to (FR11), which Speak Info names where it names a book's
    /// folder; nil for a book of the library's own.
    var feedTitle: String? = nil
    /// The book's place in the reading list, counted as the Reading List
    /// shows it (FR09), or nil for a book not in it.
    var readingListPlace: ReadingListPlace? = nil
    /// The braille code a braille book was imported with, such as "Unified
    /// English Braille, contracted (Grade 2)" (`Book.brailleCodeDescription`,
    /// FMT21), which only the full summary says; nil for every other book.
    var brailleCode: String? = nil
    /// The braille file characters a BRF or BRL braille book's file is read
    /// with, in words, such as "North American Braille ASCII"
    /// (`Book.brailleFileCodeDescription`, braillecodes), which only the full
    /// summary says, right after the braille code; nil for every other book,
    /// a PEF's included.
    var brailleFileCharacters: String? = nil
    /// The encoding a text book's file was guessed to be in, or chosen to be
    /// read in, in words, such as "Windows-1251 (Cyrillic), guessed" or
    /// "Shift JIS (Japanese), chosen" (`Book.textEncodingDescription`, FMT16,
    /// encodingchoice), which only the full summary says; nil for every other
    /// book.
    var textEncoding: String? = nil
}

// MARK: - A Braille Book's Code (FMT21) and File Characters (braillecodes)

extension Book {
    /// The braille code this braille book is read in, in words: the
    /// description of the table it was imported with, or of the default
    /// table for a braille book whose row and record lack one, such as
    /// "Unified English Braille, contracted (Grade 2)"; one of this Mac's
    /// tables also names its language, as "French braille, contracted (Grade
    /// 2), in French" (`BrailleTableCatalog.description(ofTableID:)`). Nil
    /// for a book that is not braille. Book Information and Speak Info both
    /// say it, from this one expression.
    var brailleCodeDescription: String? {
        guard format == .braille else { return nil }
        return BrailleCodeWording.describe(
            BrailleTableCatalog.description(ofTableID: brailleTable ?? BrailleTableCatalog.defaultTableID),
            origin: brailleTableOrigin
        )
    }

    /// The words of Book Information's "Braille Code" row for this book: the
    /// label and the code, which VoiceOver reads as "Braille Code, Unified
    /// English Braille, contracted (Grade 2)". Nil for a book that is not
    /// braille, which has no such row. The sheet draws the row from this, so
    /// a test can pin the words without a hosted sheet.
    var bookInfoBrailleCodeRow: (label: String, value: String)? {
        brailleCodeDescription.map { (BrailleCodeWording.bookInfoLabel, $0) }
    }

    /// The braille file characters this BRF or BRL braille book's file is
    /// read with, in words, as its row stores them (braillecodes): the
    /// code's name for a known id, and North American Braille ASCII's for
    /// none, such as "North American Braille ASCII"; an id this TextMouth
    /// does not know as `BrailleFileCodeWording.unknownValue(_:)` says it.
    /// Nil for a book that offers no such choice
    /// (`offersBrailleFileCodeChoice`): a PEF, whose rows are always Unicode
    /// braille patterns, a feed's item, and every book of another format.
    /// Speak Info says it in the words Book Information's pop-up lists the
    /// code by, both from `BrailleFileCodeWording.name(ofStored:)`, so the
    /// two never differ.
    var brailleFileCodeDescription: String? {
        guard offersBrailleFileCodeChoice else { return nil }
        return BrailleFileCodeWording.name(ofStored: brailleFileCode)
    }
}

/// The words around a braille book's code (FMT21), kept together so a test
/// pins them.
enum BrailleCodeWording {
    /// The label of Book Information's row that names a braille book's code,
    /// and of its pop-up, which reads the book again with another.
    static var bookInfoLabel: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The label of Book Information's row that names a braille book's code, and of its pop-up, which reads the book again with another.
        InterfaceText.line("brailleCode.bookInfoLabel", "Braille Code")
    }

    // MARK: What Chose It (brfguess)

    /// What follows a braille code's name when the import guessed it from the
    /// braille, in the text encoding's word for the same (`TextEncodingWording.guessNote`).
    static var guessedNote: String { TextEncodingWording.guessNote }

    /// The braille code named `name`, as `origin` says who chose it: with
    /// ", guessed" after it for a guess, and as it is otherwise
    /// ("English Braille, American Edition, contracted (Grade 2), guessed").
    /// Book Information's row and pop-up, and Speak Info, all say it so.
    static func describe(_ name: String, origin: BrailleTableOrigin?) -> String {
        guard origin == .guessed else { return name }
        let note = guessedNote
        // Translators: Joins a name and a note about it with a comma, such as an encoding or braille code and "guessed". %1$@ is the name and %2$@ the note.
        return InterfaceText.line("common.nameAndNote", "\(name), \(note)")
    }

    /// What Book Information says under the pop-up of a book whose code the
    /// import guessed: where the code came from, how to correct it, and how
    /// to keep it. Plain and short, so VoiceOver and a braille display read
    /// it as it is.
    static var guessedRecovery: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What Book Information says under the pop-up of a book whose code the import guessed: where the code came from, how to correct it, and how to keep it. Plain and short, so VoiceOver and a braille display read it as it is.
        InterfaceText.line("brailleCode.guessedRecovery", "Guessed from the book's braille. If it reads wrongly, choose Unified English Braille in Braille Code.")
    }
    /// The label of the button under that note that keeps the guessed code
    /// (a pop-up cannot be asked for the choice already selected), and what
    /// it does.
    static var keepGuessLabel: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The label of the button under that note that keeps the guessed code (a pop-up cannot be asked for the choice already selected), and what it does.
        InterfaceText.line("brailleCode.keepGuessLabel", "Keep This Code")
    }
    static var keepGuessHint: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts.
        InterfaceText.line("brailleCode.keepGuessHint", "Stops saying the code was guessed. The book is not read again.")
    }

    /// What VoiceOver hears when the listener keeps a guessed code by
    /// choosing it again: the book and the code, now the listener's own.
    static func keptGuess(bookTitle: String, codeName: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What VoiceOver hears when the listener keeps a guessed code by choosing it again: the book and the code, now the listener's own. Placeholders in order: bookTitle, codeName.
        InterfaceText.line("brailleCode.keptGuess", "“\(bookTitle)” keeps \(codeName).")
    }

    // MARK: The Pop-up

    /// The pop-up's hint, which VoiceOver says after its label and value.
    static var popUpHint: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's hint, which VoiceOver says after its label and value.
        InterfaceText.line("brailleCode.popUpHint", "Choose another braille code to read the book's file again with it.")
    }

    /// Why what would rewrite the text of the braille book titled
    /// `bookTitle` waits while TextMouth reads it again with another braille
    /// code, as the other re-reads' sentences say it
    /// (`TextEncodingWording.readingAgainRefusal(bookTitle:)`,
    /// `BrailleFileCodeWording.readingAgainRefusal(bookTitle:)`).
    static func readingAgainRefusal(bookTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why what would rewrite the text of the braille book titled bookTitle waits while TextMouth reads it again with another braille code, as the other re-reads' sentences say it (TextEncodingWording.readingAgainRefusal(bookTitle:), BrailleFileCodeWording.readingAgainRefusal(bookTitle:)). Placeholders in order: bookTitle.
        InterfaceText.line("brailleCode.readingAgainRefusal", "TextMouth is reading “\(bookTitle)” again with another braille code. Try again when that finishes.")
    }

    // MARK: The Suggestion

    /// What Book Information says under the pop-up of a braille book that is
    /// read as UEB but whose braille shows English Braille, American
    /// Edition's signs (`BrailleCodeDetector`): which code it looks like and
    /// where to choose it. Plain, so that VoiceOver and a braille display read
    /// it as it is.
    static var suggestsEnglishBrailleAmericanEdition: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What Book Information says under the pop-up of a braille book that is read as UEB but whose braille shows English Braille, American Edition's signs (BrailleCodeDetector): which code it looks like and where to choose it. Plain, so that VoiceOver and a braille display read it as it is.
        InterfaceText.line("brailleCode.suggestsAmericanEdition", "This braille looks like English Braille, American Edition. Choose its Braille Code in Book Information.")
    }

    // MARK: The Confirmation

    /// The title of the alert that asks before the book titled `bookTitle`
    /// is read again with the braille code named `codeName`, in the
    /// encoding's sentence (`TextEncodingWording.confirmTitle(bookTitle:readingName:)`):
    /// "Read “Ledger” again as Unified English Braille, uncontracted (Grade
    /// 1)?"
    static func confirmTitle(bookTitle: String, codeName: String) -> String {
        TextEncodingWording.confirmTitle(bookTitle: bookTitle, readingName: codeName)
    }

    /// What the alert says first: the braille is translated to print again
    /// with the code chosen, and nothing can tell whether it is the right
    /// one, since every braille text translates in every table, so a wrong
    /// one reads with no error.
    static var translatedAgainNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What the alert says first: the braille is translated to print again with the code chosen, and nothing can tell whether it is the right one, since every braille text translates in every table, so a wrong one reads with no error.
        InterfaceText.line("brailleCode.translatedAgainNote", "The braille is translated to print again with this code. Nothing checks that it is the right choice. If words read wrongly, choose another.")
    }

    /// The alert's message before a braille book is read again with another
    /// braille code: that the braille is translated again, that the text is
    /// replaced, and what happens to the places (the same sentences as the
    /// braille file characters' alert, without its example); then, as every
    /// re-read alert ends, that an edit of the text is kept, when content.md
    /// holds one (`keepsText`), and that Edit Text stops, for a book being
    /// edited (`stopsEditing`)
    /// (`TextEncodingWording.confirmMessage(_:keepsText:stopsEditing:)`).
    static func confirmMessage(keepsText: Bool, stopsEditing: Bool) -> String {
        TextEncodingWording.confirmMessage(
            [translatedAgainNote, TextEncodingWording.replacedNote, BrailleFileCodeWording.placesNote],
            keepsText: keepsText, stopsEditing: stopsEditing
        )
    }
}

/// The words around the braille file characters a BRF or BRL braille book's
/// file is read with (braillecodes), kept together so a test pins them. A
/// re-read with other braille file characters is the encoding's re-read
/// (`LibraryViewModel.readTextAgain(bookID:choosing:access:)`), so it says
/// what it shares with it in the encoding's words: the refusals of a busy
/// library, a failure, the alert's button and its sentences of what a
/// re-read does to the text, and the announcement once the book is read
/// again (`TextEncodingWording`). Only what differs is here.
enum BrailleFileCodeWording {

    // MARK: Book Information's Pop-up

    /// The label of Book Information's pop-up that names the braille file
    /// characters a BRF or BRL book's file is read with, in title case, as
    /// the sheet's "Braille Code" and "Text Encoding" are; the Settings and
    /// Export pop-ups say "Braille file characters", in their own sentence
    /// case.
    static var bookInfoLabel: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The label of Book Information's pop-up that names the braille file characters a BRF or BRL book's file is read with, in title case, as the sheet's "Braille Code" and "Text Encoding" are; the Settings and Export pop-ups say "Braille file characters", in their own sentence case.
        InterfaceText.line("brailleFileCode.bookInfoLabel", "Braille File Characters")
    }

    /// The pop-up's hint, which VoiceOver says after its label and value.
    static var popUpHint: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's hint, which VoiceOver says after its label and value.
        InterfaceText.line("brailleFileCode.popUpHint", "Choose other characters to read the book's file again with them.")
    }

    /// The pop-up's value, and Speak Info's words, for a book whose stored
    /// code is `id`, which this TextMouth does not know, as a later
    /// TextMouth's may be: "“ascii-braillo-no-047-01”, which this version of
    /// TextMouth can't read".
    static func unknownValue(_ id: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's value, and Speak Info's words, for a book whose stored code is id, which this TextMouth does not know, as a later TextMouth's may be: "“ascii-braillo-no-047-01”, which this version of TextMouth can't read". Placeholders in order: id.
        InterfaceText.line("brailleFileCode.unknownValue", "“\(id)”, which this version of TextMouth can't read")
    }

    /// The braille file characters a book's stored code
    /// (`Book.brailleFileCode`) names, in words: the code's own name for a
    /// known id, plainly, since nothing is guessed; North American Braille
    /// ASCII's for none (nil or empty); and `unknownValue(_:)` for an id this
    /// TextMouth does not know. The one place a stored code becomes words:
    /// Book Information's pop-up lists its items by it
    /// (`BrailleFileCodeChoiceModel.Item.name`), and Speak Info says the
    /// book's (`Book.brailleFileCodeDescription`), so the two never differ.
    static func name(ofStored stored: String?) -> String {
        BrailleFileCode.code(forStored: stored)?.name ?? unknownValue(stored ?? "")
    }

    /// Speak Info's sentence for braille file characters described as
    /// `description` (`Book.brailleFileCodeDescription`), said right after
    /// the braille code's: "Braille characters: North American Braille
    /// ASCII".
    static func speakInfoPart(_ description: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Speak Info's sentence for braille file characters described as description (Book.brailleFileCodeDescription), said right after the braille code's: "Braille characters: North American Braille ASCII". Placeholders in order: description.
        InterfaceText.line("brailleFileCode.speakInfoPart", "Braille characters: \(description)")
    }

    // MARK: The Confirmation

    /// The title of the alert that asks before the book titled `bookTitle`
    /// is read again with `code`, in the encoding's sentence
    /// (`TextEncodingWording.confirmTitle(bookTitle:readingName:)`): "Read
    /// “Ledger” again as Eurobraille, six-dot (German-speaking countries)?"
    static func confirmTitle(bookTitle: String, code: BrailleFileCode) -> String {
        TextEncodingWording.confirmTitle(bookTitle: bookTitle, readingName: code.name)
    }

    /// What the alert says first of a choice between two seven-bit codes:
    /// nothing can tell whether it is right, since every printable ASCII
    /// byte is a cell in every seven-bit code, so a wrong one reads with no
    /// error (research of October 25, section 8.3).
    static var uncheckedNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What the alert says first of a choice between two seven-bit codes: nothing can tell whether it is right, since every printable ASCII byte is a cell in every seven-bit code, so a wrong one reads with no error (research of October 25, section 8.3).
        InterfaceText.line("brailleFileCode.uncheckedNote", "Nothing checks that this is the right choice. If numbers and punctuation sound wrong, choose another.")
    }

    /// What the alert says first of a choice to or from Unicode braille
    /// patterns, which the re-read checks byte by byte before it changes
    /// anything (`BrailleBookReader.requireReadable(_:as:)`), so a wrong one
    /// is refused at its first line (review of October 30, finding 5): a
    /// file not written in the code named `codeName`, the one chosen, is
    /// refused, and nothing changes. "If the file is not written in Unicode
    /// braille patterns, TextMouth refuses it, and nothing changes."
    static func checkedNote(codeName: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What the alert says first of a choice to or from Unicode braille patterns, which the re-read checks byte by byte before it changes anything (BrailleBookReader.requireReadable(_:as:)), so a wrong one is refused at its first line (review of October 30, finding 5): a file not written in the code named codeName, the one chosen, is refused, and nothing changes. "If the file is not written in Unicode braille patterns, TextMouth refuses it, and nothing changes.". Placeholders in order: codeName.
        InterfaceText.line("brailleFileCode.checkedNote", "If the file is not written in \(codeName), TextMouth refuses it, and nothing changes.")
    }

    /// What a re-read does to the book's places, in the encoding's sentence
    /// (`TextEncodingWording.placesSentence(example:)`) without its example
    /// of garbled letters becoming Cyrillic, which is no braille book's.
    static var placesNote: String { TextEncodingWording.placesSentence(example: nil) }

    /// The alert's message before a braille book read with `current`, the
    /// code its stored id names (`BrailleFileCode.code(forStored:)`), is
    /// read again with `chosen`: first whether the choice is checked, then
    /// that the text is replaced, and what happens to the places; then, as
    /// the encoding's alert ends, that an edit of the text is kept, when
    /// content.md holds one (`keepsText`), and that Edit Text stops, for a
    /// book being edited (`stopsEditing`), in the encoding's own sentences
    /// (`TextEncodingWording.confirmMessage(_:keepsText:stopsEditing:)`).
    ///
    /// Only a choice between two seven-bit codes goes unchecked
    /// (`uncheckedNote`). One to or from Unicode braille patterns is refused
    /// unless the file is written in the code chosen (`checkedNote(codeName:)`).
    /// A `current` of nil, an id this TextMouth does not know, counts as
    /// seven-bit: only the code chosen can then make the choice checked.
    static func confirmMessage(
        from current: BrailleFileCode?, to chosen: BrailleFileCode, keepsText: Bool, stopsEditing: Bool
    ) -> String {
        let isChecked = [current, chosen].contains { $0?.kind == .unicodePatterns }
        let check = isChecked ? checkedNote(codeName: chosen.name) : uncheckedNote
        return TextEncodingWording.confirmMessage(
            [check, TextEncodingWording.replacedNote, placesNote], keepsText: keepsText, stopsEditing: stopsEditing
        )
    }

    // MARK: Refusals

    /// Why the book titled `bookTitle` was not read again with the braille
    /// file characters named `codeName`: its file is not braille in them, as
    /// `reason`, the reader's own sentence (`BrailleFileError`), says, and
    /// nothing changed. It has the shape of an encoding's refusal
    /// (`TextEncodingWording.notValidRefusal(bookTitle:encoding:)`):
    /// "“Ledger” can't be read as Eurobraille, six-dot (German-speaking
    /// countries): Line 3 holds the control character U+0007, which is not
    /// Eurobraille. Nothing was changed."
    static func notReadableRefusal(bookTitle: String, codeName: String, reason: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why the book titled bookTitle was not read again with the braille file characters named codeName: its file is not braille in them, as reason, the reader's own sentence (BrailleFileError), says, and nothing changed. It has the shape of an encoding's refusal (TextEncodingWording.notValidRefusal(bookTitle:encoding:)): "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): Line 3 holds the control character U+0007, which is not Eurobraille. Nothing was changed.". Placeholders in order: bookTitle, codeName, reason.
        InterfaceText.line("brailleFileCode.notReadableRefusal", "“\(bookTitle)” can't be read as \(codeName): \(reason) Nothing was changed.")
    }

    /// Why what would rewrite the text of the braille book titled
    /// `bookTitle` waits while TextMouth reads it again with other braille
    /// file characters, as the encoding's sentence says it for any other
    /// book (`TextEncodingWording.readingAgainRefusal(bookTitle:)`): a second
    /// re-read of it, Edit Text, Redo Text Extraction, and Replace Existing
    /// (`LibraryViewModel.readingAgainRefusal(of:)`).
    static func readingAgainRefusal(bookTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why what would rewrite the text of the braille book titled bookTitle waits while TextMouth reads it again with other braille file characters, as the encoding's sentence says it for any other book (TextEncodingWording.readingAgainRefusal(bookTitle:)): a second re-read of it, Edit Text, Redo Text Extraction, and Replace Existing (LibraryViewModel.readingAgainRefusal(of:)). Placeholders in order: bookTitle.
        InterfaceText.line("brailleFileCode.readingAgainRefusal", "TextMouth is reading “\(bookTitle)” again with other braille file characters. Try again when that finishes.")
    }
}

// MARK: - A Text Book's Encoding (FMT16, encodingchoice)

extension Book {
    /// The encoding this text book's file is read in, as its record says,
    /// in words: the encoding's name and who decided it, such as
    /// "Windows-1251 (Cyrillic), guessed" or "Shift JIS (Japanese), chosen"
    /// (`TextEncodingReading.description`). A file whose bytes named no
    /// encoding is read in one TextMouth or the listener chose, which the
    /// listener should be able to learn when a book's accents or letters read
    /// oddly. Nil for a book whose record names no encoding (its file named
    /// one, Windows-1252 read it right, it was imported before guesses were
    /// recorded, or Automatic found nothing to record), and for a book of a
    /// format that has no use for one. Speak Info says it from this one
    /// expression, from the row alone; Book Information shows what the file
    /// says too (`TextEncodingReading.current(of:access:)`).
    var textEncodingDescription: String? {
        guard format.usesTextFileDecoder else { return nil }
        return TextEncodingReading(record: textEncodingRecord)?.description
    }
}

/// The words around a text book's encoding (FMT16) and the listener's choice
/// of it (encodingchoice), kept together so a test pins them. The label names
/// the thing ("Text Encoding", as Speak Info's "Braille code" names a braille
/// book's), and the value says what decided it: a label such as "Read As" is
/// heard as "reed as", the other way to say "read".
enum TextEncodingWording {
    /// The label of Book Information's row, and pop-up, that names the
    /// encoding.
    static var bookInfoLabel: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The label of Book Information's row, and pop-up, that names the encoding.
        InterfaceText.line("textEncoding.bookInfoLabel", "Text Encoding")
    }

    // MARK: What Decided It

    /// What follows the encoding's name when TextMouth guessed it, since the
    /// file did not say it.
    static var guessNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows the encoding's name when TextMouth guessed it, since the file did not say it.
        InterfaceText.line("textEncoding.guessNote", "guessed")
    }
    /// What follows the encoding's name when the listener chose it.
    static var chosenNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows the encoding's name when the listener chose it.
        InterfaceText.line("textEncoding.chosenNote", "chosen")
    }
    /// What follows the name of a Unicode encoding a byte-order mark names.
    static var byteOrderMarkNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows the name of a Unicode encoding a byte-order mark names.
        InterfaceText.line("textEncoding.byteOrderMarkNote", "from its byte order mark")
    }
    /// What follows the name of a Unicode encoding for a file recognized as
    /// UTF-16 or UTF-32 by the structure of its bytes, which has no
    /// byte-order mark.
    static var unmarkedUnicodeNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows the name of a Unicode encoding for a file recognized as UTF-16 or UTF-32 by the structure of its bytes, which has no byte-order mark.
        InterfaceText.line("textEncoding.unmarkedUnicodeNote", "recognized by its bytes")
    }
    /// What follows the name of the encoding an HTML file declares.
    static var declaredNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows the name of the encoding an HTML file declares.
        InterfaceText.line("textEncoding.declaredNote", "declared in the file")
    }
    /// What follows "Windows-1252 (Western European)" for a file whose bytes
    /// say nothing of their encoding and that no guess was made for.
    static var defaultNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What follows "Windows-1252 (Western European)" for a file whose bytes say nothing of their encoding and that no guess was made for.
        InterfaceText.line("textEncoding.defaultNote", "the default")
    }

    /// The encoding named `name`, decided as `basis` says, in words: the
    /// name, then what decided it ("Windows-1251 (Cyrillic), guessed",
    /// "ISO 8859-2 (Central European), declared in the file"); valid UTF-8,
    /// which needs no word, as its name alone ("UTF-8").
    static func describe(name: String, basis: TextEncodingReading.Basis) -> String {
        let note: String?
        switch basis {
        case .chosen: note = chosenNote
        case .guessed: note = guessNote
        case .byteOrderMark: note = byteOrderMarkNote
        case .unmarkedUnicode: note = unmarkedUnicodeNote
        case .validUTF8: note = nil
        case .declared: note = declaredNote
        case .defaultEncoding: note = defaultNote
        }
        guard let note else { return name }
        // Translators: Joins a name and a note about it with a comma, such as an encoding or braille code and "guessed". %1$@ is the name and %2$@ the note.
        return InterfaceText.line("common.nameAndNote", "\(name), \(note)")
    }

    /// The name a listener hears for `encoding`: the catalog's for one of its
    /// own, "UTF-8", the Unicode encodings with their byte order in words
    /// ("UTF-16 (little-endian)"), and any other by its IANA name
    /// (`TextFileDecoder.name(of:)`), such as an encoding an HTML file
    /// declares that the catalog does not hold.
    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The name a listener hears for encoding: the catalog's for one of its own, "UTF-8", the Unicode encodings with their byte order in words ("UTF-16 (little-endian)"), and any other by its IANA name (TextFileDecoder.name(of:)), such as an encoding an HTML file declares that the catalog does not hold. This is the case .utf8.
        case .utf8: return InterfaceText.line("textEncoding.name.utf8", "UTF-8")
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The name a listener hears for encoding: the catalog's for one of its own, "UTF-8", the Unicode encodings with their byte order in words ("UTF-16 (little-endian)"), and any other by its IANA name (TextFileDecoder.name(of:)), such as an encoding an HTML file declares that the catalog does not hold. This is the case .utf16LittleEndian.
        case .utf16LittleEndian: return InterfaceText.line("textEncoding.name.utf16LittleEndian", "UTF-16 (little-endian)")
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The name a listener hears for encoding: the catalog's for one of its own, "UTF-8", the Unicode encodings with their byte order in words ("UTF-16 (little-endian)"), and any other by its IANA name (TextFileDecoder.name(of:)), such as an encoding an HTML file declares that the catalog does not hold. This is the case .utf16BigEndian.
        case .utf16BigEndian: return InterfaceText.line("textEncoding.name.utf16BigEndian", "UTF-16 (big-endian)")
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The name a listener hears for encoding: the catalog's for one of its own, "UTF-8", the Unicode encodings with their byte order in words ("UTF-16 (little-endian)"), and any other by its IANA name (TextFileDecoder.name(of:)), such as an encoding an HTML file declares that the catalog does not hold. This is the case .utf32LittleEndian.
        case .utf32LittleEndian: return InterfaceText.line("textEncoding.name.utf32LittleEndian", "UTF-32 (little-endian)")
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The name a listener hears for encoding: the catalog's for one of its own, "UTF-8", the Unicode encodings with their byte order in words ("UTF-16 (little-endian)"), and any other by its IANA name (TextFileDecoder.name(of:)), such as an encoding an HTML file declares that the catalog does not hold. This is the case .utf32BigEndian.
        case .utf32BigEndian: return InterfaceText.line("textEncoding.name.utf32BigEndian", "UTF-32 (big-endian)")
        default: return TextEncodingCatalog.entry(for: encoding)?.name ?? TextFileDecoder.name(of: encoding)
        }
    }

    /// Speak Info's sentence for an encoding described as `description`
    /// ("Windows-1251 (Cyrillic), guessed"): "Text encoding: Windows-1251
    /// (Cyrillic), guessed".
    static func speakInfoPart(_ description: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Speak Info's sentence for an encoding described as description ("Windows-1251 (Cyrillic), guessed"): "Text encoding: Windows-1251 (Cyrillic), guessed". Placeholders in order: description.
        InterfaceText.line("textEncoding.speakInfoPart", "Text encoding: \(description)")
    }

    // MARK: The Pop-up

    /// The pop-up's hint, which VoiceOver says after its label and value.
    static var popUpHint: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's hint, which VoiceOver says after its label and value.
        InterfaceText.line("textEncoding.popUpHint", "Choose another encoding to read the book's file again in it.")
    }
    /// What Book Information shows, beside a spinner, while the book is read
    /// again (`SheetWorkIndicator`).
    static var workingLabel: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What Book Information shows, beside a spinner, while the book is read again (SheetWorkIndicator).
        InterfaceText.line("textEncoding.workingLabel", "Reading the book again...")
    }

    // MARK: The Pop-up While the File Says Nothing Yet

    /// The pop-up's value while the book's file is read to learn what it
    /// says of its encoding.
    static var checkingValue: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's value while the book's file is read to learn what it says of its encoding.
        InterfaceText.line("textEncoding.checkingValue", "Checking the file")
    }
    /// The pop-up's value for a book that records no encoding and whose file
    /// is only in the cloud, which is never downloaded to learn it.
    static var inCloudValue: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's value for a book that records no encoding and whose file is only in the cloud, which is never downloaded to learn it.
        InterfaceText.line("textEncoding.inCloudValue", "Not known until the book is downloaded")
    }
    /// The pop-up's value for a book that records no encoding and whose file
    /// cannot be read.
    static var unreadableValue: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The pop-up's value for a book that records no encoding and whose file cannot be read.
        InterfaceText.line("textEncoding.unreadableValue", "Not known, since the file can't be read")
    }

    // MARK: The Confirmation

    /// The title of the alert that asks before a book is read again as
    /// `option` says: "Read “Ledger” again as Shift JIS (Japanese)?", or
    /// "Read “Ledger” again automatically?".
    static func confirmTitle(bookTitle: String, option: TextEncodingOption) -> String {
        switch option {
        case .automatic:
            // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The title of the alert that asks before a book is read again as option says: "Read “Ledger” again as Shift JIS (Japanese)?", or "Read “Ledger” again automatically?". Placeholders in order: bookTitle.
            return InterfaceText.line("textEncoding.confirmTitle.automatic", "Read “\(bookTitle)” again automatically?")
        case .encoding:
            return confirmTitle(bookTitle: bookTitle, readingName: TextEncodingChoices.name(of: option))
        }
    }

    /// The title of the alert that asks before the book titled `bookTitle`
    /// is read again as the reading named `readingName`: "Read “Ledger” again
    /// as Shift JIS (Japanese)?". Braille file characters are asked about in
    /// the same sentence (`BrailleFileCodeWording.confirmTitle(bookTitle:code:)`).
    static func confirmTitle(bookTitle: String, readingName: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The title of the alert that asks before the book titled bookTitle is read again as the reading named readingName: "Read “Ledger” again as Shift JIS (Japanese)?". Braille file characters are asked about in the same sentence (BrailleFileCodeWording.confirmTitle(bookTitle:code:)). Placeholders in order: bookTitle, readingName.
        InterfaceText.line("textEncoding.confirmTitle", "Read “\(bookTitle)” again as \(readingName)?")
    }

    /// What Automatic does, as the alert says it before it is chosen.
    static var automaticNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What Automatic does, as the alert says it before it is chosen.
        InterfaceText.line("textEncoding.automaticNote", "TextMouth reads its file as it reads a file you add: in the encoding the file names, or else the one TextMouth finds.")
    }
    /// What any re-read does to the book's text.
    static var replacedNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What any re-read does to the book's text.
        InterfaceText.line("textEncoding.replacedNote", "Its text is replaced by the new reading.")
    }
    /// What the encoding's alert says a re-read does to the book's places
    /// (`placesSentence(example:)`), with garbled letters becoming Cyrillic
    /// as its example.
    static var placesNote: String {
        // Translators: An example inside the sentence about what a re-read does to the listener's place: the places move when none of the old words are left, as when letters read wrongly become Cyrillic.
        placesSentence(example: InterfaceText.line("textEncoding.placesNote", "as when garbled letters become Cyrillic"))
    }

    /// What a re-read does to the book's places (T06), as both re-read
    /// alerts say it, so the two never drift apart (review of October 30,
    /// finding 8): they move with their words. Where none of a place's words
    /// are left, `PlaceRelocator` moves it to about the same point in its
    /// chapter when the two readings share no passage (the very word, for
    /// two encodings of one byte to a character, whose readings are as
    /// long), and otherwise to the edge of the nearest passage they share:
    /// after an English sentence in a Russian book, to the start of the
    /// changed passage that follows it (`TextEncodingRereadTests`).
    /// `example`, when given, says when that happens, as a clause of its own
    /// after "are left": the encoding's alert gives one (`placesNote`), and
    /// the braille file characters' gives none
    /// (`BrailleFileCodeWording.placesNote`), since no braille book's
    /// letters become Cyrillic.
    static func placesSentence(example: String?) -> String {
        // The second sentence has two whole forms, with and without the example.
        let whereNoneAreLeft = example.map { example in
            // Translators: Second sentence of what a re-read does to the listener's place and bookmarks. %@ is an example of when that happens, such as "as when garbled letters become Cyrillic", set between commas.
            InterfaceText.line("textEncoding.placesSentence.whereNoneTheirWords", "Where none of their words are left, \(example), each goes to about the same point in its chapter, or to the nearest passage the two readings share.")
        // Translators: Second sentence of what a re-read does to the listener's place and bookmarks, without an example.
        } ?? InterfaceText.line("textEncoding.placesSentence.whereNoneTheir", "Where none of their words are left, each goes to about the same point in its chapter, or to the nearest passage the two readings share.")
        return SentenceWording.joined([
            // Translators: First sentence of what a re-read does to the listener's place and bookmarks.
            InterfaceText.line("textEncoding.placesSentence.bookmarks", "Your place and bookmarks move with their words."),
            whereNoneAreLeft,
        ])
    }

    /// What a re-read does to text TextMouth did not write, said only for a
    /// book whose content.md holds such text: an edit made with Edit Text,
    /// or a save no edit took, either kept as Replace Existing keeps it
    /// (`ImportDecisionWording.replacingKeepsTextSentence`).
    static var keptTextNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a re-read does to text TextMouth did not write, said only for a book whose content.md holds such text: an edit made with Edit Text, or a save no edit took, either kept as Replace Existing keeps it (ImportDecisionWording.replacingKeepsTextSentence).
        InterfaceText.line("textEncoding.keptTextNote", "An edit of its text is kept beside the new reading, as a copy in the book's package.")
    }
    /// What a re-read does to Edit Text, said only for a book being edited:
    /// the session ends with the re-read, whose new text it never watched
    /// (`BookTextEditWording.stoppedBookReadAgain(bookTitle:)`).
    static var stopsEditingNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a re-read does to Edit Text, said only for a book being edited: the session ends with the re-read, whose new text it never watched (BookTextEditWording.stoppedBookReadAgain(bookTitle:)).
        InterfaceText.line("textEncoding.stopsEditingNote", "Edit Text stops for this book; choose Edit Text again to edit the new reading.")
    }

    /// The alert's message before a book is read again as `option` says:
    /// what Automatic does, for it; that the text is replaced; what happens
    /// to the places; that an edit of the text is kept, when content.md
    /// holds one (`keepsText`); and that Edit Text stops, for a book being
    /// edited (`stopsEditing`).
    static func confirmMessage(option: TextEncodingOption, keepsText: Bool, stopsEditing: Bool) -> String {
        let automatic = option == .automatic ? [automaticNote] : []
        return confirmMessage(automatic + [replacedNote, placesNote], keepsText: keepsText, stopsEditing: stopsEditing)
    }

    /// A re-read alert's message: `notes`, which say what this re-read
    /// does, then that an edit of the text is kept, when content.md holds
    /// one (`keepsText`), and that Edit Text stops, for a book being edited
    /// (`stopsEditing`), one space apart. The encoding's alert and the braille
    /// file characters' (`BrailleFileCodeWording.confirmMessage(from:to:keepsText:stopsEditing:)`)
    /// both end so.
    static func confirmMessage(_ notes: [String], keepsText: Bool, stopsEditing: Bool) -> String {
        var parts = notes
        if keepsText {
            parts.append(keptTextNote)
        }
        if stopsEditing {
            parts.append(stopsEditingNote)
        }
        return SentenceWording.joined(parts)
    }

    /// The alert's button that reads the book again; Cancel leaves it.
    static var confirmButton: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The alert's button that reads the book again; Cancel leaves it.
        InterfaceText.line("textEncoding.confirmButton", "Read Again")
    }

    // MARK: Refusals

    /// Why a book can't be read again while the library's text is being
    /// read again (the launch batch, Redo Text Extraction), in the words
    /// TextMouth uses while its storage work is held (`StorageBusyError`).
    static var extractionRefusal: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why a book can't be read again while the library's text is being read again (the launch batch, Redo Text Extraction), in the words TextMouth uses while its storage work is held (StorageBusyError).
        InterfaceText.line("textEncoding.extractionRefusal", "TextMouth is reading the library's text again. Try again when that finishes.")
    }

    /// Why what would rewrite the text of the book titled `bookTitle` waits
    /// while TextMouth reads it again in another encoding, in the same
    /// words as `extractionRefusal`: a second re-read of it, Edit Text, Redo
    /// Text Extraction, and Replace Existing
    /// (`LibraryViewModel.readingAgainRefusal(of:)`).
    static func readingAgainRefusal(bookTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why what would rewrite the text of the book titled bookTitle waits while TextMouth reads it again in another encoding, in the same words as extractionRefusal: a second re-read of it, Edit Text, Redo Text Extraction, and Replace Existing (LibraryViewModel.readingAgainRefusal(of:)). Placeholders in order: bookTitle.
        InterfaceText.line("textEncoding.readingAgainRefusal", "TextMouth is reading “\(bookTitle)” again in another encoding. Try again when that finishes.")
    }

    /// Why the book titled `bookTitle` can't be read again while it is being
    /// exported, with what to do, as a refusal for a book in use says it
    /// (`FeedBookUse.exporting`): "“Ledger” is being exported. Wait until the
    /// export ends, then try again."
    static func exportingRefusal(bookTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why the book titled bookTitle can't be read again while it is being exported, with what to do, as a refusal for a book in use says it (FeedBookUse.exporting): "“Ledger” is being exported. Wait until the export ends, then try again.". Placeholders in order: bookTitle, FeedBookUse.exporting.remedy, FeedBookUse.tryAgain.
        InterfaceText.line("textEncoding.exportingRefusal", "“\(bookTitle)” is being exported. \(FeedBookUse.exporting.remedy), then \(FeedBookUse.tryAgain).")
    }

    /// Why the book titled `bookTitle` was not read again as `encoding`: its
    /// bytes are not valid in it (`notValid(in:subject:)`), and nothing
    /// changed.
    static func notValidRefusal(bookTitle: String, encoding: String) -> String {
        SentenceWording.joined([
            notValid(in: encoding, subject: RemovalText.quoted(bookTitle)),
            // Translators: Last sentence of a refusal to read a book again: the book and its text are as they were.
            InterfaceText.line("common.nothingWasChanged", "Nothing was changed."),
        ])
    }

    /// Why the book titled `bookTitle` was not read again: the text changed
    /// with Edit Text could not be kept beside the new reading, so nothing
    /// was replaced, as Replace Existing leaves both copies then
    /// (`DuplicateReplacement.TextNotKept`).
    static func editNotKeptRefusal(bookTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why the book titled bookTitle was not read again: the text changed with Edit Text could not be kept beside the new reading, so nothing was replaced, as Replace Existing leaves both copies then (DuplicateReplacement.TextNotKept). Placeholders in order: bookTitle.
        InterfaceText.line("textEncoding.editNotKeptRefusal", "TextMouth couldn't keep the text you changed in “\(bookTitle)” beside the new reading, so it left the book as it was.")
    }

    /// Why the book titled `bookTitle` was not read again: the reading
    /// failed, for `reason` when one was given.
    static func failedRefusal(bookTitle: String, reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            // Translators: Why a book was not read again with another encoding or braille code: the reading failed. %@ is the book's title.
            return InterfaceText.line("textEncoding.failedRefusal.withoutReason", "TextMouth couldn't read “\(bookTitle)” again, so it left the book as it was.")
        }
        // The reason is the reading's own English sentence (question 3).
        // Translators: Why a book was not read again with another encoding or braille code: the reading failed. %1$@ is the book's title and %2$@ is the reason in English, as the reader worded it.
        return InterfaceText.line("textEncoding.failedRefusal.withReason", "TextMouth couldn't read “\(bookTitle)” again, so it left the book as it was: \(reason)")
    }

    /// Why a book that left the library while its Book Information was open
    /// is not read again.
    static var bookGoneRefusal: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why a book that left the library while its Book Information was open is not read again.
        InterfaceText.line("textEncoding.bookGoneRefusal", "The book is no longer in the library, so it was not read again.")
    }

    // MARK: Done

    /// What VoiceOver hears once the book titled `bookTitle` is read again,
    /// now as `readingDescription` says in words: "“Ledger” is now read as
    /// Shift JIS (Japanese), chosen." for an encoding
    /// (`TextEncodingReading.description`), "“Ledger” is now read as
    /// Eurobraille, six-dot (German-speaking countries)." for braille file
    /// characters (`BrailleFileCode.name`, braillecodes), or "“Ledger” was
    /// read again." when what it is read in could not be learnt (its file
    /// went to the cloud as it was read); when text TextMouth did not write
    /// was kept beside it as `keptCopy`, where, in Replace Existing's words
    /// (`BookTextEditWording.earlierTextKept(_:)`); and, when Edit Text was
    /// editing the book (`stoppedEditing`), that it has stopped, in the
    /// words Edit Text says it with
    /// (`BookTextEditWording.stoppedBookReadAgain(bookTitle:)`). One
    /// announcement says it all, so no part cuts another off.
    ///
    /// Its label is not `reading`, as the encoding's form below has it: two
    /// functions told apart only by the type of `reading` could not be
    /// called with `reading: nil`, which Swift could give to either.
    static func readAgainAnnouncement(
        bookTitle: String, readingDescription: String?, keptCopy: URL?, stoppedEditing: Bool = false
    ) -> String {
        var sentences = [readingDescription.map { description in
            // Translators: VoiceOver announcement once a book was read again. %1$@ is the book's title and %2$@ describes how it is read now, such as "Windows-1251 (Cyrillic), chosen".
            InterfaceText.line("textEncoding.sentences", "“\(bookTitle)” is now read as \(description).")
        // Translators: VoiceOver announcement once a book was read again. %@ is the book's title.
        } ?? InterfaceText.line("textEncoding.wasReadAgain", "“\(bookTitle)” was read again.")]
        if let keptCopy {
            sentences.append(BookTextEditWording.earlierTextKept(keptCopy))
        }
        if stoppedEditing {
            sentences.append(BookTextEditWording.stoppedBookReadAgain(bookTitle: bookTitle))
        }
        return SentenceWording.joined(sentences)
    }

    /// What VoiceOver hears once the book titled `bookTitle` is read again,
    /// now in the encoding `reading`, or nil when that could not be learnt:
    /// `readAgainAnnouncement(bookTitle:readingDescription:keptCopy:stoppedEditing:)`
    /// with the reading in its words (`TextEncodingReading.description`).
    static func readAgainAnnouncement(
        bookTitle: String, reading: TextEncodingReading?, keptCopy: URL?, stoppedEditing: Bool = false
    ) -> String {
        readAgainAnnouncement(
            bookTitle: bookTitle, readingDescription: reading?.description, keptCopy: keptCopy, stoppedEditing: stoppedEditing
        )
    }

    // MARK: A Choice That Cannot Be Read (encodingchoice)

    /// Why a file chosen to be read in the encoding named `encoding` was not
    /// read: some of its bytes are not valid in it. `subject` names the file
    /// or the book, as the sentence begins: "“Ledger” can't be read as Shift
    /// JIS (Japanese): it holds bytes that are not valid in that encoding."
    /// The decoder's error (`TextEncodingError.invalidForChosenEncoding`) and
    /// Book Information's refusal both say it from here.
    static func notValid(in encoding: String, subject: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Why a file chosen to be read in the encoding named encoding was not read: some of its bytes are not valid in it. subject names the file or the book, as the sentence begins: "“Ledger” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding." The decoder's error (TextEncodingError.invalidForChosenEncoding) and Book Information's refusal both say it from here. Placeholders in order: subject, encoding.
        InterfaceText.line("textEncoding.notValid", "\(subject) can't be read as \(encoding): it holds bytes that are not valid in that encoding.")
    }

    /// Why a file chosen to be read in an encoding this TextMouth does not
    /// know, recorded as `identifier`, was not read: "The file “Ledger.txt”
    /// is set to be read as “x-cp1999”, a text encoding this version of
    /// TextMouth can't read. Choose another in Book Information."
    static func unknownChoice(_ identifier: String, subject: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of why a book set to an unknown text encoding cannot be read. %1$@ names the book, as in “Ledger”, and %2$@ is the encoding's stored identifier.
            InterfaceText.line("textEncoding.unknownChoice.version", "\(subject) is set to be read as “\(identifier)”, a text encoding this version of TextMouth can't read."),
            // Translators: Last sentence of why a book set to an unknown text encoding cannot be read. "Book Information" is the name of the sheet with the encoding pop-up.
            InterfaceText.line("textEncoding.unknownChoice.information", "Choose another in Book Information."),
        ])
    }
}

/// What Speak Info knows of a folder.
struct FolderInfoFacts: Equatable {
    /// The folder's name.
    var name: String
    /// How many books are in the folder and every folder below it, as its
    /// row counts them.
    var bookCount: Int
    /// How many of those have never been opened.
    var unopenedCount: Int
    /// How many feeds have their folders inside it.
    var feedCount: Int
    /// How many folders it holds directly.
    var subfolderCount: Int
    /// The time left in all its books at the current speed, or nil when
    /// none of them has a known time left.
    var timeRemaining: TimeInterval?
}

/// What Speak Info knows of a feed.
struct FeedInfoFacts: Equatable {
    /// The feed's title.
    var title: String
    /// Its items counted, as its row counts them.
    var counts: FeedItemCounts
    /// Its last check as its row shows it: "Checked today at 3:05 PM".
    var check: String
    /// The path of its folder, or nil when the folder is gone.
    var folderPath: String?
    /// Its address, or nil when the feed's record is gone (an unsubscribed
    /// feed keeps its record, FR11, branch D).
    var address: String?
}

/// What Speak Info knows of a feed's item not downloaded, from its row
/// (returnrow).
struct FeedItemInfoFacts: Equatable {
    /// The row as VoiceOver speaks it (`FeedWording.itemRowLabel(_:)`):
    /// its title, its state, the place kept for it, its date, and its
    /// length.
    var rowLabel: String
    /// What Return and the row's default action do with it, in the row's
    /// hint's words (`FeedWording.itemRowHint(_:keptPlace:)`): "Downloads
    /// it, then opens it".
    var opening: String
    /// The title of its feed, or nil once the feed's record is gone.
    var feedTitle: String?
}

/// The selected row's facts, of whichever kind the row is.
enum LibraryInfoSubject: Equatable {
    case book(BookInfoFacts)
    case folder(FolderInfoFacts)
    case feed(FeedInfoFacts)
    case feedItem(FeedItemInfoFacts)
}

/// The sentences Speak Info speaks (`LibraryInfoSpeaker`): the brief
/// summary for Speak Info, Shift-Command-I, and the full one for Speak
/// Full Info, Shift-Command-I twice (FR12), as Where Am I speaks a
/// position. Pure functions, so every sentence is pinned by a test
/// without a window; counts through
/// `CountWording`, times through `TimeFormatting`, dates through
/// `FeedWording.moment`, and a feed's counts through its row's own phrase,
/// so nothing is spelled twice.
enum LibraryInfoWording {
    /// What a press of Speak Info, or of Return (Open Selected Book), says
    /// when no row is selected.
    static var nothingSelected: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a press of Speak Info, or of Return (Open Selected Book), says when no row is selected.
        InterfaceText.line("common.nothingIsSelected", "Nothing is selected.")
    }
    /// The kind a folder's summary names after the folder's name.
    static var folderKind: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The kind a folder's summary names after the folder's name.
        InterfaceText.line("common.folder", "Folder")
    }
    /// What a book's summary says of a book never opened.
    static var unopenedNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a book's summary says of a book never opened.
        InterfaceText.line("common.unopened", "Unopened")
    }
    /// What a book's summary says of a book in no folder.
    static var noFolderNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a book's summary says of a book in no folder.
        InterfaceText.line("libraryInfo.noFolderNote", "Not in a folder")
    }
    /// What a book's full summary says of a book a reader window has open.
    static var openInWindowNote: String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. What a book's full summary says of a book a reader window has open.
        InterfaceText.line("libraryInfo.openInWindowNote", "Open in a reader window")
    }

    // MARK: Summaries

    /// The brief summary of `subject`.
    static func brief(_ subject: LibraryInfoSubject) -> String {
        switch subject {
        case .book(let book): return sentences(briefParts(of: book))
        case .folder(let folder): return sentences(briefParts(of: folder))
        case .feed(let feed): return sentences(briefParts(of: feed))
        case .feedItem(let item): return sentences(briefParts(of: item))
        }
    }

    /// The full summary of `subject`: the brief one, then the rest. Its
    /// dates read relative to `now`, as "today at 3:05 PM", in `calendar`
    /// and `locale`.
    static func full(
        _ subject: LibraryInfoSubject,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch subject {
        case .book(let book):
            return sentences(briefParts(of: book) + fullParts(of: book, now: now, calendar: calendar, locale: locale))
        case .folder(let folder):
            return sentences(briefParts(of: folder) + fullParts(of: folder))
        case .feed(let feed):
            return sentences(briefParts(of: feed) + fullParts(of: feed))
        case .feedItem(let item):
            return sentences(briefParts(of: item) + fullParts(of: item))
        }
    }

    // MARK: A Book

    /// A book's brief summary, in parts: its title; "By" its author, unless
    /// nothing named one; its format; where it is (`placeNote(of:)`); its
    /// place in the reading list, for a book in it (`readingListNote(_:)`,
    /// FR09); its progress and time left as its row speaks them; and
    /// "Unopened" for a book never opened. Example: "Middlemarch. By George
    /// Eliot. EPUB. In Classics. In reading list, 3 of 12. 42 percent. 2
    /// hours, 5 minutes remaining."; for a finished book, "Dune. By Frank
    /// Herbert. EPUB. In Classics. Finished." (TODO P07).
    static func briefParts(of book: BookInfoFacts) -> [String] {
        var parts = [book.title]
        if !Book.isUnknownAuthor(book.author) {
            let author = book.author
            // Translators: Speak Info: the part of a book's summary that names its author. %@ is the author's name.
            parts.append(InterfaceText.line("libraryInfo.briefParts", "By \(author)"))
        }
        parts.append(book.format)
        parts.append(placeNote(of: book))
        if let place = book.readingListPlace {
            parts.append(readingListNote(place))
        }
        if let progress = book.progress {
            parts.append(progress)
        }
        if let timeLeft = book.timeRemaining {
            parts.append(remaining(timeLeft))
        }
        if book.isUnopened {
            parts.append(unopenedNote)
        }
        return parts
    }

    /// Where a book is, as its brief summary says it: in its feed, for an
    /// episode or an article in its feed's folder, which names no folder of
    /// its own (FR11): "In The Digital Antiquarian, a feed"; otherwise in its
    /// folder, "In Classics", or in none, "Not in a folder".
    static func placeNote(of book: BookInfoFacts) -> String {
        if let feedTitle = book.feedTitle {
            return inFeedNote(feedTitle)
        }
        return book.folderPath.isEmpty ? noFolderNote : inFolderNote(book.folderPath)
    }

    /// "In Fiction/Mystery": where a book is, or where a feed's folder is.
    static func inFolderNote(_ path: String) -> String {
        // Translators: Speak Info: the part of a summary that says where a book or a feed's folder is. %@ is the folder's path, such as Fiction/Mystery.
        InterfaceText.line("libraryInfo.inFolderNote", "In \(path)")
    }

    /// Where an episode or an article is, in the feed titled `feedTitle`:
    /// "In The Digital Antiquarian, a feed".
    static func inFeedNote(_ feedTitle: String) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Where an episode or an article is, in the feed titled feedTitle: "In The Digital Antiquarian, a feed". Placeholders in order: feedTitle.
        InterfaceText.line("libraryInfo.inFeedNote", "In \(feedTitle), a feed")
    }

    /// Where a book in the reading list stands in it, as its brief summary
    /// says it, counted as the Reading List shows the list (FR09): "In
    /// reading list, 3 of 12". Said in every view, the Reading List's own
    /// included, where its rows say no more than the list's order does.
    static func readingListNote(_ place: ReadingListPlace) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. Where a book in the reading list stands in it, as its brief summary says it, counted as the Reading List shows the list (FR09): "In reading list, 3 of 12". Said in every view, the Reading List's own included, where its rows say no more than the list's order does. Placeholders in order: place.position, place.count.
        InterfaceText.line("libraryInfo.readingListNote", "In reading list, \(number: place.position) of \(number: place.count)")
    }

    /// What a book's full summary adds: when it was added and last opened,
    /// its bookmarks counted, its file size when measured, its cloud note
    /// and whether it is kept on this Mac, and whether a reader window has
    /// it open. Example: "Added September 1 at 9:00 AM. Last opened today
    /// at 3:05 PM. 3 bookmarks. File size 1.2 MB. In Cloud. Kept on this
    /// Mac. Open in a reader window." A braille book says its code right
    /// after its bookmarks, and a BRF or BRL book the braille file
    /// characters its file is read with right after that: "3 bookmarks.
    /// Braille code: Unified English Braille, contracted (Grade 2). Braille
    /// characters: North American Braille ASCII. File size 1.2 MB." A text
    /// book whose encoding was guessed, or chosen, says it there too: "3
    /// bookmarks. Text encoding: Windows-1251 (Cyrillic), guessed. File size
    /// 1.2 MB."
    static func fullParts(of book: BookInfoFacts, now: Date, calendar: Calendar, locale: Locale) -> [String] {
        let added = FeedWording.moment(book.dateAdded, now: now, calendar: calendar, locale: locale)
        // Translators: Speak Info: the part of a book's full summary that says when it was added. %@ is a date or time, such as "today" or "3 days ago".
        var parts = [InterfaceText.line("libraryInfo.addedDate", "Added \(added)")]
        if let lastOpened = book.lastOpened {
            let opened = FeedWording.moment(lastOpened, now: now, calendar: calendar, locale: locale)
            // Translators: Speak Info: the part of a book's full summary that says when it was last opened. %@ is a date or time, such as "yesterday".
            parts.append(InterfaceText.line("libraryInfo.fullParts.opened", "Last opened \(opened)"))
        }
        parts.append(CountWording.bookmarks(book.bookmarkCount))
        if let code = book.brailleCode {
            // Translators: Speak Info: the part of a braille book's full summary that names its braille code. %@ is the code's description, such as "Unified English Braille, contracted (Grade 2)".
            parts.append(InterfaceText.line("libraryInfo.fullParts.braille", "Braille code: \(code)"))
        }
        if let characters = book.brailleFileCharacters {
            parts.append(BrailleFileCodeWording.speakInfoPart(characters))
        }
        if let encoding = book.textEncoding {
            parts.append(TextEncodingWording.speakInfoPart(encoding))
        }
        if let size = book.fileSize {
            let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            // Translators: Speak Info: the part of a book's full summary that says how big its file is. %@ is a size such as "2.4 MB".
            parts.append(InterfaceText.line("libraryInfo.fullParts.file", "File size \(bytes)"))
        }
        if let note = book.cloudNote {
            parts.append(note)
        }
        if book.isKeptOnThisMac {
            parts.append(book.isKeptOnlyForReadingList ? KeptOnThisMacNote.forReadingListText : KeptOnThisMacNote.text)
        }
        if book.isOpenInWindow {
            parts.append(openInWindowNote)
        }
        return parts
    }

    // MARK: A Folder

    /// A folder's brief summary, in parts: its name, "Folder", its books
    /// counted with how many are unopened, and its feeds counted when it
    /// has any. Example: "Classics. Folder. 12 books, 3 unopened. 2 feeds."
    static func briefParts(of folder: FolderInfoFacts) -> [String] {
        var parts = [folder.name, folderKind, booksPhrase(of: folder)]
        if let feeds = feedsPhrase(of: folder) {
            parts.append(feeds)
        }
        return parts
    }

    /// What a folder's full summary adds: its subfolders counted when it
    /// has any, and the time left in all its books when any is known.
    /// Example: "2 subfolders. 14 hours, 3 minutes remaining in total."
    static func fullParts(of folder: FolderInfoFacts) -> [String] {
        return [subfoldersPhrase(of: folder), timeRemainingPhrase(of: folder)].compactMap { $0 }
    }

    /// A folder's books counted with how many are unopened. Shared by Speak
    /// Info and the Folder Settings sheet. Example: "12 books, 3 unopened".
    static func booksPhrase(of folder: FolderInfoFacts) -> String {
        let books = CountWording.books(folder.bookCount)
        guard folder.unopenedCount > 0 else { return books }
        let unopened = folder.unopenedCount
        // Translators: Speak Info and Folder Settings: how many books a folder holds and how many of them were never opened. %1$@ is the count of books, such as "12 books", and %2$lld is how many are unopened, a count.
        return InterfaceText.line("libraryInfo.booksPhrase", "\(books), \(number: unopened) unopened")
    }

    /// A folder's feeds counted, or nil when it has none. Example: "2 feeds".
    static func feedsPhrase(of folder: FolderInfoFacts) -> String? {
        guard folder.feedCount > 0 else { return nil }
        return CountWording.feeds(folder.feedCount)
    }

    /// A folder's subfolders counted, or nil when it has none. Example:
    /// "2 subfolders".
    static func subfoldersPhrase(of folder: FolderInfoFacts) -> String? {
        guard folder.subfolderCount > 0 else { return nil }
        let count = folder.subfolderCount
        // Translators: Speak Info and Folder Settings: how many subfolders a folder has. %lld is the number of subfolders, a count.
        return InterfaceText.line("libraryInfo.subfoldersPhrase", "\(number: count) subfolders")
    }

    /// The time left in all of a folder's books, or nil when none is known.
    /// Example: "14 hours, 3 minutes remaining in total".
    static func timeRemainingPhrase(of folder: FolderInfoFacts) -> String? {
        guard let remaining = folder.timeRemaining else { return nil }
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. The time left in all of a folder's books, or nil when none is known. Example: "14 hours, 3 minutes remaining in total". Placeholders in order: TimeFormatting.spoken(remaining).
        return InterfaceText.line("libraryInfo.timeRemainingPhrase", "\(TimeFormatting.spoken(remaining)) remaining in total")
    }

    // MARK: A Feed

    /// A feed's brief summary, in parts: its title, "Feed", "Unsubscribed"
    /// while the listener is unsubscribed from it (FR11, branch D), "Folder
    /// missing" when its folder is gone, its items counted with its row's
    /// own phrase (`FeedWording.countsPhrase`), its size first and its
    /// unplayed items last, and its last check. Example: "Planet Money.
    /// Feed. 10 of 381 episodes listed, 3 downloaded, 2 new, 5 unplayed.
    /// Checked today at 3:05 PM."; "Finish It!. Feed. Unsubscribed. 10 of
    /// 381 episodes listed. Not checked since October 9 at 3:05 PM."
    static func briefParts(of feed: FeedInfoFacts) -> [String] {
        var parts = [feed.title, FeedWording.feedNote]
        if !feed.counts.isSubscribed {
            parts.append(FeedWording.unsubscribedNote)
        }
        if feed.folderPath == nil {
            parts.append(FeedWording.folderMissingNote)
        }
        parts.append(FeedWording.countsPhrase(feed.counts))
        parts.append(feed.check)
        return parts
    }

    /// What a feed's full summary adds: its folder when it has one, and its
    /// address while its record is here. Example: "In Podcasts/Planet
    /// Money. Address https://example.com/feed.xml."
    static func fullParts(of feed: FeedInfoFacts) -> [String] {
        var parts: [String] = []
        if let path = feed.folderPath {
            parts.append(inFolderNote(path))
        }
        if let address = feed.address {
            // Translators: Speak Info: the part of a feed's full summary that gives its web address. %@ is the address.
            parts.append(InterfaceText.line("libraryInfo.fullParts.address", "Address \(address)"))
        }
        return parts
    }

    // MARK: A Feed's Item Not Downloaded

    /// A feed's item's brief summary, in parts (returnrow): what its row
    /// says, then its feed, as an episode's book says its feed
    /// (`inFeedNote(_:)`), unless the feed's record is gone. Example: "The
    /// first visit, Not downloaded, March 3, 5 minutes. In The Tactile
    /// Atlas, a feed."
    static func briefParts(of item: FeedItemInfoFacts) -> [String] {
        [item.rowLabel] + (item.feedTitle.map { [inFeedNote($0)] } ?? [])
    }

    /// What a feed's item's full summary adds: what Return and its row's
    /// default action do with it, "Downloads it, then opens it."
    static func fullParts(of item: FeedItemInfoFacts) -> [String] {
        [item.opening]
    }

    // MARK: Sentences

    /// `remaining` as a row speaks a time left: "2 hours, 5 minutes
    /// remaining".
    static func remaining(_ remaining: TimeInterval) -> String {
        // Translators: Text of Speak Info, Book Information's braille code and text encoding rows, and the re-read alerts. remaining as a row speaks a time left: "2 hours, 5 minutes remaining". Placeholders in order: TimeFormatting.spoken(remaining).
        InterfaceText.line("common.valueRemaining", "\(TimeFormatting.spoken(remaining)) remaining")
    }

    /// `parts` as spoken sentences, joined as `SentenceWording` joins them
    /// (one space apart in English), each ended with a period unless it
    /// ends with one already, or with another mark that ends a sentence, as
    /// a title can and a feed's failure message does. Empty parts are left
    /// out, so a missing fact never becomes an audible pause.
    static func sentences(_ parts: [String]) -> String {
        SentenceWording.joined(parts.filter { !$0.isEmpty }.map { part in
            guard let last = part.last, ".!?…".contains(last) else { return part + "." }
            return part
        })
    }
}
