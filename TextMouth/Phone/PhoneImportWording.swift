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
        case 1: return "Importing \(names[0])"
        default: return "Importing \(CountWording.books(names.count))"
        }
    }

    // MARK: - Downloading

    /// The progress card's line while a file that is only in iCloud comes
    /// down, before the shared import can read it: "Downloading “Dune”".
    static func downloading(_ name: String) -> String {
        "Downloading “\(name)”"
    }

    /// What VoiceOver says when a download made no progress for the copy's
    /// stall limit, and the copy was cancelled.
    static func downloadFailed(_ name: String) -> String {
        "“\(name)” couldn't be downloaded from iCloud. Check the connection, then add it again."
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
        let subject: String
        if names.count <= namedStoppedImports {
            subject = CountWording.list(names.map { "“\($0)”" })
        } else {
            subject = CountWording.books(names.count)
        }
        let again = names.count == 1 ? "Add it again." : "Add them again."
        return "Importing \(subject) was stopped when TextMouth closed. \(again)"
    }

    // MARK: - What the Phone Can't Import Yet

    /// The next step every refusal gives.
    static let refusalNextStep = "Add it on your Mac, then send the book here."

    /// The refusal of audio the import would convert, which the phone has no
    /// converter for: "“Radio Drama” is in Ogg, which TextMouth on iPhone
    /// can't play yet. Add it on your Mac, then send the book here." `kind`
    /// names the format as `PhoneImportRefusal.audioKindName(of:)` does. A
    /// nil `name` says "This file".
    static func convertedAudioRefusal(_ name: String?, kind: String) -> String {
        "\(subject(name)) is in \(kind), which TextMouth on iPhone can't play yet. \(refusalNextStep)"
    }

    /// The refusal of a Word 6 or Word 95 document, which only textutil
    /// reads: "“Notes” is a Word 6 or Word 95 document, which TextMouth on
    /// iPhone can't read yet. Add it on your Mac, then send the book here."
    static func wordSixOrNinetyFiveRefusal(_ name: String?) -> String {
        "\(subject(name)) is a Word 6 or Word 95 document, which TextMouth on iPhone can't read yet. \(refusalNextStep)"
    }

    /// The refusal of a braille book (BRF, BRL, or PEF), which only the
    /// Mac's braille helper translates: "“Ledger” is a braille file, which
    /// TextMouth on iPhone can't read yet. Add it on your Mac, then send the
    /// book here."
    static func brailleRefusal(_ name: String?) -> String {
        "\(subject(name)) is a braille file, which TextMouth on iPhone can't read yet. \(refusalNextStep)"
    }

    /// A refusal's subject: the name in quotation marks, or "This file"
    /// when no name is known.
    private static func subject(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "This file" }
        return "“\(name)”"
    }

    // MARK: - The Library's Button

    /// The hint of the Library's Add to Library button on the phone, which
    /// offers only what the phone's sheet does (the spec's "The Library's
    /// top", item 11). Its label and title are the Mac's
    /// (`AddToLibraryWording.buttonLabel`).
    static let addToLibraryButtonHint = "Opens a sheet with the ways to add to the library: open a book, or import a folder."
}
