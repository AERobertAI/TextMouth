import Combine
import SwiftUI

// MARK: - The Text Encoding Pop-up's Model (encodingchoice)

/// What Book Information's Text Encoding pop-up shows and does for one book
/// (encodingchoice): what the book is read in now, worked out without making
/// the sheet wait on a large file; the options, with that encoding selected;
/// the confirmation a new option asks for; and the re-read, whose refusal
/// the sheet shows and VoiceOver hears. The pop-up and its alert are the
/// ones the Braille File Characters pop-up shows too (`BookRereadPopUp`), and
/// the choice, its confirmation, and the re-read run in the flow both
/// pop-ups share (`RereadChoiceFlow`).
@MainActor
final class TextEncodingChoiceModel: ObservableObject, BookRereadChoosing {
    /// One item of the pop-up.
    enum Item: Hashable, Sendable {
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
    typealias Confirmation = RereadConfirmation<TextEncodingOption>

    /// What the row shows of the book's encoding.
    @Published private(set) var state: TextEncodingRowState

    /// The choice, its confirmation, and the re-read, as both re-read
    /// pop-ups run them, with the book, its library, and how its files are
    /// reached. Its changes are this model's, so the views observing the
    /// model redraw (`flowChanges`).
    let flow: RereadChoiceFlow<TextEncodingOption>
    /// Forwards the flow's changes to this model's observers.
    private var flowChanges: AnyCancellable?

    /// The pop-up of `book`, in `library`. A book whose row records its
    /// encoding shows it at once; any other shows that its file is being
    /// checked until `load()` has read it.
    init(book: Book, library: LibraryViewModel, access: MaintenanceFileAccess = .live) {
        flow = RereadChoiceFlow(bookID: book.id, library: library, access: access)
        state = TextEncodingReading(record: book.textEncodingRecord).map(TextEncodingRowState.known) ?? .checking
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

    /// The book whose encoding the pop-up shows.
    var bookID: UUID {
        flow.bookID
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
        guard let book = flow.library.bookByID(bookID) else { return }
        if let reading = TextEncodingReading(record: book.textEncodingRecord) {
            state = .known(reading)
            return
        }
        let access = flow.access
        state = await OffMainWork.run { TextEncodingReading.current(of: book, access: access) }
    }

    // MARK: Choosing

    /// The listener chose `item` in the pop-up. Another option is asked
    /// about first (`pending`), with whether text TextMouth did not write
    /// will be kept beside the new reading and whether Edit Text stops, or
    /// refused, with the reason shown and announced, for a book that can't
    /// be read again now (`RereadChoiceFlow.choose(_:)`). The item already
    /// selected, `.current`, and a choice while the pop-up takes none change
    /// nothing.
    func choose(_ item: Item) async {
        guard case .option(let option) = item, item != selection, isEnabled else { return }
        await flow.choose(option)
    }

    /// The confirmation's title for `option`, naming the book as the library
    /// knows it: "Read “Ledger” again as Shift JIS (Japanese)?".
    func confirmTitle(for option: TextEncodingOption) -> String {
        TextEncodingWording.confirmTitle(bookTitle: flow.library.bookByID(bookID)?.title ?? "", option: option)
    }

    /// The confirmation's message for `confirmation`, which also says that an
    /// edit of the text is kept, when one will be, and that Edit Text stops,
    /// for a book being edited.
    func confirmMessage(for confirmation: Confirmation) -> String {
        TextEncodingWording.confirmMessage(
            option: confirmation.option, keepsText: confirmation.keepsText, stopsEditing: confirmation.stopsEditing
        )
    }

    /// The listener confirmed `option`: the book is read again as it says
    /// (`RereadChoiceFlow.confirm(choosing:thenReload:)`), which announces
    /// what it did; a refusal is shown, and announced, and the pop-up shows
    /// what the book is read in afterwards (`load()`).
    func confirm(_ option: TextEncodingOption) async {
        await flow.confirm(choosing: .textEncoding(option)) { await self.load() }
    }

    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel() {
        flow.cancel()
    }
}
