import Combine
import Foundation

// MARK: - The Braille Code Pop-up's Model (FMT21)

/// What Book Information's Braille Code pop-up shows and does for one
/// braille book: the braille code (the table, `Book.brailleTable`) its text
/// is translated to print by; the tables this TextMouth and this Mac offer,
/// with that one selected; the confirmation another asks for; and the
/// re-read, whose refusal the sheet shows and VoiceOver hears. It follows
/// the Braille File Characters pop-up's model (`BrailleFileCodeChoiceModel`),
/// whose view, alert, and checks it shares (`BookRereadChoosing`), and whose
/// choice, confirmation, and re-read it runs in the same flow
/// (`RereadChoiceFlow`).
///
/// The tables are listed by the words the book's row already says
/// (`BrailleTableCatalog.description(ofTableID:)`), such as "Unified English
/// Braille, contracted (Grade 2)" or "French braille, contracted (Grade 2),
/// in French". Reading the Mac's tables' headers takes a moment, so they are
/// listed off the main actor (`load()`), and the pop-up is dimmed until they
/// are, showing the book's own code meanwhile.
@MainActor
final class BrailleCodeChoiceModel: ObservableObject, BookRereadChoosing {
    /// One item of the pop-up.
    enum Item: Hashable, Sendable {
        /// A table TextMouth offers, by its stored value
        /// (`BrailleTable.id`); also the book's own table before the offered
        /// tables are listed.
        case table(String)
        /// The stored value of the book's own table when this Mac does not
        /// offer it, such as one of VoiceOver's tables that a macOS update
        /// removed: listed last only while it is selected. Choosing it
        /// changes nothing.
        case unavailable(String)
    }

    /// A choice the listener has not confirmed yet, with what its
    /// confirmation says of the book besides the new reading
    /// (`BrailleCodeWording.confirmMessage(keepsText:stopsEditing:)`).
    typealias Confirmation = RereadConfirmation<BrailleTable>

    /// The book's table as stored, nil for none, which reads as the default
    /// table: the row's at once, then, after a re-read, the row's again
    /// (`reload()`).
    @Published private(set) var storedTable: String?
    /// The tables offered, in the catalog's order, once listed (`load()`).
    @Published private(set) var offered: [BrailleTable] = []
    /// The words each offered table is listed by, by its stored value, made
    /// with the tables (`load()`).
    @Published private(set) var names: [String: String] = [:]
    /// Whether the offered tables are listed.
    @Published private(set) var isLoaded = false
    /// Whether the book's braille shows the signs of English Braille,
    /// American Edition (`BrailleCodeDetector`), found by `load()` for a book
    /// read with a UEB table.
    @Published private(set) var showsEBAESigns = false

    /// The choice, its confirmation, and the re-read, as every re-read
    /// pop-up runs them, with the book, its library, and how its files are
    /// reached. Its changes are this model's, so the views observing the
    /// model redraw (`flowChanges`).
    let flow: RereadChoiceFlow<BrailleTable>
    /// Forwards the flow's changes to this model's observers.
    private var flowChanges: AnyCancellable?

    /// The pop-up of `book`, in `library`, showing the table the book's row
    /// stores until `load()` has listed the offered tables.
    init(book: Book, library: LibraryViewModel, access: MaintenanceFileAccess = .live) {
        flow = RereadChoiceFlow(bookID: book.id, library: library, access: access)
        storedTable = book.brailleTable
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

    /// The book whose braille code the pop-up shows.
    var bookID: UUID {
        flow.bookID
    }

    // MARK: The Pop-up

    /// The id of the table the book is read with: its stored table, or the
    /// default for a book that stores none.
    private var currentTableID: String {
        storedTable ?? BrailleTableCatalog.defaultTableID
    }

    /// The items, in order: every offered table, then the book's own table
    /// when this Mac does not offer it. Only the book's own table until the
    /// offered tables are listed.
    var items: [Item] {
        guard isLoaded else { return [selection] }
        let tables = offered.map { Item.table($0.id) }
        guard case .unavailable = selection else { return tables }
        return tables + [selection]
    }

    /// The item shown as selected: the table the book is read with. Once the
    /// offered tables are listed, a table among them is a table and any other
    /// is `.unavailable`.
    var selection: Item {
        let id = currentTableID
        if isLoaded, !offered.contains(where: { $0.id == id }) {
            return .unavailable(id)
        }
        return .table(id)
    }

    /// The name `item` is listed by: the selected item's is the pop-up's
    /// value, which VoiceOver speaks before its label and the button shows,
    /// as "Unified English Braille, contracted (Grade 2)". A table not yet
    /// named is named as the book's row names its table, and so is an
    /// unavailable one, by its stored value
    /// (`BrailleTableCatalog.description(ofTableID:)`), so the pop-up, the
    /// row it replaces, and Speak Info never differ.
    func name(of item: Item) -> String {
        switch item {
        case .table(let id):
            return names[id] ?? BrailleTableCatalog.description(ofTableID: id)
        case .unavailable(let id):
            return BrailleTableCatalog.description(ofTableID: id)
        }
    }

    /// Whether the pop-up takes a choice: once the offered tables are
    /// listed, and not while a re-read is under way.
    var isEnabled: Bool {
        isLoaded && !isWorking
    }

    // MARK: The Suggestion

    /// The sentence that suggests English Braille, American Edition: the
    /// book's braille shows that code's signs and the book is read as UEB,
    /// so it probably reads wrongly. Nil when there is nothing to suggest.
    /// Nothing changes the book's table by itself (the user chooses it in
    /// the pop-up, which asks first).
    var suggestion: String? {
        showsEBAESigns && BrailleTableCatalog.table(withID: currentTableID)?.system == "ueb"
            ? BrailleCodeWording.suggestsEnglishBrailleAmericanEdition : nil
    }

    /// Whether the braille of `book` shows English Braille, American
    /// Edition's signs, found off the main actor and never downloading the
    /// file (`BrailleCodeDetector`); false for a book read with no UEB
    /// table, since there is nothing to suggest then, and for one whose file
    /// is not on this Mac or cannot be read.
    private func looksLikeEBAE(_ book: Book) async -> Bool {
        guard BrailleTableCatalog.table(withID: book.brailleTable ?? BrailleTableCatalog.defaultTableID)?.system == "ueb" else {
            return false
        }
        let file = book.bookFileURL
        let fileCode = book.brailleFileCode
        let access = flow.access
        return await OffMainWork.run {
            guard access.presence(of: file) == .present else { return false }
            return (try? access.read(file) { BrailleCodeDetector.looksLikeEBAE(fileAt: file, fileCode: fileCode) }) ?? false
        }
    }

    // MARK: Listing the Tables

    /// Lists the offered tables and the words each is named by, off the main
    /// actor (reading this Mac's tables is the one slow step), and takes the
    /// book's table as its row stores it now. A book gone from the library
    /// leaves the pop-up as it is.
    func load() async {
        guard let book = flow.library.bookByID(bookID) else { return }
        let listing = await OffMainWork.run { () -> (tables: [BrailleTable], names: [String: String]) in
            let tables = BrailleTableCatalog.offeredTables
            return (tables, Dictionary(
                tables.map { ($0.id, BrailleTableCatalog.description(ofTableID: $0.id)) },
                uniquingKeysWith: { first, _ in first }
            ))
        }
        storedTable = book.brailleTable
        offered = listing.tables
        names = listing.names
        showsEBAESigns = await looksLikeEBAE(book)
        isLoaded = true
    }

    /// Takes the table the book's row stores now, after a re-read changed it.
    /// A book gone from the library leaves the pop-up as it is.
    private func reload() {
        guard let book = flow.library.bookByID(bookID) else { return }
        storedTable = book.brailleTable
    }

    // MARK: Choosing

    /// The listener chose `item` in the pop-up. Another table is asked about
    /// first (`pending`), with whether text TextMouth did not write will be
    /// kept beside the new reading and whether Edit Text stops, or refused,
    /// with the reason shown and announced, for a book that can't be read
    /// again now (`RereadChoiceFlow.choose(_:)`). The table already
    /// selected, one this Mac does not offer, and a choice while the pop-up
    /// takes none change nothing.
    func choose(_ item: Item) async {
        guard case .table(let id) = item, item != selection, isEnabled,
              let table = offered.first(where: { $0.id == id }) else { return }
        await flow.choose(table)
    }

    /// The confirmation's title for `table`, naming the book as the library
    /// knows it: "Read “Ledger” again as Unified English Braille,
    /// uncontracted (Grade 1)?".
    func confirmTitle(for table: BrailleTable) -> String {
        BrailleCodeWording.confirmTitle(
            bookTitle: flow.library.bookByID(bookID)?.title ?? "", codeName: name(of: .table(table.id))
        )
    }

    /// The confirmation's message for `confirmation`: that the braille is
    /// translated to print again, what the re-read changes, an edit of the
    /// text kept, when one will be, and Edit Text stopping, for a book being
    /// edited, included.
    func confirmMessage(for confirmation: Confirmation) -> String {
        BrailleCodeWording.confirmMessage(keepsText: confirmation.keepsText, stopsEditing: confirmation.stopsEditing)
    }

    /// The listener confirmed `table`: the book is read again with it
    /// (`RereadChoiceFlow.confirm(choosing:thenReload:)`), which announces
    /// what it did; a refusal, such as a table that fails, is shown, and
    /// announced, and the pop-up shows the table the book is read with
    /// afterwards (`reload()`).
    func confirm(_ table: BrailleTable) async {
        await flow.confirm(choosing: .brailleTable(table)) { self.reload() }
    }

    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel() {
        flow.cancel()
    }
}
