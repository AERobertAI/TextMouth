import Foundation

/// Where the next book opens when listening goes on from one book to
/// another: at the end of a book, with Next and Previous in the reading
/// list, and with Next and Previous in Folder (0.2.5). Each raw value is the
/// choice's name in Settings' pop-up button, in Feed Info and Folder
/// Settings, and what config.json keeps.
///
/// The user asked on November 1, 2026: "the opening of new windows when
/// completing a book in the reading list or similarly configured folder or /
/// feed item seems to open a new window for the item moved to, though it
/// correctly moves to the new item. I would want it to either close the old
/// window once the new one was moved to, or even better rebuild the original
/// window to have the new book as the active item viewed."
enum NextBookWindow: String, CaseIterable, Codable, Sendable {
    /// The window the listener is in shows the next book in place of this
    /// one. The default.
    case thisWindow = "This Window"
    /// A window opens for the next book, and this one stays, as TextMouth
    /// did before 0.2.5.
    case newWindow = "A New Window"
}

/// What the reader's window is doing, as far as switching it to another
/// book is concerned. Read from AppKit by the reader
/// (`ReaderViewModel.windowStanding`), and set by a test, which has no
/// window.
struct NextBookWindowStanding: Equatable, Sendable {
    /// Whether the window is on screen (`NSWindow.isVisible`).
    var isVisible: Bool
    /// Whether the window is minimized to the Dock, which shows a book
    /// all the same.
    var isMiniaturized: Bool
    /// Whether TextMouth is hidden (Command-H), which orders every window
    /// out: a hidden app's window is not off screen for good.
    var appIsHidden: Bool
    /// Whether a sheet or an alert is open over the window.
    var hasSheet: Bool
    /// Whether a text field of the window is being typed in: Go to Percent,
    /// Go to Time, or Go to Page, whose panel is inside the window, not a
    /// sheet.
    var fieldIsBeingEdited: Bool

    /// A window that is on screen with nothing open over it, which a
    /// switch may change.
    static let onScreen = NextBookWindowStanding(
        isVisible: true, isMiniaturized: false, appIsHidden: false, hasSheet: false, fieldIsBeingEdited: false
    )

    /// No window, or one that has closed: nothing a switch could show a book
    /// in.
    static let noWindow = NextBookWindowStanding(
        isVisible: false, isMiniaturized: false, appIsHidden: false, hasSheet: false, fieldIsBeingEdited: false
    )

    /// Whether a book shown in the window is seen: it is on screen, or
    /// minimized, or TextMouth is hidden and the window comes back with it.
    /// A window that has closed is none of these.
    var isOnScreen: Bool {
        isVisible || isMiniaturized || appIsHidden
    }

    /// Whether switching the window could lose something: it is not on
    /// screen, a sheet is open over it, or a field is being typed in.
    var isBusy: Bool {
        !isOnScreen || hasSheet || fieldIsBeingEdited
    }
}

/// What a reader does to show the next book, once every setting and the
/// state of its window are weighed. The one place the rule is written in
/// code, so each arrangement is tested without opening a window.
enum NextBookWindowRule {

    /// What the reader does with the book it goes on to.
    enum Action: Equatable, Sendable {
        /// Open the book's window, or bring it forward when it is open
        /// already, and leave this window as it is: today's behavior.
        case openANewWindow
        /// Show the book in this window, in place of the one here.
        case switchThisWindow
        /// The book is open in another window already: bring that window
        /// forward, as `openANewWindow` does, and close this one, so that
        /// no two windows show one book.
        case bringTheOpenWindowForwardThenClose
    }

    /// The window choice in force for a move: the feed's or folder's own,
    /// when the move goes through one that has made a choice and listening
    /// goes on from its items, else the global setting. A move through the
    /// reading list passes no options, and follows the global setting.
    ///
    /// The feed's or folder's choice is dimmed while its items do not go on
    /// to another item (`ListeningOptions.goesOn(under:)`), and a dimmed
    /// choice is not in effect, as the pre-download switch's is not.
    ///
    /// - Parameters:
    ///   - options: The options of the feed or plain folder the move goes
    ///     through, or nil for the reading list and for a feed or folder
    ///     with none of its own.
    ///   - global: The global "Open the next book in" setting.
    ///   - globalEndOfBook: The global "When book ends" setting, which
    ///     decides whether a feed or folder with no choice of its own goes
    ///     on.
    static func choice(
        options: ListeningOptions?,
        global: NextBookWindow,
        globalEndOfBook: EndOfBookBehavior
    ) -> NextBookWindow {
        guard let options, options.goesOn(under: globalEndOfBook) else { return global }
        return options.nextBookWindow ?? global
    }

    /// Whether the feed's or folder's own choice of window can be changed:
    /// it is dimmed while listening does not go on from its items.
    static func choiceIsAvailable(options: ListeningOptions, globalEndOfBook: EndOfBookBehavior) -> Bool {
        options.goesOn(under: globalEndOfBook)
    }

    /// What the reader does to show the next book.
    ///
    /// A new window is opened, as before 0.2.5, whenever the choice says so,
    /// and whenever switching could lose something: a sheet is open over
    /// the reader, an Edit Text session is under way, the library is moving,
    /// or the reader cannot switch its window.
    ///
    /// - Parameters:
    ///   - choice: The window choice in force (`choice(options:global:globalEndOfBook:)`).
    ///   - isBusy: Whether switching this window could lose something.
    ///   - canSwitch: Whether this reader can switch its own window.
    ///   - nextBookIsOpenElsewhere: Whether the next book is open in a
    ///     reader window already.
    static func action(
        choice: NextBookWindow,
        isBusy: Bool,
        canSwitch: Bool,
        nextBookIsOpenElsewhere: Bool
    ) -> Action {
        guard choice == .thisWindow, canSwitch, !isBusy else { return .openANewWindow }
        return nextBookIsOpenElsewhere ? .bringTheOpenWindowForwardThenClose : .switchThisWindow
    }
}

/// Every word the "Open the next book in" controls say and speak (0.2.5):
/// Settings' pop-up button, and the one of Feed Info and Folder Settings.
/// One place, so a test pins each string, since the listener hears them
/// through VoiceOver and reads them in braille.
enum NextBookWindowWording {

    // MARK: The Global Setting

    /// The label of Settings' pop-up button.
    static let globalLabel = "Open the next book in"

    /// The hint of Settings' pop-up button.
    static let globalHint = "Where the next book opens when listening goes on from one book to another: "
        + "in this window in place of the book here, or in a new window. "
        + "A book already open in another window is brought forward, and with This Window this window closes."

    // MARK: A Feed's or Folder's Own Choice

    /// The label of a feed's or folder's pop-up button: "Open the next
    /// episode in", "Open the next book in".
    static func label(_ noun: ListeningOptionsWording.Noun) -> String {
        "Open the next \(noun.singular) in"
    }

    /// The name of one choice. The choice of nil is "Use the global
    /// setting", which names the global setting's own value in parentheses,
    /// since the choice means whatever that is: "Use the global setting
    /// (This Window)".
    static func title(_ choice: NextBookWindow?, global: NextBookWindow) -> String {
        guard let choice else { return "Use the global setting (\(global.rawValue))" }
        return choice.rawValue
    }

    /// The hint of a feed's or folder's pop-up button. While listening does
    /// not go on from one item to another, the choice is not in effect, and
    /// the hint says when it is available instead of what it does.
    static func hint(_ noun: ListeningOptionsWording.Noun, enabled: Bool) -> String {
        guard enabled else {
            return "Available only while \(owner(noun)) \(noun.plural) go on to another \(noun.singular) when one ends"
        }
        return "Where the next \(noun.singular) opens when listening goes on from one of \(owner(noun)) \(noun.plural): "
            + "in this window, in a new window, or as the global setting says"
    }

    /// Whose items they are: "this feed's", "this folder's".
    private static func owner(_ noun: ListeningOptionsWording.Noun) -> String {
        noun == .book ? "this folder's" : "this feed's"
    }
}
