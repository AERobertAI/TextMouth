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
/// (`BookRereadChoosing`), and whose choice, confirmation, and re-read it
/// runs in the same flow (`RereadChoiceFlow`), but nothing is guessed, so
/// the pop-up has no "Automatic" and names each code plainly.
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
    /// (`BrailleFileCodeWording.confirmMessage(from:to:keepsText:stopsEditing:)`).
    typealias Confirmation = RereadConfirmation<BrailleFileCode>

    /// The book's code as stored, by its id, nil for none: the row's at
    /// once, then, from `load()`, the one that stands between the row and
    /// the package record, which a row lagging behind a re-read needs.
    @Published private(set) var storedCode: String?

    /// The choice, its confirmation, and the re-read, as both re-read
    /// pop-ups run them, with the book, its library, and how its files are
    /// reached. Its changes are this model's, so the views observing the
    /// model redraw (`flowChanges`).
    let flow: RereadChoiceFlow<BrailleFileCode>
    /// Forwards the flow's changes to this model's observers.
    private var flowChanges: AnyCancellable?

    /// The pop-up of `book`, in `library`, showing the code the book's row
    /// stores until `load()` has read its record.
    init(book: Book, library: LibraryViewModel, access: MaintenanceFileAccess = .live) {
        flow = RereadChoiceFlow(bookID: book.id, library: library, access: access)
        storedCode = book.brailleFileCode
        flowChanges = flow.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: The Flow's State

    /// The choice the listener made and has not confirmed yet, while the
    /// confirmation asks (`RereadChoiceFlow.pending`).
    var pending: Confirmation? {
        flow.pending
    }

    /// Whether a re-read is under way, which dims the pop-up and the sheet's
    /// buttons, so it cannot start twice nor the sheet close halfway
    /// (`RereadChoiceFlow.isWorking`).
    var isWorking: Bool {
        flow.isWorking
    }

    /// Why the last choice changed nothing, which the sheet shows; nil when
    /// there is nothing to say (`RereadChoiceFlow.failureMessage`).
    var failureMessage: String? {
        flow.failureMessage
    }

    /// When the pop-up last said or cleared its failure message, in the order
    /// of every pop-up's (`RereadFailureOrder`), so the sheet shows the one
    /// used last.
    var failureStamp: Int {
        flow.failureStamp
    }

    /// The book whose braille file characters the pop-up shows.
    var bookID: UUID {
        flow.bookID
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
        guard let book = flow.library.bookByID(bookID) else { return }
        storedCode = await OffMainWork.run { book.recordedBrailleFileCode() }
    }

    // MARK: Choosing

    /// The listener chose `item` in the pop-up. Another code is asked about
    /// first (`pending`), with whether text TextMouth did not write will be
    /// kept beside the new reading and whether Edit Text stops, or refused,
    /// with the reason shown and announced, for a book that can't be read
    /// again now (`RereadChoiceFlow.choose(_:)`). The code already selected,
    /// an unknown id, and a choice while the pop-up takes none change
    /// nothing.
    func choose(_ item: Item) async {
        guard case .code(let code) = item, item != selection, isEnabled else { return }
        await flow.choose(code)
    }

    /// The confirmation's title for `code`, naming the book as the library
    /// knows it: "Read “Ledger” again as Eurobraille, six-dot
    /// (German-speaking countries)?".
    func confirmTitle(for code: BrailleFileCode) -> String {
        BrailleFileCodeWording.confirmTitle(bookTitle: flow.library.bookByID(bookID)?.title ?? "", code: code)
    }

    /// The confirmation's message for `confirmation`: whether anything
    /// checks the choice, from the code the book is read with now
    /// (`storedCode`) to the one chosen, and what the re-read changes, an
    /// edit of the text kept, when one will be, and Edit Text stopping, for
    /// a book being edited, included.
    func confirmMessage(for confirmation: Confirmation) -> String {
        BrailleFileCodeWording.confirmMessage(
            from: BrailleFileCode.code(forStored: storedCode),
            to: confirmation.option,
            keepsText: confirmation.keepsText,
            stopsEditing: confirmation.stopsEditing
        )
    }

    /// The listener confirmed `code`: the book is read again with it
    /// (`RereadChoiceFlow.confirm(choosing:thenReload:)`), which announces
    /// what it did; a refusal, such as a file holding a byte the code has no
    /// cell for, is shown, and announced, and the pop-up shows the code the
    /// book is read with afterwards (`load()`).
    func confirm(_ code: BrailleFileCode) async {
        await flow.confirm(choosing: .brailleFileCode(code)) { await self.load() }
    }

    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel() {
        flow.cancel()
    }
}
