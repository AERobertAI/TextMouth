import Foundation

/// The words the iPhone's importing says that the Mac has no words for, each
/// from the spec's "Importing" and "New words, in one place": what VoiceOver
/// says as an import starts, what the progress card says while a file
/// downloads, and what is said when a download stalls, when an import was
/// stopped by TextMouth closing, and when a file is one the phone can't read.
///
/// Everything else an import says is the Mac's own, called where it lives:
/// `ImportProgressWording`, `ImportDecisionWording`, `AddToLibraryWording`,
/// and `ImportFailure`. Only the iPhone's views and tests use this type, so
/// nothing here changes the Mac.
enum PhoneImportWording {

    // MARK: - Names

    /// What a sentence calls the file or folder at `url`: its name without
    /// its extension, as the book's title will be ("Dune" for Dune.epub).
    /// A name that is only an extension, such as ".epub", is kept whole, so
    /// a sentence never names nothing.
    static func displayName(of url: URL) -> String {
        displayName(ofFileNamed: url.lastPathComponent)
    }

    /// What a sentence calls the file named `fileName`; see `displayName(of:)`.
    static func displayName(ofFileNamed fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    // MARK: - Starting

    /// What VoiceOver says once, as the Add to Library sheet has closed or a
    /// file from another app arrives: "Importing Dune" for one item,
    /// "Importing 3 books" for several. Nil for no item, which says nothing.
    static func importing(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1:
            // Translators: What VoiceOver says once as one file or folder starts to import on the iPhone. %@ is its name, as in "Importing Dune".
            return InterfaceText.line("phoneImport.importing", "Importing \(names[0])")
        default:
            // Translators: What VoiceOver says once as several files or folders start to import on the iPhone. %lld is how many, always two or more.
            return InterfaceText.line("phoneImport.importing.other", "Importing \(number: names.count) books")
        }
    }

    // MARK: - Downloading

    /// The progress card's line while a file that is only in iCloud comes
    /// down, before the shared import can read it: "Downloading “Dune”".
    static func downloading(_ name: String) -> String {
        // Translators: Line of the iPhone's import progress card while a file that is only in iCloud comes down. %@ is the file's name, as in "Downloading “Dune”".
        InterfaceText.line("phoneImport.downloading", "Downloading “\(name)”")
    }

    /// What VoiceOver says when a download made no progress for the copy's
    /// stall limit, and the copy was cancelled.
    static func downloadFailed(_ name: String) -> String {
        // Translators: What VoiceOver says when a file's download from iCloud stalled and the import was cancelled. %@ is the file's name.
        InterfaceText.line("phoneImport.downloadFailed", "“\(name)” couldn't be downloaded from iCloud. Check the connection, then add it again.")
    }

    // MARK: - An Import TextMouth's Closing Stopped

    /// How many names the sentence about stopped imports lists before it
    /// counts them instead, as the Mac's sentence about unanswered
    /// duplicates does (`DuplicateCopyWording.unansweredTrashed(titles:)`).
    static let namedStoppedImports = 3

    /// What VoiceOver says at the next launch when TextMouth closed while
    /// imports ran: "Importing “Dune” was stopped when TextMouth closed. Add
    /// it again." Two or three are named ("Importing “Dune” and “Emma” was
    /// stopped..."), and more are counted ("Importing 5 books was
    /// stopped..."), each ending "Add them again." Nil for none.
    static func stoppedWhenClosed(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        // Each case is a whole sentence, so a language may order it as it likes.
        let stopped: String
        if names.count <= namedStoppedImports {
            let list = CountWording.list(names.map { "“\($0)”" })
            // Translators: First sentence of what VoiceOver says at launch when TextMouth had closed during imports. %@ is the quoted names of one to three files, joined as a list, as in "“Dune” and “Emma”".
            stopped = InterfaceText.line("phoneImport.stoppedWhenClosed.importing", "Importing \(list) was stopped when TextMouth closed.")
        } else {
            // Translators: First sentence of what VoiceOver says at launch when TextMouth had closed during the import of four or more files. %lld is how many.
            stopped = InterfaceText.line("phoneImport.stoppedWhenClosed.books", "Importing \(number: names.count) books was stopped when TextMouth closed.")
        }
        let again = names.count == 1
            // Translators: Last sentence of what VoiceOver says at launch when TextMouth had closed during the import of one file.
            ? InterfaceText.line("phoneImport.stoppedWhenClosed.again", "Add it again.")
            // Translators: Last sentence of what VoiceOver says at launch when TextMouth had closed during the import of several files.
            : InterfaceText.line("phoneImport.stoppedWhenClosed.them", "Add them again.")
        return SentenceWording.joined([stopped, again])
    }

    // MARK: - What the Phone Can't Import Yet

    /// The next step every refusal gives.
    static var refusalNextStep: String {
        // Translators: Last sentence of every refusal of a file the iPhone app can't import yet: the Mac can add it, and the book then comes to the iPhone.
        InterfaceText.line("phoneImport.refusalNextStep", "Add it on your Mac, then send the book here.")
    }

    /// The refusal of audio the import would convert, which the phone has no
    /// converter for: "“Radio Drama” is in Ogg, which TextMouth on iPhone
    /// can't play yet. Add it on your Mac, then send the book here." `kind`
    /// names the format as `PhoneImportRefusal.audioKindName(of:)` does. A
    /// nil `name` says "This file".
    static func convertedAudioRefusal(_ name: String?, kind: String) -> String {
        // Translators: First sentence of the refusal of an audio file the iPhone can't convert. %1$@ is the file's quoted name, or "This file". %2$@ is the audio format's name, as in "Ogg".
        let refusal = InterfaceText.line("phoneImport.convertedAudioRefusal", "\(subject(name)) is in \(kind), which TextMouth on iPhone can't play yet.")
        return SentenceWording.joined([refusal, refusalNextStep])
    }

    /// The refusal of a Word 6 or Word 95 document, which only textutil
    /// reads: "“Notes” is a Word 6 or Word 95 document, which TextMouth on
    /// iPhone can't read yet. Add it on your Mac, then send the book here."
    static func wordSixOrNinetyFiveRefusal(_ name: String?) -> String {
        // Translators: First sentence of the refusal of a Word 6 or Word 95 document, which the iPhone can't read. %@ is the file's quoted name, or "This file".
        let refusal = InterfaceText.line("phoneImport.wordSixOrNinetyFiveRefusal", "\(subject(name)) is a Word 6 or Word 95 document, which TextMouth on iPhone can't read yet.")
        return SentenceWording.joined([refusal, refusalNextStep])
    }

    /// The refusal of a braille book that needs one of a Mac's own braille
    /// tables, `table` by its file name: "“Manuel” needs “fr-bfu-g2.ctb”,
    /// one of a Mac's own braille tables, which TextMouth on iPhone doesn't
    /// have. Add it on your Mac, then send the book here." The Mac has the
    /// table and reads the braille; the book it sends brings its text.
    static func macBrailleTableRefusal(_ name: String?, table: String) -> String {
        // Translators: First sentence of the refusal of a braille book that needs a braille table only a Mac has. %1$@ is the file's quoted name, or "This file". %2$@ is the table's file name, as in "fr-bfu-g2.ctb".
        let refusal = InterfaceText.line("phoneImport.macBrailleTableRefusal", "\(subject(name)) needs “\(table)”, one of a Mac's own braille tables, which TextMouth on iPhone doesn't have.")
        return SentenceWording.joined([refusal, refusalNextStep])
    }

    /// A refusal's subject: the name in quotation marks, or "This file"
    /// when no name is known.
    private static func subject(_ name: String?) -> String {
        guard let name, !name.isEmpty else {
            // Translators: Stands for a file's name at the start of a sentence about refusing it, when no name is known: "This file is in Ogg, which...".
            return InterfaceText.line("phoneImport.subject", "This file")
        }
        return "“\(name)”"
    }

    // MARK: - The Progress Card

    /// The lines the phone's progress card shows under the Mac's title,
    /// "Importing Books", at `now`: while a file is copied, "Downloading
    /// “Dune”" for one coming down from iCloud and otherwise the Mac's first
    /// step, "“Dune”, Reading the file"; once the shared import has it, the
    /// Mac's own lines (`ImportProgressState.lines(at:)`). Empty lines are
    /// left out.
    static func cardLines(copying copy: PhoneImportCopyRun.Status?, state: ImportProgressState, at now: Date) -> [String] {
        if let copy {
            return [copy.isDownloading ? downloading(copy.name) : ImportProgressWording.book(copy.name, step: .readingSource)]
        }
        return state.lines(at: now).filter { !$0.isEmpty }
    }

    /// What VoiceOver reads for the card, when it asks: the Mac's title,
    /// then each line as a sentence, as the Mac's overlay is read.
    static func cardSummary(copying copy: PhoneImportCopyRun.Status?, state: ImportProgressState, at now: Date) -> String {
        ImportProgressWording.spokenStatus(title: ImportProgressWording.title, lines: cardLines(copying: copy, state: state, at: now))
    }

    // MARK: - The Library's Button

    /// The hint of the Library's Add to Library button on the phone, which
    /// offers only what the phone's sheet does (the spec's "The Library's
    /// top", item 11). Its label and title are the Mac's
    /// (`AddToLibraryWording.buttonLabel`).
    static var addToLibraryButtonHint: String {
        // Translators: Hint of the iPhone Library's Add to Library button.
        InterfaceText.line("phoneImport.addToLibraryButtonHint", "Opens options to open a book, import a folder, or add a feed.")
    }

    // MARK: - What the Phone Has Not Yet

    /// The note at the end of the phone's Add to Library sheet, after its two
    /// rows: the Mac's sheet also offers New Recording… and Add Feed…, so a
    /// person looking for them here learns they are the Mac's for now,
    /// rather than wondering whether they are hidden or broken (FR53). Each
    /// feature's iPhone phase shortens it, and the last removes it.
    static var onlyOnTheMacNote: String {
        // Translators: Note at the end of the iPhone's Add to Library sheet, after its choices, saying which features the iPhone app does not have yet and the Mac app does. "For now": they are planned for the iPhone.
        InterfaceText.line("phoneImport.onlyOnTheMacNote", "Recording, editing audio, and transcribing are only on the Mac for now.")
    }
}
