import Combine
import Foundation

// MARK: - What Book Information's Re-read Pop-ups Share (encodingchoice, braillecodes)

/// A choice the listener made in one of Book Information's re-read pop-ups
/// and has not confirmed yet, with what its confirmation says of the book
/// besides the new reading: the Text Encoding pop-up's option
/// (`TextEncodingChoiceModel.Confirmation`, encodingchoice) or the Braille
/// File Characters pop-up's code (`BrailleFileCodeChoiceModel.Confirmation`,
/// braillecodes).
struct RereadConfirmation<Option: Equatable>: Equatable {
    /// The option chosen.
    let option: Option
    /// Whether the book's content.md holds text TextMouth did not write,
    /// which the re-read keeps beside the new reading as a copy: an edit
    /// made with Edit Text, or a save no edit took.
    let keepsText: Bool
    /// Whether the book is being edited with Edit Text, which stops.
    let stopsEditing: Bool
}

/// What the checks a re-read pop-up makes before it asks for a confirmation
/// found (`LibraryViewModel.rereadPreflight(of:access:)`).
enum RereadPreflight: Equatable, Sendable {
    /// The book can be read again now, so the confirmation asks, saying
    /// whether text TextMouth did not write will be kept beside the new
    /// reading (`keepsText`) and whether Edit Text stops (`stopsEditing`).
    case ready(keepsText: Bool, stopsEditing: Bool)
    /// The book can't be read again now, for the reason given, in full,
    /// which the sheet shows and VoiceOver hears; nothing is asked.
    case refused(String)
}

extension LibraryViewModel {
    /// The checks both of Book Information's re-read pop-ups make before
    /// they ask the listener to confirm a choice for the book `bookID`, in
    /// one place: a book gone from the library
    /// (`TextEncodingWording.bookGoneRefusal`) or busy
    /// (`textEncodingChangeRefusal(of:)`) is refused; any other is ready,
    /// with whether text TextMouth did not write will be kept beside the new
    /// reading, read from the book's content.md off the main actor through
    /// `access` and never downloaded (`unwrittenText(of:access:)`), and
    /// whether Edit Text stops, for a book being edited. The re-read checks
    /// the book again once it is confirmed
    /// (`readTextAgain(bookID:choosing:access:)`), since it may change while
    /// the confirmation asks.
    func rereadPreflight(of bookID: UUID, access: MaintenanceFileAccess) async -> RereadPreflight {
        guard let book = bookByID(bookID) else {
            return .refused(TextEncodingWording.bookGoneRefusal)
        }
        if let refusal = textEncodingChangeRefusal(of: book) {
            return .refused(refusal)
        }
        let keepsText = await OffMainWork.run { (try? Self.unwrittenText(of: book, access: access)) != nil }
        return .ready(keepsText: keepsText, stopsEditing: textEditSessions.isEditing(bookID))
    }
}

// MARK: - A Re-read Pop-up's Model

/// What one of Book Information's re-read pop-ups (`BookRereadPopUp`) needs
/// of its model, which the Text Encoding pop-up's (`TextEncodingChoiceModel`,
/// encodingchoice) and the Braille File Characters pop-up's
/// (`BrailleFileCodeChoiceModel`, braillecodes) both have: the items, with
/// what the book is read with now selected and named; whether the pop-up
/// takes a choice; and the confirmation a new choice asks for, its words, and
/// its two answers. Both models run the choice, its confirmation, and the
/// re-read through one `RereadChoiceFlow`. Sendable, as a main-actor model
/// is, since the pop-up's binding hands it to closures SwiftUI requires to be
/// Sendable.
@MainActor
protocol BookRereadChoosing: ObservableObject, Sendable {
    /// One item of the pop-up. Sendable, since the pop-up hands the item
    /// chosen to a task (`choose(_:)`).
    associatedtype Item: Hashable, Sendable
    /// What a confirmation asks about and the re-read reads the book with:
    /// an encoding option, or braille file characters. Sendable, since the
    /// alert hands the option confirmed to a task (`confirm(_:)`).
    associatedtype Option: Equatable, Sendable

    /// The items, in the pop-up's order.
    var items: [Item] { get }
    /// The item shown as selected: what the book is read with now.
    var selection: Item { get }
    /// The name `item` is listed by. The selected item's is the pop-up's
    /// value, which VoiceOver speaks before its label and the button shows.
    func name(of item: Item) -> String
    /// Whether the pop-up takes a choice now.
    var isEnabled: Bool { get }
    /// The choice the listener made and has not confirmed yet, while the
    /// confirmation asks; nil otherwise.
    var pending: RereadConfirmation<Option>? { get }
    /// The listener chose `item` in the pop-up: another reading is asked
    /// about first (`pending`), or refused, with the reason shown and
    /// announced; the item already selected changes nothing.
    func choose(_ item: Item) async
    /// The confirmation's title for `option`, naming the book.
    func confirmTitle(for option: Option) -> String
    /// The confirmation's message for `confirmation`: what the re-read
    /// changes.
    func confirmMessage(for confirmation: RereadConfirmation<Option>) -> String
    /// The listener confirmed `option`: the book is read again with it.
    func confirm(_ option: Option) async
    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel()
}

// MARK: - The Choice and the Re-read, for Both Pop-ups (review of October 30, finding 8)

/// The steps from a choice in one of Book Information's re-read pop-ups to
/// the book read again, and their state, in one place for both pop-ups'
/// models: the Text Encoding pop-up's (`TextEncodingChoiceModel`,
/// encodingchoice) and the Braille File Characters pop-up's
/// (`BrailleFileCodeChoiceModel`, braillecodes). A choice is checked, then
/// asked about (`choose(_:)`) or refused with the reason shown and
/// announced; a confirmed one reads the book again
/// (`confirm(choosing:thenReload:)`); a confirmation closed without one
/// leaves everything (`cancel()`).
///
/// Each model holds one flow, keeps its own items, selection, names, and
/// reading of what the book is read with now, and forwards the flow's
/// changes to the views observing it. So a change to the flow, such as
/// when `isWorking` turns on or what a refusal announces, reaches both
/// pop-ups at once, where each model once kept a copy of it.
@MainActor
final class RereadChoiceFlow<Option: Equatable & Sendable>: ObservableObject {
    /// The choice the listener made and has not confirmed yet, while the
    /// confirmation asks; nil otherwise.
    @Published private(set) var pending: RereadConfirmation<Option>?
    /// Whether a re-read is under way, which dims the pop-up and the sheet's
    /// buttons, so it cannot start twice nor the sheet close halfway.
    @Published private(set) var isWorking = false
    /// Why the last choice changed nothing, which the sheet shows; nil when
    /// there is nothing to say.
    @Published private(set) var failureMessage: String?
    /// When this flow last said something about its failure message, or
    /// cleared it, in the order of every pop-up's (`RereadFailureOrder`): a
    /// sheet with several pop-ups shows the message of the one that spoke
    /// last, so a message of an earlier choice in another pop-up never stays
    /// beside a newer one's.
    private(set) var failureStamp = 0

    /// The book the pop-up reads again.
    let bookID: UUID
    /// The library the book is in, which checks the book and reads it
    /// again. The pop-up's model asks it for the book too, for what the
    /// book is read with now and for its title.
    let library: LibraryViewModel
    /// How the book's files are reached: the app's, unless a test passes one
    /// that pretends files are in the cloud.
    let access: MaintenanceFileAccess

    /// The flow of the book `bookID`, in `library`, whose files are reached
    /// through `access`: nothing asked, under way, or refused yet.
    init(bookID: UUID, library: LibraryViewModel, access: MaintenanceFileAccess) {
        self.bookID = bookID
        self.library = library
        self.access = access
    }

    /// The listener chose `option`, which the pop-up's model has found to
    /// differ from what the book is read with now, while the pop-up takes a
    /// choice. The last refusal is cleared, so it never reads as this
    /// choice's. The choice is then asked about first (`pending`), with
    /// whether text TextMouth did not write will be kept beside the new
    /// reading, read from the book's content.md off the main actor and never
    /// downloaded, and whether Edit Text stops
    /// (`LibraryViewModel.rereadPreflight(of:access:)`). A book that can't
    /// be read again now is not asked about: the sheet says why
    /// (`failureMessage`), and VoiceOver hears it.
    func choose(_ option: Option) async {
        setFailureMessage(nil)
        switch await library.rereadPreflight(of: bookID, access: access) {
        case .refused(let refusal):
            setFailureMessage(OperationFailureNotice.message(after: .failure(refusal)))
        case let .ready(keepsText, stopsEditing):
            pending = RereadConfirmation(option: option, keepsText: keepsText, stopsEditing: stopsEditing)
        }
    }

    /// The listener confirmed a choice: the book is read again as `choice`
    /// says, the option confirmed in its kind of re-read
    /// (`.textEncoding(option)`, or `.brailleFileCode(code)`), by
    /// `LibraryViewModel.readTextAgain(bookID:choosing:access:)`, which
    /// announces what it did; a refusal is shown, and announced. Then
    /// `reload`, the pop-up's model's own reading of what the book is read
    /// with now, runs before the re-read counts as over, so the pop-up
    /// shows the book as it is by the time it takes a choice again.
    /// `reload` is only called, never kept, so the flow holds no reference
    /// to the model that holds it.
    func confirm(choosing choice: TextRereadChoice, thenReload reload: @MainActor () async -> Void) async {
        pending = nil
        setFailureMessage(nil)
        isWorking = true
        let outcome = await library.readTextAgain(bookID: bookID, choosing: choice, access: access)
        setFailureMessage(OperationFailureNotice.message(after: outcome))
        await reload()
        isWorking = false
    }

    /// Says `message` as this flow's failure message, or none (nil), and
    /// notes that this flow spoke last (`failureStamp`): a choice or a
    /// re-read of this pop-up, even one that fails nothing, replaces what an
    /// earlier one of any pop-up left showing.
    private func setFailureMessage(_ message: String?) {
        failureMessage = message
        failureStamp = RereadFailureOrder.next()
    }

    /// The confirmation closed without the listener confirming: nothing
    /// changes, and the pop-up shows what it showed.
    func cancel() {
        pending = nil
    }
}

// MARK: - Which Pop-up's Refusal the Sheet Shows

/// The order in which Book Information's re-read pop-ups spoke about their
/// failures, so the sheet, which has one line for a refusal under all of its
/// pop-ups (a BRF book's has two: Braille Code and Braille File Characters),
/// shows the message of the one used last and only that one's. Each flow
/// stamps its message, and its clearing, with the next number
/// (`RereadChoiceFlow.failureStamp`).
@MainActor
enum RereadFailureOrder {
    /// The last number given.
    private static var last = 0

    /// The next number, higher than every one given before.
    static func next() -> Int {
        last += 1
        return last
    }

    /// The failure message to show for pop-ups that said `popUps`: the
    /// message of the pop-up that spoke last, or nil when it cleared its
    /// message (a new choice, or a re-read that went ahead), whatever an
    /// earlier pop-up still holds.
    static func latest(among popUps: [(message: String?, stamp: Int)]) -> String? {
        popUps.max { $0.stamp < $1.stamp }?.message
    }
}
