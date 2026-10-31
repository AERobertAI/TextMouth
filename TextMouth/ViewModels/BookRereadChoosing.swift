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
/// its two answers. Sendable, as a main-actor model is, since the pop-up's
/// binding hands it to closures SwiftUI requires to be Sendable.
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
