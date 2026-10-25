import SwiftUI

// MARK: - The Text Encoding Pop-up's Model (encodingchoice)

/// What Book Information's Text Encoding pop-up shows and does for one book
/// (encodingchoice): what the book is read in now, worked out without making
/// the sheet wait on a large file; the options, with that encoding selected;
/// the confirmation a new option asks for; and the re-read, whose refusal
/// the sheet shows and VoiceOver hears.
@MainActor
final class TextEncodingChoiceModel: ObservableObject {
    /// One item of the pop-up.
    enum Item: Hashable {
        /// One of the options (`TextEncodingChoices.options`).
        case option(TextEncodingOption)
        /// What the book is read in now, when no option names it (UTF-16, or
        /// an encoding an HTML file declares that the catalog lacks), or while
        /// that is not known. Listed last, so Automatic stays first; choosing
        /// it changes nothing.
        case current
    }

    /// A choice the listener has not confirmed yet, with what its
    /// confirmation says of the book besides the new reading
    /// (`TextEncodingWording.confirmMessage(option:keepsText:stopsEditing:)`).
    struct Confirmation: Equatable {
        /// The option chosen.
        let option: TextEncodingOption
        /// Whether the book's content.md holds text TextMouth did not write,
        /// which the re-read keeps beside the new reading as a copy: an edit
        /// made with Edit Text, or a save no edit took.
        let keepsText: Bool
        /// Whether the book is being edited with Edit Text, which stops.
        let stopsEditing: Bool
    }

    /// What the row shows of the book's encoding.
    @Published private(set) var state: TextEncodingRowState
    /// The choice the listener made and has not confirmed yet, while the
    /// confirmation asks.
    @Published private(set) var pending: Confirmation?
    /// Whether a re-read is under way, which dims the pop-up and the sheet's
    /// buttons, so it cannot start twice nor the sheet close halfway.
    @Published private(set) var isWorking = false
    /// Why the last choice changed nothing, which the sheet shows; nil when
    /// there is nothing to say.
    @Published private(set) var failureMessage: String?

    /// The book whose encoding the pop-up shows.
    let bookID: UUID
    /// The library the book is in, which reads it again.
    private let library: LibraryViewModel
    /// How the book's files are reached: the app's, unless a test passes one
    /// that pretends files are in the cloud.
    private let access: MaintenanceFileAccess

    /// The pop-up of `book`, in `library`. A book whose row records its
    /// encoding shows it at once; any other shows that its file is being
    /// checked until `load()` has read it.
    init(book: Book, library: LibraryViewModel, access: MaintenanceFileAccess = .live) {
        bookID = book.id
        self.library = library
        self.access = access
        state = TextEncodingReading(record: book.textEncodingRecord).map(TextEncodingRowState.known) ?? .checking
    }

    // MARK: The Pop-up

    /// The items, in order: every option, then the current reading when no
    /// option names it.
    var items: [Item] {
        let options = TextEncodingChoices.options.map(Item.option)
        return selection == .current ? options + [.current] : options
    }

    /// The item shown as selected: the option of the encoding the book is
    /// read in now, or `.current` when none names it.
    var selection: Item {
        guard case .known(let reading) = state, let option = reading.option else { return .current }
        return .option(option)
    }

    /// The name `item` is listed by: an option's, exactly as the catalog
    /// names it (`TextEncodingChoices.name(of:)`); but the item selected, the
    /// encoding the book is read in now, is named with what decided it
    /// (`valueDescription`): "Windows-1251 (Cyrillic), guessed". A pop-up
    /// button's value, which VoiceOver speaks before its label and the
    /// button shows, is its selected item's name, and SwiftUI gives it no
    /// other (its `accessibilityValue` does not reach the button, as
    /// `TextEncodingPopUpTests` measured), so the selected item says it.
    func name(of item: Item) -> String {
        if item == selection {
            return valueDescription
        }
        switch item {
        case .option(let option):
            return TextEncodingChoices.name(of: option)
        case .current:
            // Never listed unless selected (`items`).
            return valueDescription
        }
    }

    /// The pop-up's value, as VoiceOver speaks it and the button shows it,
    /// its selected item's name: what the book is read in now and what
    /// decided it, "Windows-1251 (Cyrillic), guessed", or why that is not
    /// known yet.
    var valueDescription: String {
        state.valueDescription
    }

    /// Whether the pop-up takes a choice: not while the file is checked, nor
    /// while a re-read is under way.
    var isEnabled: Bool {
        state != .checking && !isWorking
    }

    // MARK: Working Out the Reading

    /// Works out what the book is read in now: from its row's record at
    /// once, or else off the main actor, from its package record or its
    /// file (`TextEncodingReading.current(of:access:)`), which is never
    /// downloaded for it. A book gone from the library leaves the row as it
    /// is.
    func load() async {
        guard let book = library.bookByID(bookID) else { return }
        if let reading = TextEncodingReading(record: book.textEncodingRecord) {
            state = .known(reading)
            return
        }
        let access = self.access
        state = await OffMainWork.run { TextEncodingReading.current(of: book, access: access) }
    }

    // MARK: Choosing

    /// The listener chose `item` in the pop-up. Another option is asked
    /// about first (`pending`), with whether text TextMouth did not write
    /// will be kept beside the new reading, read from the book's content.md
    /// off the main actor and never downloaded
    /// (`LibraryViewModel.unwrittenText(of:access:)`), and whether Edit Text
    /// stops. A book that can't be read again now is not asked about: the
    /// sheet says why (`failureMessage`), and VoiceOver hears it. The item
    /// already selected, and `.current`, change nothing.
    func choose(_ item: Item) async {
        guard case .option(let option) = item, item != selection, isEnabled else { return }
        failureMessage = nil
        guard let book = library.bookByID(bookID) else {
            failureMessage = OperationFailureNotice.message(after: .failure(TextEncodingWording.bookGoneRefusal))
            return
        }
        if let refusal = library.textEncodingChangeRefusal(of: book) {
            failureMessage = OperationFailureNotice.message(after: .failure(refusal))
            return
        }
        let access = self.access
        let keepsText = await OffMainWork.run { (try? LibraryViewModel.unwrittenText(of: book, access: access)) != nil }
        pending = Confirmation(option: option, keepsText: keepsText, stopsEditing: library.textEditSessions.isEditing(bookID))
    }

    /// The confirmation's title for `option`, naming the book as the library
    /// knows it: "Read “Ledger” again as Shift JIS (Japanese)?".
    func confirmTitle(for option: TextEncodingOption) -> String {
        TextEncodingWording.confirmTitle(bookTitle: library.bookByID(bookID)?.title ?? "", option: option)
    }

    /// The confirmation's message for `confirmation`, which also says that an
    /// edit of the text is kept, when one will be, and that Edit Text stops,
    /// for a book being edited.
    func confirmMessage(for confirmation: Confirmation) -> String {
        TextEncodingWording.confirmMessage(
            option: confirmation.option, keepsText: confirmation.keepsText, stopsEditing: confirmation.stopsEditing
        )
    }

    /// The listener confirmed `option`: the book is read again
    /// (`LibraryViewModel.readTextAgain(bookID:as:access:)`), which announces
    /// what it did; a refusal is shown, and announced, and the pop-up shows
    /// what the book is read in afterwards.
    func confirm(_ option: TextEncodingOption) async {
        pending = nil
        failureMessage = nil
        isWorking = true
        let outcome = await library.readTextAgain(bookID: bookID, as: option, access: access)
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
