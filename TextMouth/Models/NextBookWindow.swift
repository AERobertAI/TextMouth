import Foundation

/// Where the next book opens when listening goes on from one book to
/// another: at the end of a book, with Next and Previous in the reading
/// list, and with Next and Previous in Folder (0.2.5). Each raw value is what
/// config.json and a folder's or feed's options keep, in English whatever
/// the interface's language; `title` is the choice's name in Settings'
/// pop-up button and in Feed Info and Folder Settings, in the interface's
/// language (FR35). The raw values were the names until the names were
/// localized, which is why they read as English words.
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
    case thisWindow = "This Window" // l10n: no (stored id: config.json keeps it; `title` is shown)
    /// A window opens for the next book, and this one stays, as TextMouth
    /// did before 0.2.5.
    case newWindow = "A New Window" // l10n: no (stored id: config.json keeps it; `title` is shown)

    /// The choice's name, as Settings' pop-up button, Feed Info, and Folder
    /// Settings show and VoiceOver speaks it: today the same words as the raw
    /// value in English, read from the String Catalog in any other language.
    var title: String {
        switch self {
        case .thisWindow:
            // Translators: A choice of the Open the next book in pop-up button (Settings, Playback; Feed Info; Folder Settings): the next book opens in the window already open, in place of the book there.
            return InterfaceText.line("nextBookWindow.title.thisWindow", "This Window")
        case .newWindow:
            // Translators: A choice of the Open the next book in pop-up button (Settings, Playback; Feed Info; Folder Settings): the next book opens in a window of its own, and this one stays.
            return InterfaceText.line("nextBookWindow.title.newWindow", "A New Window")
        }
    }
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
///
/// Localized (FR35): a sentence that names a feed's or folder's items is
/// written whole for each noun, never built from the noun's English forms,
/// since another language may change the words around the noun with it.
enum NextBookWindowWording {

    // MARK: The Global Setting

    /// The label of Settings' pop-up button.
    static var globalLabel: String {
        // Translators: Label of the pop-up button in Settings, Playback, and in a folder's settings, choosing where the next book opens; its choices are This Window and A New Window.
        InterfaceText.line("nextBookWindow.globalLabel", "Open the next book in")
    }

    /// The hint of Settings' pop-up button, also shown under it (FR35's cut:
    /// it began "Where the next book opens when listening goes on from one
    /// book to another", and said each choice at length).
    static var globalHint: String {
        // Translators: VoiceOver hint of the Open the next book in pop-up button in Settings, Playback, also shown under it. %@ is the name of its choice This Window.
        InterfaceText.line("nextBookWindow.globalHint", "Chooses where the next book opens: in this window or a new one. A book open in another window comes forward, and with \(NextBookWindow.thisWindow.title) chosen, this window closes.")
    }

    // MARK: A Feed's or Folder's Own Choice

    /// The label of a feed's or folder's pop-up button: "Open the next
    /// episode in", "Open the next book in".
    static func label(_ noun: ListeningOptionsWording.Noun) -> String {
        switch noun {
        case .episode:
            // Translators: Label of the pop-up button in a podcast feed's Feed Info, choosing where the feed's next episode opens.
            return InterfaceText.line("nextBookWindow.label.episode", "Open the next episode in")
        case .article:
            // Translators: Label of the pop-up button in a news feed's Feed Info, choosing where the feed's next article opens.
            return InterfaceText.line("nextBookWindow.label.article", "Open the next article in")
        case .item:
            // Translators: Label of the pop-up button in a feed's Feed Info, choosing where the feed's next item opens.
            return InterfaceText.line("nextBookWindow.label.item", "Open the next item in")
        case .book:
            return globalLabel
        }
    }

    /// The name of one choice. The choice of nil is "Use the global
    /// setting", which names the global setting's own value in parentheses,
    /// since the choice means whatever that is: "Use the global setting
    /// (This Window)".
    static func title(_ choice: NextBookWindow?, global: NextBookWindow) -> String {
        guard let choice else {
            // Translators: A choice of the Open the next book in pop-up button in Feed Info and Folder Settings: do as Settings says. %@ is the name of the choice Settings has now, such as This Window.
            return InterfaceText.line("common.useTheGlobalSettingValue", "Use the global setting (\(global.title))")
        }
        return choice.title
    }

    /// The hint of a feed's or folder's pop-up button. While listening does
    /// not go on from one item to another, the choice is not in effect, and
    /// the hint says when it is available instead of what it does.
    static func hint(_ noun: ListeningOptionsWording.Noun, enabled: Bool) -> String {
        enabled ? enabledHint(noun) : unavailableHint(noun)
    }

    /// The hint while the choice is in effect: what it chooses, for the
    /// items `noun` names; its choices say the rest (FR35's cut: each said
    /// the three choices again).
    private static func enabledHint(_ noun: ListeningOptionsWording.Noun) -> String {
        switch noun {
        case .episode:
            // Translators: VoiceOver hint of the Open the next episode in pop-up button in a podcast feed's Feed Info.
            return InterfaceText.line("nextBookWindow.enabledHint.episode", "Chooses where this feed's next episode opens.")
        case .article:
            // Translators: VoiceOver hint of the Open the next article in pop-up button in a news feed's Feed Info.
            return InterfaceText.line("nextBookWindow.enabledHint.article", "Chooses where this feed's next article opens.")
        case .item:
            // Translators: VoiceOver hint of the Open the next item in pop-up button in a feed's Feed Info.
            return InterfaceText.line("nextBookWindow.enabledHint.item", "Chooses where this feed's next item opens.")
        case .book:
            // Translators: VoiceOver hint of the Open the next book in pop-up button in a folder's settings.
            return InterfaceText.line("nextBookWindow.enabledHint.folder", "Chooses where this folder's next book opens.")
        }
    }

    /// The hint while the choice is dimmed: when it becomes available, for
    /// the items `noun` names. Word for word the sentence the predownload
    /// switch beside it says (`ListeningOptionsWording.predownloadHint`), so
    /// the two read alike and share one translation; not cut alone (FR35).
    static func unavailableHint(_ noun: ListeningOptionsWording.Noun) -> String {
        switch noun {
        case .episode:
            // Translators: VoiceOver hint of the dimmed Open the next episode in pop-up button in a podcast feed's Feed Info: when it can be used.
            return InterfaceText.line("nextBookWindow.unavailableHint.episode", "Available only while this feed's episodes go on to another episode when one ends")
        case .article:
            // Translators: VoiceOver hint of the dimmed Open the next article in pop-up button in a news feed's Feed Info: when it can be used.
            return InterfaceText.line("nextBookWindow.unavailableHint.article", "Available only while this feed's articles go on to another article when one ends")
        case .item:
            // Translators: VoiceOver hint of the dimmed Open the next item in pop-up button in a feed's Feed Info: when it can be used.
            return InterfaceText.line("nextBookWindow.unavailableHint.item", "Available only while this feed's items go on to another item when one ends")
        case .book:
            // Translators: VoiceOver hint of the dimmed Open the next book in pop-up button in a folder's settings: when it can be used.
            return InterfaceText.line("nextBookWindow.unavailableHint.folder", "Available only while this folder's books go on to another book when one ends")
        }
    }
}
