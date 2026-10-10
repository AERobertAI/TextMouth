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

// MARK: - Menu Commands

struct PlaybackCommands: Commands {
    @FocusedValue(\.canReleaseMediaControls) var canReleaseMediaControls
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

            Button("Copy Reading Position") {
                NotificationCenter.default.post(name: .copyReadingPosition, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Search in Book") {
                NotificationCenter.default.post(name: .searchInBook, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

struct NavigationCommands: Commands {
    /// Whether the key reader reads its book from the reading list (FR09).
    @FocusedValue(\.readsFromReadingList) var readsFromReadingList

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

    var body: some Commands {
        CommandMenu("Library") {
            // Chooses DAISY books kept as loose files by their folders, in a
            // folder-only panel the Library window presents (TODO I02). The
            // Open Book... panel stays file-only, so Return on a folder there
            // keeps opening it.
            Button("Import DAISY Folder…") {
                NotificationCenter.default.post(name: .importDAISYFolder, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            // VoiceOver speaks how the imports under way have got (FR10).
            // It has no key until the user gives it one in Settings, which
            // KeyboardShortcutManager then handles from any window.
            Button(ShortcutAction.speakImportProgress.title) {
                NotificationCenter.default.post(name: .speakImportProgress, object: nil)
            }

            // Records from a microphone into a new audiobook (FR04); File >
            // New Recording… carries the shortcut.
            Button(RecordingWording.menuTitle) {
                RecordingWindowController.shared.show()
            }

            Divider()

            // Subscribes to a podcast or article feed (FR03): the key
            // Library window opens the Add Feed sheet. Shift-Command-F is
            // used by no other command or default shortcut.
            Button(FeedWording.addFeedCommand) {
                NotificationCenter.default.post(name: .addFeed, object: nil)
            }
            .keyboardShortcut(FeedShortcuts.addFeed)

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
            // in a reader. Its key, I, is handled by KeyboardShortcutManager
            // for window targeting; Book Info (Command-I) is the Navigate
            // menu's, and from a feed's row it opens Feed Info.
            Button(ShortcutAction.speakInfo.title) {
                NotificationCenter.default.post(name: .speakInfo, object: nil)
            }

            // The selected row's full summary (FR12, question 8), I twice
            // unless changed, likewise handled by KeyboardShortcutManager.
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

            Button("Move Book Up") {
                NotificationCenter.default.post(name: .moveBookUp, object: nil)
            }
            // Cmd+Shift+Up handled by KeyboardShortcutManager

            Button("Move Book Down") {
                NotificationCenter.default.post(name: .moveBookDown, object: nil)
            }
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
            // "Delete Permanently".
            Button(LibraryRemoveCommandWording.menuBarTitle(preferences: removal.preferences)) {
                NotificationCenter.default.post(name: .removeFromLibrary, object: nil)
            }
            // Cmd+Delete handled by KeyboardShortcutManager for window targeting
        }
    }
}

struct BookmarkCommands: Commands {
    var body: some Commands {
        CommandMenu("Bookmarks") {
            Button("Toggle Bookmark") {
                NotificationCenter.default.post(name: .addBookmark, object: nil)
            }

            Button("Show Bookmarks") {
                NotificationCenter.default.post(name: .showBookmarkList, object: nil)
            }

            Divider()

            Button("Next Bookmark") {
                NotificationCenter.default.post(name: .nextBookmark, object: nil)
            }

            Button("Previous Bookmark") {
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
/// audiobook's audio, cleans up its transcript, or deletes it, and Edit
/// Audio… opens an audiobook in the audio editor (FR04);
/// MenuVisibilityManager shows it only while a reader is in front. Edit
/// Text is unavailable for an audiobook without a transcript, Transcribe
/// Audio… and Edit Audio… for a text book, and Clean Up Transcript
/// (Experimental)… and Delete Transcript… for a book without a transcript.
struct BookCommands: Commands {
    @FocusedValue(\.canEditBookText) var canEditBookText
    @FocusedValue(\.canTranscribeBookAudio) var canTranscribeBookAudio
    @FocusedValue(\.canCleanUpBookTranscript) var canCleanUpBookTranscript
    @FocusedValue(\.canDeleteBookTranscript) var canDeleteBookTranscript
    @FocusedValue(\.canEditBookAudio) var canEditBookAudio

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

            Divider()

            Button(TranscriptionWording.transcribeCommandTitle) {
                NotificationCenter.default.post(name: .transcribeBookAudio, object: nil)
            }
            .disabled(canTranscribeBookAudio != true)

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
    /// Posted by Navigate > Next in Reading List, and by its key when the
    /// user gave it one (FR09): the key reader, reading its book from the
    /// reading list, opens the book below it there.
    static let nextInReadingList = Notification.Name("nextInReadingList")
    /// Posted by Navigate > Previous in Reading List, and by its key when
    /// the user gave it one (FR09): the key reader, reading its book from
    /// the reading list, opens the book above it there.
    static let previousInReadingList = Notification.Name("previousInReadingList")
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
    /// Posted by Library > Import DAISY Folder…. One Library window
    /// presents the folder-only panel and imports the folders chosen.
    static let importDAISYFolder = Notification.Name("importDAISYFolder")
    static let showBookInfo = Notification.Name("showBookInfo")
    /// Posted by Library > Speak Info and the I key: the Library window
    /// that takes the command speaks its selected row's information with
    /// the app's own voice (`LibraryInfoSpeaker`).
    static let speakInfo = Notification.Name("speakInfo")
    /// Posted by Library > Speak Full Info and its key, I twice unless the
    /// user changed it (FR12): the Library window that takes the command
    /// speaks its selected row's full summary (`LibraryInfoSpeaker`).
    static let speakFullInfo = Notification.Name("speakFullInfo")
    /// Posted by Library > Speak Import Progress and its key, when the user
    /// gave it one: the library model has VoiceOver speak how the imports
    /// under way have got (FR10).
    static let speakImportProgress = Notification.Name("speakImportProgress")
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
    /// Posted by Book > Transcribe Audio… (FR05): the key reader opens the
    /// Transcribe Audio sheet for its audiobook.
    static let transcribeBookAudio = Notification.Name("transcribeBookAudio")
    /// Posted by Book > Delete Transcript… (FR05): the key reader asks to
    /// delete its audiobook's transcript.
    static let deleteBookTranscript = Notification.Name("deleteBookTranscript")
}
