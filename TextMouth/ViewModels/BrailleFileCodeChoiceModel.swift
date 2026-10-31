import Combine
import Foundation

// MARK: - The Braille File Characters Pop-up's Model (braillecodes)

/// What Book Information's Braille File Characters pop-up shows and does for
/// one BRF or BRL braille book (braillecodes, research of October 25,
/// section 8.3): the braille file characters its file is read with, as its
/// record keeps them; the codes, with that one selected; the confirmation
/// another asks for; and the re-read, whose refusal the sheet shows and
/// VoiceOver hears. It follows the Text Encoding pop-up's model
/// (`TextEncodingChoiceModel`), whose view, alert, and checks it shares
/// (`BookRereadChoosing`), but nothing is guessed, so the pop-up has no
/// "Automatic" and names each code plainly.
@MainActor
final class BrailleFileCodeChoiceModel: ObservableObject, BookRereadChoosing {
    /// One item of the pop-up.
    enum Item: Hashable, Sendable {
        /// One of the codes this TextMouth reads (`BrailleFileCode.all`).
        case code(BrailleFileCode)
        /// The id of a code this TextMouth does not know, as a later
        /// TextMouth may record: the book's own, listed last only while it
        /// is selected. Choosing it changes nothing.
        case unknown(String)

        /// The item a book's stored code names (`Book.brailleFileCode`):
        /// the code for none, which reads as North American Braille ASCII,
        /// and for an id this TextMouth knows
        /// (`BrailleFileCode.code(forStored:)`); `.unknown` for any other id.
        init(stored: String?) {
            if let code = BrailleFileCode.code(forStored: stored) {
                self = .code(code)
            } else {
                // Only an id this TextMouth does not know names no code, so
                // `stored` is never nil here.
                self = .unknown(stored ?? "")
            }
        }

        /// The words for the item: a code's own name, plainly, since
        /// nothing is guessed ("North American Braille ASCII", and
        /// "Unicode braille patterns", which an import picks by the file's
        /// bytes, alike); an unknown id as
        /// `BrailleFileCodeWording.unknownValue(_:)` says it. The pop-up
        /// lists the item by them, and Speak Info says the book's in the
        /// same words, both from `BrailleFileCodeWording.name(ofStored:)`.
        var name: String {
            switch self {
            case .code(let code):
                return BrailleFileCodeWording.name(ofStored: code.id)
            case .unknown(let id):
                return BrailleFileCodeWording.name(ofStored: id)
            }
        }
    }

    /// A choice the listener has not confirmed yet, with what its
    /// confirmation says of the book besides the new reading
    /// (`BrailleFileCodeWording.confirmMessage(keepsText:stopsEditing:)`).
    typealias Confirmation = RereadConfirmation<BrailleFileCode>

    /// The book's code as stored, by its id, nil for none: the row's at
    /// once, then, from `load()`, the one that stands between the row and
    /// the package record, which a row lagging behind a re-read needs.
    @Published private(set) var storedCode: String?
    /// The choice the listener made and has not confirmed yet, while the
    /// confirmation asks.
    @Published private(set) var pending: Confirmation?
    /// Whether a re-read is under way, which dims the pop-up and the sheet's
    /// buttons, so it cannot start twice nor the sheet close halfway.
    @Published private(set) var isWorking = false
    /// Why the last choice changed nothing, which the sheet shows; nil when
    /// there is nothing to say.
    @Published private(set) var failureMessage: String?

    /// The book whose braille file characters the pop-up shows.
    let bookID: UUID
    /// The library the book is in, which reads it again.
    private let library: LibraryViewModel
    /// How the book's files are reached: the app's, unless a test passes one
    /// that pretends files are in the cloud.
    private let access: MaintenanceFileAccess

    /// The pop-up of `book`, in `library`, showing the code the book's row
    /// stores until `load()` has read its record.
    init(book: Book, library: LibraryViewModel, access: MaintenanceFileAccess = .live) {
        bookID = book.id
        self.library = library
        self.access = access
        storedCode = book.brailleFileCode
    }

    // MARK: The Pop-up

    /// The items, in order: every code, in the catalog's order, then the
    /// book's own code when this TextMouth does not know it.
    var items: [Item] {
        let codes = BrailleFileCode.all.map(Item.code)
        guard case .unknown = selection else { return codes }
        return codes + [selection]
    }

    /// The item shown as selected: the code the book's file is read with.
    var selection: Item {
        Item(stored: storedCode)
    }

    /// The name `item` is listed by (`Item.name`): the selected item's is
    /// the pop-up's value, which VoiceOver speaks before its label and the
    /// button shows, as "North American Braille ASCII".
    func name(of item: Item) -> String {
        item.name
    }

    /// Whether the pop-up takes a choice: not while a re-read is under way.
    var isEnabled: Bool {
        !isWorking
    }

    // MARK: Reading the Stored Code

    /// Reads the code the book's file is read with, off the main actor: the
    /// one that stands between its row and its package record
    /// (`Book.recordedBrailleFileCode()`), the record's whenever it names
    /// one, which is never downloaded for it. A book gone from the library
    /// leaves the pop-up as it is.
    func load() async {
        guard let book = library.bookByID(bookID) else { return }
        storedCode = await OffMainWork.run { book.recordedBrailleFileCode() }
    }

    // MARK: Choosing

    /// The listener chose `item` in the pop-up. Another code is asked about
    /// first (`pending`), with whether text TextMouth did not write will be
    /// kept beside the new reading, read from the book's content.md off the
    /// main actor and never downloaded, and whether Edit Text stops
    /// (`LibraryViewModel.rereadPreflight(of:access:)`). A book that can't be
    /// read again now is not asked about: the sheet says why
    /// (`failureMessage`), and VoiceOver hears it. The code already
    /// selected, and an unknown id, change nothing.
    func choose(_ item: Item) async {
        guard case .code(let code) = item, item != selection, isEnabled else { return }
        failureMessage = nil
        switch await library.rereadPreflight(of: bookID, access: access) {
        case .refused(let refusal):
            failureMessage = OperationFailureNotice.message(after: .failure(refusal))
        case let .ready(keepsText, stopsEditing):
            pending = Confirmation(option: code, keepsText: keepsText, stopsEditing: stopsEditing)
        }
    }

    /// The confirmation's title for `code`, naming the book as the library
    /// knows it: "Read “Ledger” again as Eurobraille, six-dot
    /// (German-speaking countries)?".
    func confirmTitle(for code: BrailleFileCode) -> String {
        BrailleFileCodeWording.confirmTitle(bookTitle: library.bookByID(bookID)?.title ?? "", code: code)
    }

    /// The confirmation's message for `confirmation`: that nothing checks
    /// the choice, and what the re-read changes, an edit of the text kept,
    /// when one will be, and Edit Text stopping, for a book being edited,
    /// included.
    func confirmMessage(for confirmation: Confirmation) -> String {
        BrailleFileCodeWording.confirmMessage(keepsText: confirmation.keepsText, stopsEditing: confirmation.stopsEditing)
    }

    /// The listener confirmed `code`: the book is read again with it
    /// (`LibraryViewModel.readTextAgain(bookID:choosing:access:)`), which
    /// announces what it did; a refusal, such as a file holding a byte the
    /// code has no cell for, is shown, and announced, and the pop-up shows
    /// the code the book is read with afterwards.
    func confirm(_ code: BrailleFileCode) async {
        pending = nil
        failureMessage = nil
        isWorking = true
        let outcome = await library.readTextAgain(bookID: bookID, choosing: .brailleFileCode(code), access: access)
        failureMessage = OperationFailureNotice.message(after: outcome)
        await load()
        isWorking = false
    }

    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel() {
        pending = nil
    }
}
