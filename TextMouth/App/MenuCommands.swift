import SwiftUI

// MARK: - Window Type Tracking

/// Identifies which type of window currently has focus. The AppKit-backed
/// MenuVisibilityManager uses the same cases to hide/show context menu titles
/// without depending on SwiftUI focused values for the menu contents.
enum ActiveWindowType {
    case library
    case reader
}

/// FocusedValue key for the active window type
struct ActiveWindowTypeKey: FocusedValueKey {
    typealias Value = ActiveWindowType
}

struct CanReleaseMediaControlsKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var activeWindowType: ActiveWindowType? {
        get { self[ActiveWindowTypeKey.self] }
        set { self[ActiveWindowTypeKey.self] = newValue }
    }

    var canReleaseMediaControls: Bool? {
        get { self[CanReleaseMediaControlsKey.self] }
        set { self[CanReleaseMediaControlsKey.self] = newValue }
    }
}

/// Whether the reader whose window is key reads its book from the reading
/// list (FR09), which Navigate > Next in Reading List and Previous in
/// Reading List need. The reader's window publishes it as a scene value
/// (`BookReaderWindowView`), so the commands stay available while
/// VoiceOver reads the window's text, which holds no keyboard focus.
struct ReadsFromReadingListKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var readsFromReadingList: Bool? {
        get { self[ReadsFromReadingListKey.self] }
        set { self[ReadsFromReadingListKey.self] = newValue }
    }
}

/// Whether the book of the reader whose window is key has pages (PG02),
/// which Navigate > Go to Page… needs. The reader's window publishes it as a
/// scene value (`BookReaderWindowView`), so the command stays available while
/// VoiceOver reads the window's text, which holds no keyboard focus.
struct ReaderHasPagesKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var readerHasPages: Bool? {
        get { self[ReaderHasPagesKey.self] }
        set { self[ReaderHasPagesKey.self] = newValue }
    }
}

/// Whether the key window is a reader, which Navigate > Next in Folder and
/// Previous in Folder need (0.2.5). The reader's window publishes it as a
/// scene value (`BookReaderWindowView`), so the commands stay available while
/// VoiceOver reads the window's text, which holds no keyboard focus, and
/// after a window switches to another book, which takes the focused view
/// away. (`activeWindowType` is a plain focused value, which leaves a menu
/// command dimmed then.)
struct IsReaderWindowKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var isReaderWindow: Bool? {
        get { self[IsReaderWindowKey.self] }
        set { self[IsReaderWindowKey.self] = newValue }
    }
}

/// The key Library window's selection as the Library menu's Remove names
/// it: Delete Download for feed items alone (REV11 F2). Each Library window
/// publishes its own as a scene value (`LibraryView`), so the title follows
/// the selection while VoiceOver reads the list, which holds no keyboard
/// focus.
struct LibraryRemovalSelectionKey: FocusedValueKey {
    typealias Value = LibraryRemovalSelection
}

extension FocusedValues {
    var libraryRemovalSelection: LibraryRemovalSelection? {
        get { self[LibraryRemovalSelectionKey.self] }
        set { self[LibraryRemovalSelectionKey.self] = newValue }
    }
}

/// The names of the views the key Library window's View pop-up offers to a
/// window showing none, in order (design section 6 of
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md): the Library menu's Go to View
/// submenu lists them, the first nine with Go to View 1 to Go to View 9's
/// keys. Each Library window publishes its own as a scene value
/// (`LibraryView`), so the submenu follows the window in front while
/// VoiceOver reads the list, which holds no keyboard focus.
struct LibraryOfferedViewNamesKey: FocusedValueKey {
    typealias Value = [String]
}

extension FocusedValues {
    var libraryOfferedViewNames: [String]? {
        get { self[LibraryOfferedViewNamesKey.self] }
        set { self[LibraryOfferedViewNamesKey.self] = newValue }
    }
}

// MARK: - Menu Commands

/// The File menu's commands beside New Window (Command-N): Open Book…, New
/// from Text…, and New Recording…, each showing and answering its key in
/// force, which the Shortcuts tab and config.json can change (FR12's branch
/// D), or none while another action has its key; and each acting only where
/// its action works (FR12's branch E): New from Text… in Library windows,
/// so a reader's Shift-Command-T is Show Sleep Timer's.
struct FileCommands: Commands {
    /// The shortcuts, observed so each item's key equivalent follows a
    /// change at once.
    @ObservedObject var shortcuts: KeyboardShortcutManager
    /// The window in front, observed so each item acts only where its
    /// command works.
    @ObservedObject private var front = FrontWindowKind.shared
    /// The library recordings are saved into.
    let library: LibraryViewModel

    /// The File menu's commands, their keys those of `shortcuts`, saving
    /// recordings into `library`.
    init(shortcuts: KeyboardShortcutManager, library: LibraryViewModel) {
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
        self.library = library
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(ShortcutAction.openBook.title) {
                NotificationCenter.default.post(name: .openBookFile, object: nil)
            }
            .menuCommandKey(.openBook, shortcuts: shortcuts, frontKind: front.kind)

            Button(ShortcutAction.newFromText.title) {
                NotificationCenter.default.post(name: .newFromText, object: nil)
            }
            .menuCommandKey(.newFromText, shortcuts: shortcuts, frontKind: front.kind)

            // Records from a microphone into a new audiobook (FR04).
            Button(ShortcutAction.newRecording.title) {
                RecordingWindowController.shared.show(library: library)
            }
            .menuCommandKey(.newRecording, shortcuts: shortcuts, frontKind: front.kind)
        }
    }
}

/// Edit > Find > Search Library…, which opens the Search Library window
/// (`LibrarySearchWindowController`) from any window, the Library's, a
/// reader's, and the Search Library window itself among them. Its key is the
/// menu item's key equivalent in force (`ShortcutAction.searchLibrary`,
/// Option-Command-F unless changed in the Shortcuts tab), shown while the
/// action's scope admits the window in front, which for the one scope it can
/// have, every window, is always.
///
/// The submenu follows the Edit menu's own items (`.textEditing`), so
/// VoiceOver reads Search Library… where it reads the other ways of finding.
struct EditCommands: Commands {
    /// The shortcuts, observed so the item's key equivalent follows a change
    /// at once.
    @ObservedObject var shortcuts: KeyboardShortcutManager
    /// The window in front, observed so the item acts only where its command
    /// works, as every menu command's does.
    @ObservedObject private var front = FrontWindowKind.shared

    /// The Edit menu's Find submenu, its key that of `shortcuts`.
    init(shortcuts: KeyboardShortcutManager) {
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
    }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                // The window listens for this name once a Library window has
                // appeared (`LibrarySearchWindowController.attach`).
                Button(ShortcutAction.searchLibrary.title) {
                    NotificationCenter.default.post(name: .searchLibrary, object: nil)
                }
                .menuCommandKey(.searchLibrary, shortcuts: shortcuts, frontKind: front.kind)
            }
        }
    }
}

struct PlaybackCommands: Commands {
    @FocusedValue(\.canReleaseMediaControls) var canReleaseMediaControls
    /// The shortcuts, observed so Copy Reading Position's and Search in
    /// Book's key equivalents follow a change at once (FR12's branch D).
    @ObservedObject var shortcuts: KeyboardShortcutManager
    /// The window in front, observed so those items act only where their
    /// commands work (FR12's branch E).
    @ObservedObject private var front = FrontWindowKind.shared

    /// The Playback menu, its keys in force those of `shortcuts`.
    init(shortcuts: KeyboardShortcutManager) {
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                NotificationCenter.default.post(name: .togglePlayback, object: nil)
            }

            Divider()

            Button("Skip Forward") {
                NotificationCenter.default.post(name: .skipForward, object: nil)
            }

            Button("Skip Backward") {
                NotificationCenter.default.post(name: .skipBackward, object: nil)
            }

            Divider()

            Button("Cycle Forward Navigation Unit") {
                NotificationCenter.default.post(name: .cycleForwardNavigationUnit, object: nil)
            }
            // Customizable shortcuts are handled by KeyboardShortcutManager.
            // A SwiftUI keyboardShortcut here would post an untargeted duplicate.

            Button("Cycle Backward Navigation Unit") {
                NotificationCenter.default.post(name: .cycleBackwardNavigationUnit, object: nil)
            }

            Divider()

            Button("Increase Speed") {
                NotificationCenter.default.post(name: .increaseSpeed, object: nil)
            }

            Button("Decrease Speed") {
                NotificationCenter.default.post(name: .decreaseSpeed, object: nil)
            }

            Divider()

            Button("Where Am I?") {
                NotificationCenter.default.post(name: .whereAmI, object: nil)
            }

            // The full announcement (FR12, question 8). Its key, W twice
            // unless changed, is handled by KeyboardShortcutManager for
            // window targeting, and no menu can show a double press.
            Button(ShortcutAction.whereAmIFull.title) {
                NotificationCenter.default.post(name: .whereAmIFull, object: nil)
            }

            if canReleaseMediaControls == true {
                Divider()

                Button("Release Media Controls") {
                    NotificationCenter.default.post(name: .releaseMediaControls, object: nil)
                }
            }

            Divider()

            Button(ShortcutAction.copyReadingPosition.title) {
                NotificationCenter.default.post(name: .copyReadingPosition, object: nil)
            }
            .menuCommandKey(.copyReadingPosition, shortcuts: shortcuts, frontKind: front.kind)

            Button(ShortcutAction.searchInBook.title) {
                NotificationCenter.default.post(name: .searchInBook, object: nil)
            }
            .menuCommandKey(.searchInBook, shortcuts: shortcuts, frontKind: front.kind)
        }
    }
}

struct NavigationCommands: Commands {
    /// Whether the key reader reads its book from the reading list (FR09).
    @FocusedValue(\.readsFromReadingList) var readsFromReadingList
    /// Whether the key reader's book has pages (PG02), which Go to Page…
    /// needs.
    @FocusedValue(\.readerHasPages) var readerHasPages
    /// Whether the key window is a reader, so Next in Folder and Previous in
    /// Folder are offered in a reader window alone.
    @FocusedValue(\.isReaderWindow) var isReaderWindow

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Go to Library") {
                NotificationCenter.default.post(name: .goToLibrary, object: nil)
            }

            Button("Go Back") {
                NotificationCenter.default.post(name: .goBack, object: nil)
            }

            Button("Go Forward") {
                NotificationCenter.default.post(name: .goForward, object: nil)
            }

            Divider()

            Button("Next Heading") {
                NotificationCenter.default.post(name: .nextHeading, object: nil)
            }

            Button("Previous Heading") {
                NotificationCenter.default.post(name: .previousHeading, object: nil)
            }

            // Go to Page… (PG03): available while the key reader's book has
            // more than one page. Its key is the manager's, as the headings'
            // are, and in any other book it says why it opens nothing. Moving
            // from page to page is the Page navigation unit's (PG02).
            Button(ShortcutAction.goToPage.title) {
                NotificationCenter.default.post(name: .goToPage, object: nil)
            }
            .disabled(readerHasPages != true)

            Divider()

            // The book below or above this one in the reading list (FR09),
            // available while the key reader reads its book from the list.
            // They have no keys until the user gives them some, which
            // KeyboardShortcutManager handles for window targeting.
            Button(ShortcutAction.nextInReadingList.title) {
                NotificationCenter.default.post(name: .nextInReadingList, object: nil)
            }
            .disabled(readsFromReadingList != true)

            Button(ShortcutAction.previousInReadingList.title) {
                NotificationCenter.default.post(name: .previousInReadingList, object: nil)
            }
            .disabled(readsFromReadingList != true)

            // The item below or above this book in its folder or feed
            // (0.2.5), available in a reader window. They have no keys until
            // the user gives them some, as the reading list's commands.
            Button(ShortcutAction.nextInFolder.title) {
                NotificationCenter.default.post(name: .nextInFolder, object: nil)
            }
            .disabled(isReaderWindow != true)

            Button(ShortcutAction.previousInFolder.title) {
                NotificationCenter.default.post(name: .previousInFolder, object: nil)
            }
            .disabled(isReaderWindow != true)

            Divider()

            Button("Show Headings") {
                NotificationCenter.default.post(name: .showHeadingList, object: nil)
            }

            Button("Show Sleep Timer") {
                NotificationCenter.default.post(name: .showSleepTimer, object: nil)
            }

            Divider()

            Button("Book Info") {
                NotificationCenter.default.post(name: .showBookInfo, object: nil)
            }
            // Cmd+I is handled by KeyboardShortcutManager which includes window focus
            // info in the notification. Adding .keyboardShortcut here would cause
            // a second notification without focus info, opening dialogs in every window.
        }
    }
}

struct LibraryCommands: Commands {
    /// The removal preferences, observed so the Remove command's title
    /// always says what choosing it will do (TODO A08).
    @ObservedObject private var removal = RemovalPreferencesModel.shared
    /// The key Library window's selection, which the Remove command's title
    /// names as Delete Download for feed items alone (REV11 F2).
    @FocusedValue(\.libraryRemovalSelection) private var removalSelection
    /// The names of the views the key Library window offers, which the Go
    /// to View submenu lists; nil while no Library window is in front.
    @FocusedValue(\.libraryOfferedViewNames) private var offeredViewNames
    /// The shortcuts, observed so Import Folder's and Add Feed's key
    /// equivalents follow a change at once (FR12's branch D).
    @ObservedObject var shortcuts: KeyboardShortcutManager
    /// The window in front, observed so those items act only where their
    /// commands work (FR12's branch E).
    @ObservedObject private var front = FrontWindowKind.shared

    /// The Library menu, its keys in force those of `shortcuts`.
    init(shortcuts: KeyboardShortcutManager) {
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
    }

    /// Whether a Library window can take a command this menu posts: one is
    /// in front, or no window is open at all, as a menu's items must act
    /// then (`ShortcutScope.admitsMenuCommand(in:)`).
    private var libraryWindowCanTakeCommands: Bool {
        ShortcutScope.library.admitsMenuCommand(in: front.kind)
    }

    var body: some Commands {
        CommandMenu("Library") {
            // Chooses DAISY books kept as loose files by their folders, in a
            // folder-only panel the Library window presents (TODO I02). The
            // Open Book… panel stays file-only, so Return on a folder there
            // keeps opening it.
            Button(ShortcutAction.importDAISYFolder.title) {
                NotificationCenter.default.post(name: .importDAISYFolder, object: nil)
            }
            .menuCommandKey(.importDAISYFolder, shortcuts: shortcuts, frontKind: front.kind)

            // VoiceOver speaks how the imports under way have got (FR10).
            // It has no key until the user gives it one in Settings, which
            // KeyboardShortcutManager then handles from any window.
            Button(ShortcutAction.speakImportProgress.title) {
                NotificationCenter.default.post(name: .speakImportProgress, object: nil)
            }

            // VoiceOver speaks how the feed downloads under way have got,
            // as the Library window's feed downloads section says it, or that
            // none is under way, with those waiting for a network or for room
            // (FR10's feed half). No key until the user gives it one, as
            // above.
            Button(ShortcutAction.speakDownloadProgress.title) {
                NotificationCenter.default.post(name: .speakDownloadProgress, object: nil)
            }

            // Records from a microphone into a new audiobook (FR04); File >
            // New Recording… carries the shortcut. Named by its action, as
            // the File menu's item is.
            Button(ShortcutAction.newRecording.title) {
                RecordingWindowController.shared.show()
            }

            Divider()

            // Subscribes to a podcast or article feed (FR03): the key
            // Library window opens the Add Feed sheet. Its key,
            // Shift-Command-F unless changed, is no other default's.
            Button(ShortcutAction.addFeed.title) {
                NotificationCenter.default.post(name: .addFeed, object: nil)
            }
            .menuCommandKey(.addFeed, shortcuts: shortcuts, frontKind: front.kind)

            // Checks every feed now; the key Library window says what came.
            Button(FeedWording.refreshAllCommand) {
                NotificationCenter.default.post(name: .refreshAllFeeds, object: nil)
            }

            // Subscriptions in OPML, the format feed readers exchange them
            // in: the key Library window asks for the file, or says there
            // is no subscription to export. The menu never reads the feed
            // engine itself, which starts with the library.
            Button(FeedWording.importCommand) {
                NotificationCenter.default.post(name: .importOPML, object: nil)
            }

            Button(FeedWording.exportCommand) {
                NotificationCenter.default.post(name: .exportOPML, object: nil)
            }

            Divider()

            // Speaks the selected book's, folder's, or feed's information
            // with the app's own voice, as Where Am I? speaks a position
            // in a reader. Its key, Shift-Command-I, is handled by
            // KeyboardShortcutManager for window targeting; Book Info
            // (Command-I) is the Navigate menu's, and from a feed's row it
            // opens Feed Info.
            Button(ShortcutAction.speakInfo.title) {
                NotificationCenter.default.post(name: .speakInfo, object: nil)
            }

            // The selected row's full summary (FR12, question 8),
            // Shift-Command-I twice unless changed, likewise handled by
            // KeyboardShortcutManager.
            Button(ShortcutAction.speakFullInfo.title) {
                NotificationCenter.default.post(name: .speakFullInfo, object: nil)
            }

            Divider()

            Button("Edit Mode") {
                NotificationCenter.default.post(name: .toggleEditMode, object: nil)
            }
            // Cmd+E handled by KeyboardShortcutManager for window targeting

            Divider()

            Button("New Folder") {
                NotificationCenter.default.post(name: .newFolder, object: nil)
            }
            // Cmd+Shift+N handled by KeyboardShortcutManager for window targeting

            Button("Move to Folder...") {
                NotificationCenter.default.post(name: .moveToFolder, object: nil)
            }
            // Cmd+Shift+M handled by KeyboardShortcutManager for window targeting

            Divider()

            // Only a Library window takes these two, and says what it did or
            // why it could not, so they are dimmed in any other window,
            // where nothing would answer.
            Button("Move Book Up") {
                NotificationCenter.default.post(name: .moveBookUp, object: nil)
            }
            .disabled(!libraryWindowCanTakeCommands)
            // Cmd+Shift+Up handled by KeyboardShortcutManager

            Button("Move Book Down") {
                NotificationCenter.default.post(name: .moveBookDown, object: nil)
            }
            .disabled(!libraryWindowCanTakeCommands)
            // Cmd+Shift+Down handled by KeyboardShortcutManager

            Divider()

            // Adds the selected books to the end of the reading list, or
            // takes them off it (FR09): the key Library window acts on its
            // selection and says what it did, or why nothing changed. They
            // have no keys until the user gives them some in Settings,
            // which KeyboardShortcutManager handles for window targeting.
            Button(ShortcutAction.addToReadingList.title) {
                NotificationCenter.default.post(name: .addToReadingList, object: nil)
            }

            Button(ShortcutAction.removeFromReadingList.title) {
                NotificationCenter.default.post(name: .removeFromReadingList, object: nil)
            }

            // Opens the settings of the folder the Library window shows
            // (FR19), the toolbar button's command; it has no key until the
            // user gives it one in Settings.
            Button(ShortcutAction.folderOrFeedSettings.title) {
                NotificationCenter.default.post(name: .showFolderOrFeedSettings, object: nil)
            }

            // Shows one of the views the key Library window offers (design
            // section 6), each item titled by its view's name, the first
            // nine with Go to View 1 to Go to View 9's keys; while no
            // Library window is in front, one dimmed item says so.
            Menu(LibraryViewPickerWording.goToViewMenuTitle) {
                goToViewItems
            }

            Divider()

            // Keeps the selected books downloaded on this Mac, or stops, in
            // a library in the cloud (Keep on This Mac). The key Library
            // window acts on its selection, and says why when nothing changes.
            Button(LibraryCloudWording.keepName) {
                NotificationCenter.default.post(name: .keepOnThisMac, object: nil)
            }

            Button(LibraryCloudWording.stopKeepingName) {
                NotificationCenter.default.post(name: .stopKeepingOnThisMac, object: nil)
            }

            Divider()

            // "Remove from Library..." when it asks first; with confirmation
            // off it deletes at once, so it says "Move to Trash" or
            // "Delete Permanently"; with feed items alone selected, it is
            // their Delete Download, and says so (REV11 F2).
            Button(LibraryRemoveCommandWording.menuBarTitle(preferences: removal.preferences, selection: removalSelection)) {
                NotificationCenter.default.post(name: .removeFromLibrary, object: nil)
            }
            // Cmd+Delete handled by KeyboardShortcutManager for window targeting
        }
    }

    /// The Go to View submenu's items (design section 6): one for each view
    /// the key Library window offers, titled by its name, asking the window
    /// for the view by its number (`ShortcutAction.goToViewUserInfo(number:)`),
    /// the first nine showing Go to View 1 to Go to View 9's keys; or, while
    /// no Library window is in front, one dimmed item saying so.
    @ViewBuilder
    private var goToViewItems: some View {
        if let names = offeredViewNames {
            ForEach(Array(names.enumerated()), id: \.offset) { index, viewName in
                Button(viewName) {
                    NotificationCenter.default.post(name: .goToLibraryView, object: nil, userInfo: ShortcutAction.goToViewUserInfo(number: index + 1))
                }
                .goToViewKey(number: index + 1, shortcuts: shortcuts, frontKind: front.kind)
            }
        } else {
            Button(LibraryViewPickerWording.noLibraryWindow) {
                // Dimmed: there is no Library window whose view to change.
            }
            .disabled(true)
        }
    }
}

/// The Bookmarks menu. Each item is titled from its action's name, the one
/// the Shortcuts tab, config.json, and every message use, so the menu and
/// the Shortcuts tab cannot drift apart again (#1937).
struct BookmarkCommands: Commands {
    var body: some Commands {
        CommandMenu("Bookmarks") {
            Button(ShortcutAction.addBookmark.rawValue) {
                NotificationCenter.default.post(name: .addBookmark, object: nil)
            }

            Button(ShortcutAction.showBookmarkList.rawValue) {
                NotificationCenter.default.post(name: .showBookmarkList, object: nil)
            }

            Divider()

            Button(ShortcutAction.nextBookmark.rawValue) {
                NotificationCenter.default.post(name: .nextBookmark, object: nil)
            }

            Button(ShortcutAction.previousBookmark.rawValue) {
                NotificationCenter.default.post(name: .previousBookmark, object: nil)
            }
        }
    }
}

/// Whether the book of the reader whose window is key has text that Edit
/// Text can open (FR05): a text book's, or a transcribed audiobook's. The
/// reader publishes it as a scene value (`ReaderBookCommandsSupport`).
struct CanEditBookTextKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canEditBookText: Bool? {
        get { self[CanEditBookTextKey.self] }
        set { self[CanEditBookTextKey.self] = newValue }
    }
}

/// Whether the book of the reader whose window is key is an audiobook of
/// tracks whose manifest Edit Manifest can open (FR17). The reader
/// publishes it as a scene value (`ReaderBookCommandsSupport`).
struct CanEditBookManifestKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canEditBookManifest: Bool? {
        get { self[CanEditBookManifestKey.self] }
        set { self[CanEditBookManifestKey.self] = newValue }
    }
}

/// Whether the book of the reader whose window is key is an audiobook that
/// Transcribe Audio… can transcribe (FR05). The reader publishes it as a
/// scene value (`ReaderBookCommandsSupport`).
struct CanTranscribeBookAudioKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canTranscribeBookAudio: Bool? {
        get { self[CanTranscribeBookAudioKey.self] }
        set { self[CanTranscribeBookAudioKey.self] = newValue }
    }
}

/// Whether the book of the reader whose window is key is an audiobook that
/// Attach Transcript… can give a transcript from a file (FMT23): one in a
/// package of its own that no transcript is being attached to already
/// (`TranscriptAttachments.canAttach`). The reader publishes it as a scene
/// value (`ReaderBookCommandsSupport`).
struct CanAttachBookTranscriptKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canAttachBookTranscript: Bool? {
        get { self[CanAttachBookTranscriptKey.self] }
        set { self[CanAttachBookTranscriptKey.self] = newValue }
    }
}

/// Whether the book of the reader whose window is key is a transcribed
/// audiobook whose transcript Delete Transcript… can delete (FR05). The
/// reader publishes it as a scene value (`ReaderBookCommandsSupport`).
struct CanDeleteBookTranscriptKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canDeleteBookTranscript: Bool? {
        get { self[CanDeleteBookTranscriptKey.self] }
        set { self[CanDeleteBookTranscriptKey.self] = newValue }
    }
}

/// The commands that act on a book as a whole, wherever it was chosen
/// (FR05). File > Export… exports the book of the reader that is key, or
/// the books selected in the Library window that is key, which each
/// decides for itself through `WindowCommandRouting`. The reader's Book
/// menu opens its book's text in the user's own editor, and transcribes an
/// audiobook's audio (Retranscribe Audio… once it has a transcript),
/// attaches a WebVTT or SubRip file as its transcript instead (Attach
/// Transcript…, FMT23), cleans up its transcript, or deletes it, and Edit
/// Audio… opens an audiobook in the audio editor (FR04);
/// MenuVisibilityManager shows it only while a reader is in front. Edit
/// Text is unavailable for an audiobook without a transcript, Edit Manifest
/// for any book but an audiobook of tracks (FR17), Transcribe
/// Audio… and Edit Audio… for a text book, Attach Transcript… for a text
/// book and while a transcript is being attached to the book, and Clean Up
/// Transcript (Experimental)… and Delete Transcript… for a book without a
/// transcript.
/// Move to Library… moves an episode or article out of its feed into a
/// folder of the library (FR11, branch D), and is unavailable for any other
/// book.
struct BookCommands: Commands {
    @FocusedValue(\.canEditBookText) var canEditBookText
    @FocusedValue(\.canEditBookManifest) var canEditBookManifest
    @FocusedValue(\.canTranscribeBookAudio) var canTranscribeBookAudio
    @FocusedValue(\.canAttachBookTranscript) var canAttachBookTranscript
    @FocusedValue(\.canCleanUpBookTranscript) var canCleanUpBookTranscript
    @FocusedValue(\.canDeleteBookTranscript) var canDeleteBookTranscript
    @FocusedValue(\.canEditBookAudio) var canEditBookAudio
    @FocusedValue(\.canMoveBookToLibrary) var canMoveBookToLibrary

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button(BookExportWording.commandTitle) {
                // The window in front exports, or VoiceOver hears why
                // nothing can be exported, as when only Settings is open.
                ExportCommandRouting.exportFromWindowInFront()
            }
        }

        CommandMenu("Book") {
            Button(BookTextEditWording.editTitle) {
                NotificationCenter.default.post(name: .editBookText, object: nil)
            }
            .disabled(canEditBookText != true)

            Button(BookTextEditWording.editWithTitle) {
                NotificationCenter.default.post(name: .editBookTextWith, object: nil)
            }
            .disabled(canEditBookText != true)

            // An audiobook of tracks' manifest.json in the user's own
            // editor (FR17).
            Button(BookManifestEditWording.editTitle) {
                NotificationCenter.default.post(name: .editBookManifest, object: nil)
            }
            .disabled(canEditBookManifest != true)

            Button(BookManifestEditWording.editWithTitle) {
                NotificationCenter.default.post(name: .editBookManifestWith, object: nil)
            }
            .disabled(canEditBookManifest != true)

            Divider()

            // Delete Transcript… is available exactly while the key reader's
            // book has a transcript (`ReaderBookCommandsSupport.hasTranscript`),
            // so that is when the command retranscribes.
            Button(TranscriptionWording.transcribeCommandTitle(hasTranscript: canDeleteBookTranscript == true)) {
                NotificationCenter.default.post(name: .transcribeBookAudio, object: nil)
            }
            .disabled(canTranscribeBookAudio != true)

            // A WebVTT or SubRip file as the audiobook's transcript, in
            // place of transcribing it (FMT23); dimmed while one is being
            // attached to the book.
            Button(TranscriptionWording.attachCommandTitle) {
                NotificationCenter.default.post(name: .attachBookTranscript, object: nil)
            }
            .disabled(canAttachBookTranscript != true)

            Button(TranscriptCleanupWording.commandTitle) {
                NotificationCenter.default.post(name: .cleanUpBookTranscript, object: nil)
            }
            .disabled(canCleanUpBookTranscript != true)

            Button(TranscriptionWording.deleteCommandTitle) {
                NotificationCenter.default.post(name: .deleteBookTranscript, object: nil)
            }
            .disabled(canDeleteBookTranscript != true)

            Divider()

            // The audiobook's audio in the audio editor (FR04).
            Button(AudioEditorWording.editAudioCommand) {
                NotificationCenter.default.post(name: .editBookAudio, object: nil)
            }
            .disabled(canEditBookAudio != true)

            Divider()

            // An episode or article out of its feed into a folder of the
            // library, as a book of its own (FR11, branch D). It has no key
            // until the user gives it one in Settings, which
            // KeyboardShortcutManager handles for window targeting.
            Button(ShortcutAction.moveToLibrary.title) {
                NotificationCenter.default.post(name: .moveToLibrary, object: nil)
            }
            .disabled(canMoveBookToLibrary != true)
        }
    }
}

/// Whether the book of the reader whose window is key is an episode or
/// article downloaded in its feed, which Move to Library… can move into the
/// library (FR11, branch D). The reader publishes it as a scene value
/// (`ReaderBookCommandsSupport`).
struct CanMoveBookToLibraryKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canMoveBookToLibrary: Bool? {
        get { self[CanMoveBookToLibraryKey.self] }
        set { self[CanMoveBookToLibraryKey.self] = newValue }
    }
}

extension View {
    /// A menu item for `action`, whose key the user may change (FR12's
    /// branches D and E): it shows `action`'s key in force and acts while
    /// `action` works where the window in front is (`frontKind`,
    /// `ShortcutScope.admitsMenuCommand(in:)`); elsewhere it has no key, so
    /// the key goes on to the window's own action, and is dimmed, doing
    /// nothing there. The menu observes `shortcuts` and the front window, so
    /// the item follows each.
    func menuCommandKey(_ action: ShortcutAction, shortcuts: KeyboardShortcutManager, frontKind: ShortcutWindowKind?) -> some View {
        let acts = shortcuts.scope(of: action).admitsMenuCommand(in: frontKind)
        return keyboardShortcut(acts ? shortcuts.keyboardShortcut(for: action) : nil)
            .disabled(!acts)
    }

    /// The Go to View submenu's item for the `number`th view (design
    /// section 6 of LIBRARY-VIEWS-RESEARCH-2026-10-30.md): it shows the key
    /// of the action going to that view, Go to View 1 to Go to View 9, as
    /// `shortcuts` has it in force (`menuShownKey(for:frontKind:)`), so
    /// VoiceOver says the key beside the view's name; an item past the ninth
    /// shows none. The shortcut manager takes these keys itself, for the
    /// window they are pressed in, and meets a key before the menus do, so
    /// the item never acts on its key a second time: only choosing it acts.
    func goToViewKey(number: Int, shortcuts: KeyboardShortcutManager, frontKind: ShortcutWindowKind?) -> some View {
        keyboardShortcut(ShortcutAction.goToView(number: number).flatMap { shortcuts.menuShownKey(for: $0, frontKind: frontKind) })
    }
}

// MARK: - Key Equivalents in Force (FR12's Branch D)

extension KeyboardShortcutManager {
    /// `action`'s key in force as its menu item or button takes it: its key
    /// equivalent (`keyEquivalent(for:)`), or nil for none, so the item
    /// shows no key rather than one that does something else.
    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        keyEquivalent(for: action)?.keyboardShortcut
    }

    /// The key a menu item shows for `action`, whose keys this manager
    /// takes rather than a menu item (design section 6, Go to View): its
    /// first key in force that a menu item can show
    /// (`KeyBinding.keyboardShortcut`), while its keys work in windows of
    /// `frontKind`; nil otherwise, as with no window in front, so the item
    /// never shows a key that does something else there.
    func menuShownKey(for action: ShortcutAction, frontKind: ShortcutWindowKind?) -> KeyboardShortcut? {
        guard let frontKind, scope(of: action).reaches(frontKind) else { return nil }
        return bindingsFor(action).lazy.compactMap(\.keyboardShortcut).first
    }
}

extension KeyBinding {
    /// The binding as SwiftUI's key equivalent, for a menu item or a button:
    /// its key with its modifiers; nil for a binding that cannot be a key
    /// equivalent (`canBeKeyEquivalent`), a double press among them.
    var keyboardShortcut: KeyboardShortcut? {
        guard canBeKeyEquivalent, let key = keyEquivalent else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// The key as SwiftUI names it: Space, Tab, Return, and Escape by name,
    /// and any other key by the one character a binding holds for it, the
    /// character AppKit gives a function key included, which a menu item
    /// takes as that key. The arrows and Delete never come here: a text field
    /// edits with them, so no key equivalent may have them.
    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "tab": return .tab
        case "return": return .return
        case "escape": return .escape
        default: return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let refreshContextMenus = Notification.Name("refreshContextMenus")
    static let togglePlayback = Notification.Name("togglePlayback")
    static let releaseMediaControls = Notification.Name("releaseMediaControls")
    static let skipForward = Notification.Name("skipForward")
    static let skipBackward = Notification.Name("skipBackward")
    static let cycleForwardNavigationUnit = Notification.Name("cycleForwardNavigationUnit")
    static let cycleBackwardNavigationUnit = Notification.Name("cycleBackwardNavigationUnit")
    static let increaseSpeed = Notification.Name("increaseSpeed")
    static let decreaseSpeed = Notification.Name("decreaseSpeed")
    static let nextHeading = Notification.Name("nextHeading")
    static let previousHeading = Notification.Name("previousHeading")
    /// Posted by Navigate > Go to Page…, and by its key (PG03): the key
    /// reader opens its page field.
    static let goToPage = Notification.Name("goToPage")
    /// Posted by Navigate > Next in Reading List, and by its key when the
    /// user gave it one (FR09): the key reader, reading its book from the
    /// reading list, opens the book below it there.
    static let nextInReadingList = Notification.Name("nextInReadingList")
    /// Posted by Navigate > Previous in Reading List, and by its key when
    /// the user gave it one (FR09): the key reader, reading its book from
    /// the reading list, opens the book above it there.
    static let previousInReadingList = Notification.Name("previousInReadingList")
    static let nextInFolder = Notification.Name("nextInFolder")
    static let previousInFolder = Notification.Name("previousInFolder")
    static let addBookmark = Notification.Name("addBookmark")
    static let nextBookmark = Notification.Name("nextBookmark")
    static let previousBookmark = Notification.Name("previousBookmark")
    static let goToLibrary = Notification.Name("goToLibrary")
    static let goBack = Notification.Name("goBack")
    static let goForward = Notification.Name("goForward")
    static let navigateUpLevel = Notification.Name("navigateUpLevel")
    static let whereAmI = Notification.Name("whereAmI")
    /// Posted by Playback > Where Am I? Full Summary and its key, W twice
    /// unless the user changed it (FR12): the key reader speaks its full
    /// Where Am I? announcement.
    static let whereAmIFull = Notification.Name("whereAmIFull")
    static let openBookFile = Notification.Name("openBookFile")
    /// Posted by Library > Import Folder…. One Library window
    /// presents the folder-only panel and imports the folders chosen.
    static let importDAISYFolder = Notification.Name("importDAISYFolder")
    static let showBookInfo = Notification.Name("showBookInfo")
    /// Posted by Library > Speak Info and its key, Shift-Command-I: the
    /// Library window that takes the command speaks its selected row's
    /// information with the app's own voice (`LibraryInfoSpeaker`), and the
    /// reader window it is pressed in speaks its book's information, in the
    /// same words (`ReaderViewModel.speakInfo(_:now:)`).
    static let speakInfo = Notification.Name("speakInfo")
    /// Posted by Library > Speak Full Info and its key, Shift-Command-I
    /// twice unless the user changed it (FR12): the Library window that
    /// takes the command speaks its selected row's full summary
    /// (`LibraryInfoSpeaker`).
    static let speakFullInfo = Notification.Name("speakFullInfo")
    /// Posted by Library > Speak Import Progress and its key, when the user
    /// gave it one: the library model has VoiceOver speak how the imports
    /// under way have got (FR10).
    static let speakImportProgress = Notification.Name("speakImportProgress")
    /// Posted by Library > Speak Download Progress and its key, when the
    /// user gave it one: the library model has VoiceOver speak how the feed
    /// downloads under way have got (FR10's feed half).
    static let speakDownloadProgress = Notification.Name("speakDownloadProgress")
    static let openSelectedBook = Notification.Name("openSelectedBook")
    static let copyReadingPosition = Notification.Name("copyReadingPosition")
    static let searchInBook = Notification.Name("searchInBook")
    static let newFromText = Notification.Name("newFromText")
    /// Posted by a reader whose book finished with Continue to Next Book,
    /// once it has left the next book a request to start playing
    /// (`ReaderAutoplayRequests`). `userInfo` names the next book and the
    /// finished one (`Notification.ContinueToNextBookKey`). The app opens
    /// the next book's reader window, or brings it forward when it is
    /// already open, and that reader claims the request and plays.
    static let continueToNextBook = Notification.Name("continueToNextBook")
    static let removeFromLibrary = Notification.Name("removeFromLibrary")
    static let newFolder = Notification.Name("newFolder")
    static let moveToFolder = Notification.Name("moveToFolder")
    /// Posted by Book > Move to Library…, and by its key when the user gave
    /// it one (FR11, branch D): the key reader, or the Library window that
    /// takes it, asks which folder to move its episode or article, or its
    /// selected ones, into as books of the library's own.
    static let moveToLibrary = Notification.Name("moveToLibrary")
    static let selectAll = Notification.Name("selectAll")
    static let toggleEditMode = Notification.Name("toggleEditMode")
    static let moveBookUp = Notification.Name("moveBookUp")
    static let moveBookDown = Notification.Name("moveBookDown")
    /// Posted by Library > Add to Reading List, and by its key when the
    /// user gave it one (FR09): the Library window that takes it adds its
    /// selected books to the reading list.
    static let addToReadingList = Notification.Name("addToReadingList")
    /// Posted by Library > Remove from Reading List, and by its key when
    /// the user gave it one (FR09): the Library window that takes it takes
    /// its selected books off the reading list.
    static let removeFromReadingList = Notification.Name("removeFromReadingList")
    /// Posted by Library > Folder or Feed Settings, and by its key when the
    /// user gave it one (FR19): the Library window that takes it opens the
    /// settings of the folder it shows, or says there is none.
    static let showFolderOrFeedSettings = Notification.Name("showFolderOrFeedSettings")
    /// Posted by Library > Keep on This Mac: the key Library window keeps
    /// its selected books downloaded on this Mac.
    static let keepOnThisMac = Notification.Name("keepOnThisMac")
    /// Posted by Library > Stop Keeping on This Mac: the key Library window
    /// stops keeping its selected books on this Mac.
    static let stopKeepingOnThisMac = Notification.Name("stopKeepingOnThisMac")
    static let showHeadingList = Notification.Name("showHeadingList")
    static let showBookmarkList = Notification.Name("showBookmarkList")
    static let showSleepTimer = Notification.Name("showSleepTimer")
    /// Posted by either the Restart Sleep Timer keyboard shortcut or
    /// the experimental media-gesture detector. ReaderViewModel
    /// listens and either restarts a running timer or re-arms a new
    /// one with the previous duration.
    static let restartSleepTimer = Notification.Name("restartSleepTimer")
    /// Posted by File > Export… (FR05): the key reader opens the Export
    /// dialog for its book, or the key Library window for its selection.
    static let exportBooks = Notification.Name("exportBooks")
    /// Posted by Book > Edit Text in Default Editor (FR05): the key reader
    /// opens its book's text in the default app for Markdown.
    static let editBookText = Notification.Name("editBookText")
    /// Posted by Book > Edit Text With… (FR05): the key reader asks which
    /// app to open its book's text in.
    static let editBookTextWith = Notification.Name("editBookTextWith")
    /// Posted by Book > Edit Manifest in Default Editor (FR17): the key
    /// reader opens its audiobook's manifest.json in the default app for JSON.
    static let editBookManifest = Notification.Name("editBookManifest")
    /// Posted by Book > Edit Manifest With… (FR17): the key reader asks
    /// which app to open its audiobook's manifest.json in.
    static let editBookManifestWith = Notification.Name("editBookManifestWith")
    /// Posted by Book > Transcribe Audio… (FR05): the key reader opens the
    /// Transcribe Audio sheet for its audiobook.
    static let transcribeBookAudio = Notification.Name("transcribeBookAudio")
    /// Posted by Book > Attach Transcript… (FMT23): the key reader asks for
    /// a WebVTT or SubRip file to make its audiobook's transcript.
    static let attachBookTranscript = Notification.Name("attachBookTranscript")
    /// Posted by Book > Delete Transcript… (FR05): the key reader asks to
    /// delete its audiobook's transcript.
    static let deleteBookTranscript = Notification.Name("deleteBookTranscript")
}
