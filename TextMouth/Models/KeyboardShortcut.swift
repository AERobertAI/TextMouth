#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// All actions that can have keyboard shortcuts
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePlayback = "Play / Pause"
    case releaseMediaControls = "Release Media Controls"
    case skipForward = "Skip Forward"
    case skipBackward = "Skip Backward"
    case cycleForwardNavigationUnit = "Cycle Forward Navigation Unit"
    case cycleBackwardNavigationUnit = "Cycle Backward Navigation Unit"
    case increaseSpeed = "Increase Speed"
    case decreaseSpeed = "Decrease Speed"
    /// Playback > Copy Reading Position, a menu command whose key is its
    /// menu item's key equivalent (FR12's branch D, `isKeyEquivalent`).
    case copyReadingPosition = "Copy Reading Position"
    /// Playback > Search in Book, a menu command whose key is its menu
    /// item's key equivalent (FR12's branch D).
    case searchInBook = "Search in Book"
    case goToLibrary = "Go to Library"
    case goBack = "Go Back"
    case goForward = "Go Forward"
    case nextHeading = "Next Heading"
    case previousHeading = "Previous Heading"
    /// Navigate > Go to Page…: opens the reader's page field, where the user
    /// types a page as the book numbers it (PG03).
    case goToPage = "Go to Page…"
    /// Opens the book below this one in the reading list, for a book read
    /// from the list (FR09). It has no key until the user gives it one in
    /// Settings.
    case nextInReadingList = "Next in Reading List"
    /// Opens the book above this one in the reading list, for a book read
    /// from the list (FR09). It has no key until the user gives it one in
    /// Settings.
    case previousInReadingList = "Previous in Reading List"
    /// Goes to the item below this book in its folder, or in its feed
    /// (0.2.5): it plays when this book was playing, and only opens
    /// otherwise. It has no key until the user gives it one in Settings.
    case nextInFolder = "Next in Folder"
    /// Goes to the item above this book in its folder, or in its feed
    /// (0.2.5), as Next in Folder goes below. It has no key until the user
    /// gives it one in Settings.
    case previousInFolder = "Previous in Folder"
    // Up One Level last of the Navigation group, and Show Bookmarks last of
    // the Bookmarks group, as the Shortcuts tab lists them: `allCases` is
    // Settings order, which the record of edits, the press index, and the
    // settling of a key two edited actions share all follow (#1528).
    case navigateUpLevel = "Up One Level"
    /// Adds a bookmark at the reading position, or removes the one there:
    /// the Bookmarks menu's item of the same name. It was named Add Bookmark
    /// in Settings and config.json until October 12, 2026, a name still read
    /// (`formerNames`, #1937).
    case addBookmark = "Toggle Bookmark"
    case nextBookmark = "Next Bookmark"
    case previousBookmark = "Previous Bookmark"
    case showBookmarkList = "Show Bookmarks"
    case showHeadingList = "Show Headings"
    case showSleepTimer = "Show Sleep Timer"
    case restartSleepTimer = "Restart Sleep Timer"
    case whereAmI = "Where Am I?"
    /// Speaks a reader's full Where Am I? announcement, W twice by default
    /// (FR12): the first W speaks the brief one at once, and a second within
    /// the double-press time switches to this one, which escalates it
    /// (`escalates`).
    case whereAmIFull = "Where Am I? Full Summary"
    /// Speaks the selected book's, folder's, or feed's information in
    /// the Library window with the app's own voice, as Where Am I? speaks
    /// a position in a reader (`LibraryInfoSpeaker`); in a reader window it
    /// speaks the reader's own book's information, announced as the
    /// reader's other spoken commands are (`ReaderViewModel.speakInfo(_:now:)`).
    case speakInfo = "Speak Info"
    /// Speaks the selected row's full summary in the Library window,
    /// Shift-Command-I twice by default (FR12), escalating Speak Info as
    /// Where Am I? Full Summary escalates Where Am I?.
    case speakFullInfo = "Speak Full Info"
    /// Has VoiceOver speak how the imports under way have got, as the
    /// import overlay says it, from any window (FR10). It has no key until
    /// the user gives it one in Settings.
    case speakImportProgress = "Speak Import Progress"
    /// Has VoiceOver speak how the feed downloads under way have got, as
    /// the Library window's feed downloads section says it, from any window
    /// (FR10's feed half). It has no key until the user gives it one in
    /// Settings.
    case speakDownloadProgress = "Speak Download Progress"
    case openSelectedBook = "Open Selected Book"
    case showBookInfo = "Book Info"
    case removeFromLibrary = "Remove from Library"
    case newFolder = "New Folder"
    case moveToFolder = "Move to Folder"
    /// Moves the selected episodes and articles, or a reader's, from their
    /// feeds into a folder of the library as books of its own, after asking
    /// which folder (FR11, branch D): the item's context menu, its VoiceOver
    /// actions, and the reader's Book menu offer it. It has no key until the
    /// user gives it one in Settings.
    case moveToLibrary = "Move to Library…"
    case selectAll = "Select All"
    case toggleEditMode = "Edit Mode"
    case moveBookUp = "Move Book Up"
    case moveBookDown = "Move Book Down"
    /// Adds the selected books to the end of the reading list (FR09). It
    /// has no key until the user gives it one in Settings.
    case addToReadingList = "Add to Reading List"
    /// Takes the selected books off the reading list (FR09). It has no key
    /// until the user gives it one in Settings.
    case removeFromReadingList = "Remove from Reading List"
    /// Opens the settings of the folder the Library window shows (FR19): Feed
    /// Info in a feed's folder, Folder Settings in a plain folder, as the
    /// toolbar's Feed Settings or Folder Settings button does. It has no key
    /// until the user gives it one in Settings.
    case folderOrFeedSettings = "Folder or Feed Settings"
    // Go to View 1 to Go to View 9 (the design of October 30, 2026,
    // LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 6), Command-1 to
    // Command-9 by default, in Library windows: the window shows the first
    // to the ninth view its View pop-up offers, counting those offered always
    // and when applicable, never one kept there only because the window
    // shows it, so a key always goes to the same view; and it says the
    // view's name and what it lists, or, for a key with no view, that there
    // is none. The Library menu's Go to View submenu shows each key beside
    // its view.
    case goToView1 = "Go to View 1"
    case goToView2 = "Go to View 2"
    case goToView3 = "Go to View 3"
    case goToView4 = "Go to View 4"
    case goToView5 = "Go to View 5"
    case goToView6 = "Go to View 6"
    case goToView7 = "Go to View 7"
    case goToView8 = "Go to View 8"
    case goToView9 = "Go to View 9"
    /// Library > Import Folder…, a menu command whose key is its menu item's
    /// key equivalent (FR12's branch D), for DAISY books and folders of audio
    /// tracks (FR17). It was Import DAISY Folder… until October 14, 2026,
    /// a name `formerNames` still reads, so a key the user gave it keeps
    /// working.
    case importDAISYFolder = "Import Folder…"
    /// Library > Add Feed…, a menu command whose key is its menu item's key
    /// equivalent (FR12's branch D).
    case addFeed = "Add Feed…"
    /// Edit > Find > Search Library…, a menu command whose key is its menu
    /// item's key equivalent, as Search in Book's is. It opens the Search
    /// Library window, which searches the text of every book, from any
    /// window. It is listed last of the Library group, whose actions the
    /// Shortcuts tab lists whole and in `allCases` order (#1528), though its
    /// menu is Edit's.
    case searchLibrary = "Search Library…"

    // The File menu's commands (FR12's branch D): a group named as their
    // menu is, each a key equivalent of its menu item.
    case openBook = "Open Book…"
    case newFromText = "New from Text…"
    case newRecording = "New Recording…"

    // The Record window's buttons (FR12's branch D): a group of their own,
    // each a key equivalent of its button, whose raw values begin with the
    // group's name, the window's own as VoiceOver reads it, as the audio
    // editor's do, so config.json never takes the window's Stop for another.
    // Their former names, under "Recording Window", are still read
    // (`formerNames`).
    case recordingRecord = "New Recording: Record"
    case recordingPauseOrResume = "New Recording: Pause or Resume"
    case recordingStop = "New Recording: Stop"

    // The audio editor's (FR04): a group of their own, matched only while an
    // editor window is key (`ShortcutScope`), so they may share keys with
    // the reader's. Each raw value begins with the group's name, so
    // config.json tells them apart from the reader's actions of the same
    // name; Settings lists them by `title`, under the group's heading.
    case editorPlayPause = "Audio Editor: Play / Pause"
    case editorStop = "Audio Editor: Stop"
    case editorSkipBack = "Audio Editor: Back One Second"
    case editorSkipForward = "Audio Editor: Forward One Second"
    case editorSkipBackLong = "Audio Editor: Back 10 Seconds"
    case editorSkipForwardLong = "Audio Editor: Forward 10 Seconds"
    case editorSkipBackShort = "Audio Editor: Back a Tenth of a Second"
    case editorSkipForwardShort = "Audio Editor: Forward a Tenth of a Second"
    case editorGoToStart = "Audio Editor: Go to Start"
    case editorGoToEnd = "Audio Editor: Go to End"
    case editorGoToTime = "Audio Editor: Go to Time…"
    case editorPreviousChapter = "Audio Editor: Previous Chapter Marker"
    case editorNextChapter = "Audio Editor: Next Chapter Marker"
    case editorPreviousPause = "Audio Editor: Previous Pause"
    case editorNextPause = "Audio Editor: Next Pause"
    case editorWhereAmI = "Audio Editor: Where Am I?"
    case editorMarkIn = "Audio Editor: Mark In"
    case editorMarkOut = "Audio Editor: Mark Out"
    case editorSelectToPreviousPause = "Audio Editor: Select to Previous Pause"
    case editorSelectToNextPause = "Audio Editor: Select to Next Pause"
    case editorSelectChapter = "Audio Editor: Select Chapter"
    case editorSelectAll = "Audio Editor: Select All"
    case editorClearSelection = "Audio Editor: Clear Selection"
    case editorSpeakSelection = "Audio Editor: Speak Selection"
    case editorPlaySelection = "Audio Editor: Play Selection"
    case editorAddMarker = "Audio Editor: Add Marker"
    case editorShowMarkers = "Audio Editor: Markers and Pauses…"
    case editorUndo = "Audio Editor: Undo"
    case editorRedo = "Audio Editor: Redo"
    case editorCut = "Audio Editor: Cut"
    case editorCopy = "Audio Editor: Copy"
    case editorPaste = "Audio Editor: Paste"
    case editorTrimToSelection = "Audio Editor: Trim to Selection"
    case editorInsertSilence = "Audio Editor: Insert Silence…"
    case editorInsertChapter = "Audio Editor: Insert Chapter Marker…"
    case editorApplyFilter = "Audio Editor: Apply Filter…"
    case editorPunchIn = "Audio Editor: Punch In"
    case editorSave = "Audio Editor: Save"
    case editorExport = "Audio Editor: Export…"
    case editorRevert = "Audio Editor: Revert to Original…"
    case editorInfo = "Audio Editor: Audio Info…"

    var id: String { rawValue }

    /// The heading of the audio editor's group in Settings, and the start
    /// of each of its actions' raw values.
    static let audioEditorCategory = "Audio Editor"
    /// The heading of the File menu's commands in Settings (FR12's branch
    /// D), named as their menu is.
    static let fileCategory = "File"
    /// The heading of the Record window's buttons in Settings (FR12's
    /// branch D), and the start of each of their raw values: the window's
    /// title, New Recording, as VoiceOver names the window
    /// (`RecordingWording.windowTitle`, a test checks), where the group was
    /// once named "Recording Window", a name the window never shows (REV11).
    static let recordingWindowCategory = "New Recording"
    /// The groups whose actions' raw values begin with the group's name and
    /// a colon, so config.json tells them apart from actions of the same name
    /// elsewhere: the audio editor's Play / Pause from the reader's, the
    /// Record window's Stop from the editor's.
    private static let groupsNamingTheirActions = [audioEditorCategory, recordingWindowCategory]

    /// The action's name as Settings lists it under its group's heading:
    /// its raw value, less the group's name that begins the raw value of an
    /// action of the audio editor or the Record window.
    var title: String {
        for group in Self.groupsNamingTheirActions {
            let prefix = group + ": "
            if rawValue.hasPrefix(prefix) {
                return String(rawValue.dropFirst(prefix.count))
            }
        }
        return rawValue
    }

    /// Where the action's shortcuts work unless the user chooses otherwise
    /// (FR12's branch E): the audio editor's group in its windows, the
    /// Record window's in it, a few actions in one kind of window
    /// (`defaultScopesOfTheirOwn`), and every other in every window but an
    /// audio editor's, as all of them always did.
    var defaultScope: ShortcutScope {
        if let scope = Self.defaultScopesOfTheirOwn[self] {
            return scope
        }
        switch category {
        case Self.audioEditorCategory: return .audioEditor
        case Self.recordingWindowCategory: return .recording
        default: return .app
        }
    }

    /// The scopes the user may give the action, in the Shortcuts tab and in
    /// config.json (FR12's branch E): the app's actions and the File menu's
    /// commands work in every window, in Library windows, or in reader
    /// windows; every other action works only where it does by nature, the
    /// audio editor's in its windows, the Record window's buttons in it, and
    /// the Library and Playback menus' commands where those menus show.
    var availableScopes: [ShortcutScope] {
        let fixed = defaultScope == .audioEditor || defaultScope == .recording
            || (isKeyEquivalent && category != Self.fileCategory)
        return fixed ? [defaultScope] : [.app, .library, .reader]
    }

    /// The actions whose shortcuts work in one kind of window by default,
    /// though their groups' work in every window (FR12's branch E): New from
    /// Text in Library windows and Show Sleep Timer in reader windows, as the
    /// user chose on October 7, so Shift-Command-T is each's in its own kind
    /// of window (#1451); the Library and Playback menus' commands where
    /// their menus show, as their keys always worked; and Go to View 1 to Go
    /// to View 9 in Library windows, whose views they show, so Command-1 to
    /// Command-9 stay free in every other window (October 30, 2026).
    static let defaultScopesOfTheirOwn: [ShortcutAction: ShortcutScope] = [
        .newFromText: .library,
        .showSleepTimer: .reader,
        .importDAISYFolder: .library,
        .addFeed: .library,
        .copyReadingPosition: .reader,
        .searchInBook: .reader,
    ].merging(goToViewActions.map { ($0, ShortcutScope.library) }) { own, _ in own }

    /// The notification to post when this action is triggered. A key
    /// equivalent's action (`isKeyEquivalent`) is never posted by the
    /// shortcut manager: its menu item or button acts on its key itself, and
    /// this names the notification choosing that command posts, or
    /// `actsWithoutNotification` for one that acts directly.
    var notificationName: Notification.Name {
        switch self {
        case .togglePlayback: return .togglePlayback
        case .releaseMediaControls: return .releaseMediaControls
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .cycleForwardNavigationUnit: return .cycleForwardNavigationUnit
        case .cycleBackwardNavigationUnit: return .cycleBackwardNavigationUnit
        case .increaseSpeed: return .increaseSpeed
        case .decreaseSpeed: return .decreaseSpeed
        case .copyReadingPosition: return .copyReadingPosition
        case .searchInBook: return .searchInBook
        case .searchLibrary: return .searchLibrary
        case .goToLibrary: return .goToLibrary
        case .goBack: return .goBack
        case .goForward: return .goForward
        case .navigateUpLevel: return .navigateUpLevel
        case .nextHeading: return .nextHeading
        case .previousHeading: return .previousHeading
        case .goToPage: return .goToPage
        case .nextInReadingList: return .nextInReadingList
        case .previousInReadingList: return .previousInReadingList
        case .nextInFolder: return .nextInFolder
        case .previousInFolder: return .previousInFolder
        case .addBookmark: return .addBookmark
        case .nextBookmark: return .nextBookmark
        case .previousBookmark: return .previousBookmark
        case .showHeadingList: return .showHeadingList
        case .showBookmarkList: return .showBookmarkList
        case .showSleepTimer: return .showSleepTimer
        case .restartSleepTimer: return .restartSleepTimer
        case .whereAmI: return .whereAmI
        case .whereAmIFull: return .whereAmIFull
        case .speakInfo: return .speakInfo
        case .speakFullInfo: return .speakFullInfo
        case .speakImportProgress: return .speakImportProgress
        case .speakDownloadProgress: return .speakDownloadProgress
        case .openSelectedBook: return .openSelectedBook
        case .showBookInfo: return .showBookInfo
        case .removeFromLibrary: return .removeFromLibrary
        case .newFolder: return .newFolder
        case .moveToFolder: return .moveToFolder
        case .moveToLibrary: return .moveToLibrary
        case .selectAll: return .selectAll
        case .toggleEditMode: return .toggleEditMode
        case .moveBookUp: return .moveBookUp
        case .moveBookDown: return .moveBookDown
        case .addToReadingList: return .addToReadingList
        case .removeFromReadingList: return .removeFromReadingList
        case .folderOrFeedSettings: return .showFolderOrFeedSettings
        // Go to View's nine actions post one name, carrying the action in
        // their user info, from which the Library window reads the number.
        case .goToView1, .goToView2, .goToView3, .goToView4, .goToView5,
             .goToView6, .goToView7, .goToView8, .goToView9:
            return .goToLibraryView
        case .importDAISYFolder: return .importDAISYFolder
        case .addFeed: return .addFeed
        case .openBook: return .openBookFile
        case .newFromText: return .newFromText
        // File > New Recording… opens the Record window itself, and the
        // window's buttons call its model: no notification is theirs.
        case .newRecording, .recordingRecord, .recordingPauseOrResume, .recordingStop:
            return .actsWithoutNotification
        // The audio editor's actions all post one name, carrying the action
        // in their user info, and its window performs them.
        case .editorPlayPause, .editorStop, .editorSkipBack, .editorSkipForward,
             .editorSkipBackLong, .editorSkipForwardLong, .editorSkipBackShort, .editorSkipForwardShort,
             .editorGoToStart, .editorGoToEnd, .editorGoToTime, .editorPreviousChapter, .editorNextChapter,
             .editorPreviousPause, .editorNextPause, .editorWhereAmI,
             .editorMarkIn, .editorMarkOut, .editorSelectToPreviousPause, .editorSelectToNextPause,
             .editorSelectChapter, .editorSelectAll, .editorClearSelection, .editorSpeakSelection,
             .editorPlaySelection, .editorAddMarker, .editorShowMarkers,
             .editorUndo, .editorRedo, .editorCut, .editorCopy, .editorPaste, .editorTrimToSelection,
             .editorInsertSilence, .editorInsertChapter, .editorApplyFilter, .editorPunchIn,
             .editorSave, .editorExport, .editorRevert, .editorInfo:
            return .audioEditorShortcut
        }
    }

    /// Category for grouping in settings
    var category: String {
        switch self {
        case .togglePlayback, .releaseMediaControls, .skipForward, .skipBackward,
             .cycleForwardNavigationUnit, .cycleBackwardNavigationUnit,
             .increaseSpeed, .decreaseSpeed, .copyReadingPosition, .searchInBook:
            return "Playback"
        case .goToLibrary, .goBack, .goForward, .navigateUpLevel, .nextHeading, .previousHeading,
             .goToPage, .nextInReadingList, .previousInReadingList,
             .nextInFolder, .previousInFolder:
            return "Navigation"
        case .addBookmark, .nextBookmark, .previousBookmark, .showBookmarkList:
            return "Bookmarks"
        case .showHeadingList, .showSleepTimer, .restartSleepTimer:
            return "Panels"
        case .whereAmI, .whereAmIFull, .speakInfo, .speakFullInfo, .speakImportProgress, .speakDownloadProgress:
            return "Information"
        case .openSelectedBook, .showBookInfo, .removeFromLibrary, .newFolder, .moveToFolder, .moveToLibrary, .selectAll, .toggleEditMode,
             .moveBookUp, .moveBookDown, .addToReadingList, .removeFromReadingList, .folderOrFeedSettings,
             .goToView1, .goToView2, .goToView3, .goToView4, .goToView5, .goToView6, .goToView7, .goToView8, .goToView9,
             .importDAISYFolder, .addFeed, .searchLibrary:
            return "Library"
        case .openBook, .newFromText, .newRecording:
            return Self.fileCategory
        case .recordingRecord, .recordingPauseOrResume, .recordingStop:
            return Self.recordingWindowCategory
        case .editorPlayPause, .editorStop, .editorSkipBack, .editorSkipForward,
             .editorSkipBackLong, .editorSkipForwardLong, .editorSkipBackShort, .editorSkipForwardShort,
             .editorGoToStart, .editorGoToEnd, .editorGoToTime, .editorPreviousChapter, .editorNextChapter,
             .editorPreviousPause, .editorNextPause, .editorWhereAmI,
             .editorMarkIn, .editorMarkOut, .editorSelectToPreviousPause, .editorSelectToNextPause,
             .editorSelectChapter, .editorSelectAll, .editorClearSelection, .editorSpeakSelection,
             .editorPlaySelection, .editorAddMarker, .editorShowMarkers,
             .editorUndo, .editorRedo, .editorCut, .editorCopy, .editorPaste, .editorTrimToSelection,
             .editorInsertSilence, .editorInsertChapter, .editorApplyFilter, .editorPunchIn,
             .editorSave, .editorExport, .editorRevert, .editorInfo:
            return Self.audioEditorCategory
        }
    }
}

/// Where an action's shortcuts work: in every window but an audio editor's,
/// or in one kind of window (FR12's branch E, as the user asked on October
/// 7: "new from text should only work in Library view and sleep timer only
/// in reader view"). One key belongs to at most one action wherever both
/// act (`windowKinds(of:)`, a menu command's key acting wherever its menu
/// item does), so a key may mean one thing in a Library window and another
/// in a reader, as Shift-Command-T does.
enum ShortcutScope: String, CaseIterable, Hashable, Sendable {
    /// Every window but an audio editor's: the Library, the readers, the
    /// Record window, Settings, and the rest, as the app's shortcuts always
    /// worked. An audio editor's window has shortcuts of its own; a menu
    /// command works there too, as menus do.
    case app
    /// Library windows.
    case library
    /// Reader windows.
    case reader
    /// The audio editor's windows (FR04), and nowhere else: so the editor
    /// can take Space, J, K, and L for itself.
    case audioEditor
    /// The Record window: its Record, Pause or Resume, and Stop.
    case recording

    /// The kinds of window whose key presses the scope's shortcuts match, a
    /// sheet's counting as its window's.
    var windowKinds: Set<ShortcutWindowKind> {
        switch self {
        case .app: return [.library, .reader, .recording, .other]
        case .library: return [.library]
        case .reader: return [.reader]
        case .audioEditor: return [.audioEditor]
        case .recording: return [.recording]
        }
    }

    /// Whether the scope's shortcuts work in windows of `kind`.
    func reaches(_ kind: ShortcutWindowKind) -> Bool {
        windowKinds.contains(kind)
    }

    /// Whether this scope and `other` share a kind of window, where a key
    /// held in both would mean two things.
    func overlaps(_ other: ShortcutScope) -> Bool {
        !windowKinds.isDisjoint(with: other.windowKinds)
    }

    /// The kinds of window where `action`'s keys act while it works in this
    /// scope: those whose key presses the scope's shortcuts match
    /// (`windowKinds`), and, for an action whose key is a key equivalent
    /// (`ShortcutAction.isKeyEquivalent`), every kind its menu item acts in
    /// (`admitsMenuCommand(in:)`), which for a File menu command working in
    /// every window takes in an audio editor's (REV11). A key is claimed
    /// (`KeyClaims`), and noted in the press index, in each of these, so no
    /// editor action can hold a key a menu command answers in an editor
    /// window, where the editor took the key while the menu showed it.
    func windowKinds(of action: ShortcutAction) -> Set<ShortcutWindowKind> {
        guard action.isKeyEquivalent else { return windowKinds }
        return Set(ShortcutWindowKind.allCases.filter { admitsMenuCommand(in: $0) })
    }

    /// The scope as the Shortcuts tab's Works in pop-up names it, and as
    /// config.json writes it: "Every window", "Library windows", "Reader
    /// windows", "The audio editor", or "The recording window".
    var title: String {
        switch self {
        case .app: return "Every window"
        case .library: return "Library windows"
        case .reader: return "Reader windows"
        case .audioEditor: return "The audio editor"
        case .recording: return "The recording window"
        }
    }

    /// The scope named within a sentence: "every window", "Library
    /// windows", "reader windows", "the audio editor", or "the recording
    /// window", the Library keeping its capital as the window's name.
    var inSentence: String {
        self == .library ? title : title.prefix(1).lowercased() + title.dropFirst()
    }

    /// Whether the scope is said where it is an action's default, in the
    /// Shortcuts tab's rows and in config.json's "default" text: Library and
    /// reader windows are, since a key may mean one thing in each; every
    /// window, most actions' default, goes unsaid, and so do the audio
    /// editor and the Record window, which their actions' names and groups
    /// say already.
    var isSaidAsADefault: Bool {
        self == .library || self == .reader
    }

    /// The scope config.json's `name` names (FR12's branch E): the Works in
    /// pop-up's words, as "Library windows", or the scope's short name, as
    /// "library", in any letter case, with spaces or without, and with or
    /// without "the" before it and "window" or "windows" after it. So "every
    /// window", "Every", and "app" all name every window, and "the audio
    /// editor" and "audioEditor" the audio editor. Nil for a name that names
    /// none.
    static func named(_ name: String) -> ShortcutScope? {
        let wanted = comparableName(name)
        return allCases.first { comparableName($0.title) == wanted || comparableName($0.rawValue) == wanted }
    }

    /// `name` as `named(_:)` compares names: in lower case, without spaces,
    /// and without "the" before it or "window" or "windows" after it. No two
    /// scopes' names compare alike (a test checks).
    private static func comparableName(_ name: String) -> String {
        var compared = name.lowercased().filter { !$0.isWhitespace }
        if compared.hasPrefix("the") {
            compared.removeFirst("the".count)
        }
        if let ending = ["windows", "window"].first(where: { compared.hasSuffix($0) }) {
            compared.removeLast(ending.count)
        }
        return compared
    }

    /// Whether a menu command working here acts while a window of `kind` is
    /// in front, nil meaning no window at all (FR12's branch E): one working
    /// in every window acts in any, an audio editor's included, as menus
    /// always have; one working in a kind of window acts in that kind; and
    /// any acts with no window open, as a menu's key must.
    func admitsMenuCommand(in kind: ShortcutWindowKind?) -> Bool {
        guard let kind else { return true }
        return self == .app || reaches(kind)
    }
}

/// The kind of window a key is pressed in, whose shortcuts in force there
/// are those of the scopes that reach it (FR12's branch E).
enum ShortcutWindowKind: CaseIterable, Hashable, Sendable {
    /// A Library window.
    case library
    /// A reader window.
    case reader
    /// An audio editor's window.
    case audioEditor
    /// The Record window.
    case recording
    /// Any other window, Settings, a panel, or an alert run on its own among
    /// them, or none at all.
    case other

    /// Whether a letter pressed alone, with no modifier, belongs to the
    /// window's own letter navigation rather than to a shortcut: a Library
    /// window's list moves to the first book or folder whose name starts
    /// with it. The user asked on October 17 to "have letter navigation take
    /// priority", so no shortcut is a letter alone in a Library window
    /// (`KeyBinding.isLetterAlone`; `ShortcutPressDispatcher.Index`). Only
    /// `.library` navigates by letter.
    var navigatesByLetter: Bool {
        self == .library
    }
}

extension Notification.Name {
    /// Posted for every audio editor shortcut (FR04), with the action's raw
    /// value under "action" in its user info, and the window it was pressed
    /// in under "sourceWindow": that window's editor performs it.
    static let audioEditorShortcut = Notification.Name("audioEditorShortcut")
    /// Posted by Go to View 1 to Go to View 9's keys and by the Library
    /// menu's Go to View submenu (October 30, 2026): the Library window that
    /// takes it shows the view its user info numbers
    /// (`ShortcutAction.goToViewNumber(in:)`), and says so.
    static let goToLibraryView = Notification.Name("goToLibraryView")
    /// Never posted: the notification name of the actions whose command acts
    /// directly, with no notification of its own, File > New Recording… and
    /// the Record window's buttons (FR12's branch D). The shortcut manager
    /// posts no key equivalent's action, so nothing listens for this.
    static let actsWithoutNotification = Notification.Name("actsWithoutNotification")
}

// MARK: - Go to View (October 30, 2026)

extension ShortcutAction {
    /// Go to View 1 to Go to View 9, in order: the Nth goes to the Nth view
    /// a Library window offers.
    static let goToViewActions: [ShortcutAction] = [
        .goToView1, .goToView2, .goToView3, .goToView4, .goToView5,
        .goToView6, .goToView7, .goToView8, .goToView9,
    ]

    /// The number of the view this action goes to, 1 to 9, or nil for any
    /// action but Go to View's.
    var goToViewNumber: Int? {
        Self.goToViewActions.firstIndex(of: self).map { $0 + 1 }
    }

    /// The action going to the `number`th view, Go to View 1 to Go to View
    /// 9, or nil for any other number, which no action goes to.
    static func goToView(number: Int) -> ShortcutAction? {
        goToViewActions.indices.contains(number - 1) ? goToViewActions[number - 1] : nil
    }

    /// The user info key under which the Go to View submenu's item for a
    /// view past the ninth gives that view's number, as no action does.
    static let goToViewNumberKey = "viewNumber"

    /// The user info with which the Go to View submenu's item for the
    /// `number`th view posts `.goToLibraryView`: the action's raw value under
    /// "action" for the first nine, as their keys post it, and the number
    /// under `goToViewNumberKey` past them.
    static func goToViewUserInfo(number: Int) -> [String: Any] {
        guard let action = goToView(number: number) else {
            return [goToViewNumberKey: number]
        }
        return ["action": action.rawValue]
    }

    /// The number of the view a `.goToLibraryView` notification's
    /// `userInfo` asks for: its action's (`goToViewNumber`), or else the
    /// number under `goToViewNumberKey`; nil for neither.
    static func goToViewNumber(in userInfo: [AnyHashable: Any]?) -> Int? {
        let action = (userInfo?["action"] as? String).flatMap(ShortcutAction.init(rawValue:))
        return action?.goToViewNumber ?? (userInfo?[goToViewNumberKey] as? Int)
    }
}

// MARK: - Key Equivalents (FR12's Branch D)

extension ShortcutAction {
    /// The actions whose keys are key equivalents (FR12's branch D): the
    /// menu commands whose keys were fixed before, and the Record window's
    /// buttons. Their menu item or button shows the key in force and acts on
    /// it; the shortcut manager never takes it. A command added later joins
    /// them here.
    static let keyEquivalentActions: Set<ShortcutAction> = [
        .copyReadingPosition, .searchInBook, .searchLibrary, .importDAISYFolder, .addFeed,
        .openBook, .newFromText, .newRecording,
        .recordingRecord, .recordingPauseOrResume, .recordingStop,
    ]

    /// Whether the action's key is a key equivalent: of its menu item, or of
    /// its button in the Record window, which acts on it as menus always
    /// have, from a text field and with no window open. Such a key is one
    /// press with Command or Control (`KeyBinding.canBeKeyEquivalent`), the
    /// shortcut manager never takes it, and it is the action's only key, as
    /// an item has one key equivalent.
    var isKeyEquivalent: Bool {
        Self.keyEquivalentActions.contains(self)
    }

    /// Whether this action, working in `scope`, and `other`, working in
    /// `otherScope`, act in a kind of window in common
    /// (`ShortcutScope.windowKinds(of:)`), where one key cannot be both's: a
    /// menu command's key counts wherever its menu item acts.
    func sharesAWindow(in scope: ShortcutScope, with other: ShortcutAction, in otherScope: ShortcutScope) -> Bool {
        !scope.windowKinds(of: self).isDisjoint(with: otherScope.windowKinds(of: other))
    }
}

extension KeyBinding {
    /// Whether the binding can be a key equivalent (FR12's branch D): one
    /// press, since no menu or button takes a double press; with Command or
    /// Control, so that it acts from a text field, where a key without them
    /// types; and none of the keys a text field edits with
    /// (`TextEditingKeys`), which a key equivalent would take from the field,
    /// since the menus meet a key before the field does.
    var canBeKeyEquivalent: Bool {
        keyEquivalentRefusal == nil
    }

    /// Why the binding cannot be a key equivalent (`canBeKeyEquivalent`),
    /// or nil when it can.
    var keyEquivalentRefusal: ShortcutRefusal? {
        if isDoublePress || !(command || control) {
            return .notOnePressWithCommandOrControl(self)
        }
        return TextEditingKeys.contains(self) ? .editsText(self) : nil
    }
}

// MARK: - Keys an Action Cannot Take (FR12's Branch D)

/// Why a key cannot be given to an action: the Shortcuts tab says so as it
/// refuses the key, and reading config.json logs it, the action keeping the
/// keys it had (FR12's branch D).
enum ShortcutRefusal: Equatable, Sendable {
    /// A menu command's or a Record window button's key is one press of a
    /// key with Command or Control: no menu or button takes a double press,
    /// and a key without Command or Control types in a text field.
    case notOnePressWithCommandOrControl(KeyBinding)
    /// A key a text field edits with (`TextEditingKeys`), which a menu
    /// command's key would take from every field.
    case editsText(KeyBinding)
    /// A second key for a menu command or a Record window button, whose item
    /// has one key equivalent.
    case secondKeyEquivalent(KeyBinding)
    /// A key of one of macOS's own commands (`KeyBinding.systemCommands`),
    /// named here, which a shortcut would take from it: the manager meets a
    /// key before the menus do (finding 10 of FR12's design).
    case systemCommand(KeyBinding, command: String)

    /// The key refused.
    var key: KeyBinding {
        switch self {
        case .notOnePressWithCommandOrControl(let key), .editsText(let key), .secondKeyEquivalent(let key),
             .systemCommand(let key, _):
            return key
        }
    }

    /// Why, in words, for VoiceOver, a braille display, and the debug log:
    /// "a menu command's shortcut is one press of a key with Command or
    /// Control".
    var reason: String {
        switch self {
        case .notOnePressWithCommandOrControl:
            return "a menu command's shortcut is one press of a key with Command or Control"
        case .editsText:
            return "a text field edits with it, and a menu command's shortcut would take it from the field"
        case .secondKeyEquivalent:
            return "a menu command has one shortcut"
        case .systemCommand(_, let command):
            return "\(command) has it in the menus, and no shortcut may take it"
        }
    }
}

extension KeyBinding {
    /// The Edit menu's commands a text field edits with, each key with its
    /// command's name: Undo, Redo, Cut, Copy, Paste, and Select All. A field
    /// keeps these keys from the shortcut manager
    /// (`TextEditingKeys.editMenuKeys`), and no shortcut may take them
    /// (`systemCommands`).
    static let editMenuCommands: [KeyBinding: String] = [
        KeyBinding(key: "z", command: true): "Undo",
        KeyBinding(key: "z", command: true, shift: true): "Redo",
        KeyBinding(key: "x", command: true): "Cut",
        KeyBinding(key: "c", command: true): "Copy",
        KeyBinding(key: "v", command: true): "Paste",
        KeyBinding(key: "a", command: true): "Select All",
    ]

    /// The keys of macOS's own commands in TextMouth's menus, which no
    /// shortcut may take (finding 10 of FR12's design), each with its
    /// command's name: Quit, Close, Settings, Hide, and Minimize, and the
    /// Edit menu's (`editMenuCommands`, which this holds). A key held for
    /// its own command, as Select All's Command-A or the audio editor's Undo
    /// and Copy are, is no taking (`ShortcutAction.refusal(of:)`).
    static let systemCommands: [KeyBinding: String] = [
        KeyBinding(key: "q", command: true): "Quit TextMouth",
        KeyBinding(key: "w", command: true): "Close",
        KeyBinding(key: "w", command: true, option: true): "Close All",
        KeyBinding(key: ",", command: true): "Settings",
        KeyBinding(key: "h", command: true): "Hide TextMouth",
        KeyBinding(key: "h", command: true, option: true): "Hide Others",
        KeyBinding(key: "m", command: true): "Minimize",
        KeyBinding(key: "m", command: true, option: true): "Minimize All",
        // Not a key a field keeps, so it stays out of `editMenuCommands`.
        KeyBinding(key: "v", command: true, option: true, shift: true): "Paste and Match Style",
    ].merging(editMenuCommands) { own, _ in own }

    /// The name of the system command whose key this binding's stroke is,
    /// pressed once or twice (a double press's first press would keep it
    /// from the command), or nil.
    var systemCommand: String? {
        Self.systemCommands[stroke]
    }
}

extension ShortcutAction {
    /// Why `key` cannot be one of this action's keys, or nil when it can: no
    /// action takes a system command's key, unless it is one of the action's
    /// own defaults, which stand for that command, as Select All's Command-A
    /// does; and a key equivalent's action takes only a key that can be one
    /// (`KeyBinding.keyEquivalentRefusal`).
    func refusal(of key: KeyBinding) -> ShortcutRefusal? {
        if let command = key.systemCommand, Self.defaultBindings[self]?.contains(key) != true {
            return .systemCommand(key, command: command)
        }
        return isKeyEquivalent ? key.keyEquivalentRefusal : nil
    }

    /// Why `keys` cannot become this action's keys, or nil when they can:
    /// the first key they add to `held`, the keys it has now, that it cannot
    /// take (`refusal(of:)`), or, for a key equivalent's action, whose item
    /// has one key, a key past the number it may have, which is one, or as
    /// many as it holds. A key it holds already is never refused, so keys a
    /// store edited by hand gave it never stop the user changing it. The one
    /// rule the Shortcuts tab (`KeyboardShortcutManager`), with the keys in
    /// force, and config.json (`ShortcutListing.refusal(for:)`), with none,
    /// both follow (REV11).
    func refusal(ofKeys keys: [KeyBinding], holding held: [KeyBinding] = []) -> ShortcutRefusal? {
        let added = keys.filter { !held.contains($0) }
        if let refused = added.lazy.compactMap(refusal(of:)).first {
            return refused
        }
        let allowed = max(1, held.count)
        if isKeyEquivalent, keys.count > allowed,
           let extra = keys.dropFirst(allowed).first(where: { !held.contains($0) }) ?? added.first {
            return .secondKeyEquivalent(extra)
        }
        return nil
    }
}

// MARK: - A Dialog's Own Keys

extension KeyBinding {
    /// The keys a dialog's own buttons answer, which no shortcut takes while
    /// a sheet or an alert is the key window (the review of October 10,
    /// item B): Return and the keypad's Enter, for its default button, and
    /// Escape and Command-Period, for its Cancel button, each with no other
    /// modifier. The keypad's Enter is held as the character it gives, as
    /// `keyNames` names it.
    static let dialogKeys: Set<KeyBinding> = [
        KeyBinding(key: "return"),
        KeyBinding(key: "\u{3}"),
        KeyBinding(key: "escape"),
        KeyBinding(key: ".", command: true),
    ]

    /// Whether a press of this binding's key is one a dialog's own buttons
    /// answer (`dialogKeys`), pressed once or twice.
    var isDialogKey: Bool {
        Self.dialogKeys.contains(stroke)
    }
}

extension KeyBinding {
    /// Whether the binding is a letter pressed with no modifier at all
    /// (none of Command, Option, Shift, or Control), once or twice, such as
    /// W, or W twice. Any letter counts, a non-Latin one included. A
    /// Library window leaves such a key to its list's letter navigation
    /// (`ShortcutWindowKind.navigatesByLetter`).
    var isLetterAlone: Bool {
        key.count == 1 && key.first?.isLetter == true
            && !command && !option && !shift && !control
    }
}

/// A keyboard binding: key + modifiers, pressed once or, for a double press,
/// twice (FR12).
struct KeyBinding: Codable, Equatable, Hashable {
    /// The key character (lowercased letter) or special key name:
    /// "space", "rightArrow", "leftArrow", "upArrow", "downArrow", "tab",
    /// "return", "delete", "escape", or a single character like "k", "+", "-", "[", "]"
    var key: String
    var command: Bool = false
    var option: Bool = false
    var shift: Bool = false
    var control: Bool = false
    /// Whether the binding is its key pressed twice within the double-press
    /// time (FR12, `SettingsPolicy.shortcutDoublePressSeconds`), rather than
    /// once. A double press and a single press of one key are two bindings,
    /// which two actions may hold; `ShortcutPressDispatcher` tells them
    /// apart as the key is pressed.
    var isDoublePress: Bool = false

    /// The word that follows a double press's shortcut where it is shown,
    /// spoken, or written in config.json: "W twice", "w twice".
    static let twiceWord = "twice"

    /// The key press the binding is made of: the binding as a single press,
    /// its key as a key press gives it (`from(event:)`), a character in
    /// lower case. A double press is its stroke pressed twice; key presses
    /// are matched by their strokes.
    var stroke: KeyBinding {
        KeyBinding(
            key: key.count == 1 ? key.lowercased() : key,
            command: command,
            option: option,
            shift: shift,
            control: control
        )
    }

    /// The binding pressed twice when `isDouble`, or once: the same key and
    /// modifiers, as the Shortcuts tab's Make Double Press and Make Single
    /// Press change them.
    func asDoublePress(_ isDouble: Bool) -> KeyBinding {
        var binding = self
        binding.isDoublePress = isDouble
        return binding
    }

    /// Human-readable display string, such as "⌘I", or "⌘I twice" for a
    /// double press.
    var displayString: String {
        var parts: [String] = []
        if control { parts.append("\u{2303}") }      // ⌃
        if option { parts.append("\u{2325}") }        // ⌥
        if shift { parts.append("\u{21E7}") }         // ⇧
        if command { parts.append("\u{2318}") }       // ⌘
        parts.append(keyDisplayName)
        return withTwice(parts.joined())
    }

    /// The binding in words, as VoiceOver speaks it and a braille display
    /// shows it: its modifiers, then its key, joined by " + ", such as
    /// "Shift + Command + B" or "Command + Right Arrow", and " twice" after
    /// a double press: "W twice", "Command + I twice". No part is a symbol,
    /// which a braille display shows as a sign (FR12).
    var accessibleDisplayString: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(keyNameInWords)
        return withTwice(parts.joined(separator: " + "))
    }

    /// `text`, naming the binding's key and modifiers, followed by " twice"
    /// for a double press: the one place every form of a binding, on the
    /// screen, in words, and in config.json, says that it is one.
    private func withTwice(_ text: String) -> String {
        isDoublePress ? "\(text) \(Self.twiceWord)" : text
    }

    /// The keys of one action in words, as the Shortcuts tab says them:
    /// "Space or K", or "No shortcut" for none.
    static func accessibleDisplayString(for keys: [KeyBinding]) -> String {
        keys.isEmpty ? "No shortcut" : keys.map(\.accessibleDisplayString).joined(separator: " or ")
    }

    /// The key in words (`KeyName.words`): a named key's name, such as
    /// "Right Arrow", "Page Down", "F5", or "Comma", or the character in
    /// capitals.
    private var keyNameInWords: String {
        Self.words(forKey: key)
    }

    /// The key as the screen shows it (`KeyName.shown`): a named key's
    /// symbol, such as "→" or "⌫", or its words, such as "Space" or "Page
    /// Down", or the character in capitals.
    private var keyDisplayName: String {
        Self.keyName(forKey: key)?.shown ?? key.uppercased()
    }

#if os(macOS)
    /// The binding a key press makes, as the Shortcuts tab records it and
    /// the dispatcher matches it: the key named by its key code, or else by
    /// the character it gives, in lower case, with the modifiers held. Nil
    /// for a key that gives no character, or one of the private-use area
    /// that no name in `keyNames` says, which nothing could show or speak.
    static func from(event: NSEvent) -> KeyBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let shft = flags.contains(.shift)
        let ctrl = flags.contains(.control)

        let key: String
        if let named = keyNamesByKeyCode[event.keyCode] {
            key = named.key
        } else {
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty,
                  !isUnnamedPrivateUseCharacter(chars) else {
                return nil
            }
            key = chars
        }

        return KeyBinding(key: key, command: cmd, option: opt, shift: shft, control: ctrl)
    }
#endif
}

// MARK: - Keys in Words

/// A key named rather than spelled by its character (FR12; #1452 and
/// #1508), in the one table the Shortcuts tab, the audio editor's hints,
/// VoiceOver, braille, and config.json all read (`KeyBinding.keyNames`).
struct KeyName: Sendable {
    /// The key as a binding holds it: a name such as "rightArrow", or a
    /// character: AppKit's private-use one for a key with no name of its
    /// own, such as Page Down's, or the key's own, such as ",".
    let key: String
    /// The key in words, as VoiceOver speaks it and a braille display shows
    /// it: "Right Arrow", "Page Down", "F5", "Comma".
    let words: String
    /// The key as the screen shows it: a symbol such as "→", or its words,
    /// or a punctuation mark itself.
    let shown: String
    /// The key as config.json writes it, read back in any letter case:
    /// "rightArrow", "pageDown", "f5", or a punctuation mark itself, ",".
    let configName: String
    /// The key code a press of the key has, for a key matched by its code
    /// rather than its character; nil for every other.
    let keyCode: UInt16?
}

extension KeyBinding {
    /// Every key named rather than spelled by its character: the keys the
    /// keyboard's key codes name, AppKit's function keys, the keypad's
    /// Enter, and the punctuation marks.
    static let keyNames: [KeyName] = codeNamedKeys + functionKeys + [keypadEnter] + punctuationMarks

    /// The special keys' names, spelled as `from(event:)` records them. Any
    /// other key is a character.
    static let namedKeys = codeNamedKeys.map(\.key)

    /// The keys matched by their key codes, as `from(event:)` records them,
    /// each shown as macOS's menus show it.
    private static let codeNamedKeys: [KeyName] = [
        KeyName(key: "space", words: "Space", shown: "Space", configName: "space", keyCode: 49),
        KeyName(key: "tab", words: "Tab", shown: "\u{21E5}", configName: "tab", keyCode: 48),                // ⇥
        KeyName(key: "return", words: "Return", shown: "\u{21A9}", configName: "return", keyCode: 36),       // ↩
        KeyName(key: "delete", words: "Delete", shown: "\u{232B}", configName: "delete", keyCode: 51),       // ⌫
        KeyName(key: "escape", words: "Escape", shown: "\u{238B}", configName: "escape", keyCode: 53),       // ⎋
        KeyName(key: "leftArrow", words: "Left Arrow", shown: "\u{2190}", configName: "leftArrow", keyCode: 123),     // ←
        KeyName(key: "rightArrow", words: "Right Arrow", shown: "\u{2192}", configName: "rightArrow", keyCode: 124),  // →
        KeyName(key: "upArrow", words: "Up Arrow", shown: "\u{2191}", configName: "upArrow", keyCode: 126),           // ↑
        KeyName(key: "downArrow", words: "Down Arrow", shown: "\u{2193}", configName: "downArrow", keyCode: 125),     // ↓
    ]

    /// The keys AppKit gives a private-use character of its own (NSEvent.h's
    /// function-key constants), which a binding holds as that character, as
    /// `from(event:)` records it and `TextEditingKeys` keeps Forward Delete,
    /// Home, End, Page Up, and Page Down for a text field. Each is shown,
    /// spoken, and written in config.json in words, never as its character,
    /// which no screen or braille display can show.
    private static let functionKeys: [KeyName] = {
        var keys = [
            functionKey(NSDeleteFunctionKey, "Forward Delete", "forwardDelete"),
            functionKey(NSHomeFunctionKey, "Home", "home"),
            functionKey(NSEndFunctionKey, "End", "end"),
            functionKey(NSPageUpFunctionKey, "Page Up", "pageUp"),
            functionKey(NSPageDownFunctionKey, "Page Down", "pageDown"),
            functionKey(NSHelpFunctionKey, "Help", "help"),
            functionKey(NSClearLineFunctionKey, "Clear", "clear"),
            functionKey(NSInsertFunctionKey, "Insert", "insert"),
            functionKey(NSBeginFunctionKey, "Begin", "begin"),
            functionKey(NSPrintScreenFunctionKey, "Print Screen", "printScreen"),
            functionKey(NSScrollLockFunctionKey, "Scroll Lock", "scrollLock"),
            functionKey(NSPauseFunctionKey, "Pause", "pause"),
            functionKey(NSSysReqFunctionKey, "System Request", "sysReq"),
            functionKey(NSBreakFunctionKey, "Break", "break"),
            functionKey(NSResetFunctionKey, "Reset", "reset"),
            functionKey(NSStopFunctionKey, "Stop", "stop"),
            functionKey(NSMenuFunctionKey, "Menu", "menu"),
            functionKey(NSUserFunctionKey, "User", "user"),
            functionKey(NSSystemFunctionKey, "System", "system"),
            functionKey(NSPrintFunctionKey, "Print", "print"),
            functionKey(NSClearDisplayFunctionKey, "Clear Display", "clearDisplay"),
            functionKey(NSInsertLineFunctionKey, "Insert Line", "insertLine"),
            functionKey(NSDeleteLineFunctionKey, "Delete Line", "deleteLine"),
            functionKey(NSInsertCharFunctionKey, "Insert Character", "insertCharacter"),
            functionKey(NSDeleteCharFunctionKey, "Delete Character", "deleteCharacter"),
            functionKey(NSPrevFunctionKey, "Previous", "previous"),
            functionKey(NSNextFunctionKey, "Next", "next"),
            functionKey(NSSelectFunctionKey, "Select", "select"),
            functionKey(NSExecuteFunctionKey, "Execute", "execute"),
            functionKey(NSUndoFunctionKey, "Undo", "undo"),
            functionKey(NSRedoFunctionKey, "Redo", "redo"),
            functionKey(NSFindFunctionKey, "Find", "find"),
            functionKey(NSModeSwitchFunctionKey, "Mode Switch", "modeSwitch"),
        ]
        // F1 to F35, which AppKit numbers in a row from F1's character.
        for number in 1...35 {
            keys.append(functionKey(NSF1FunctionKey + number - 1, "F\(number)", "f\(number)"))
        }
        return keys
    }()

    /// The keypad's Enter, whose character is a control character no screen
    /// shows: named "Enter" everywhere.
    private static let keypadEnter = KeyName(key: "\u{3}", words: "Enter", shown: "Enter", configName: "enter", keyCode: nil)

    /// The punctuation marks, named in words for VoiceOver and braille, as
    /// the audio editor's hints always named them, and shown and written in
    /// config.json as themselves.
    private static let punctuationMarks: [KeyName] = [
        (",", "Comma"), (".", "Period"), ("<", "Less Than"), (">", "Greater Than"), ("/", "Slash"),
        ("\\", "Backslash"), (";", "Semicolon"), ("'", "Apostrophe"), ("`", "Grave Accent"),
        ("[", "Left Bracket"), ("]", "Right Bracket"), ("-", "Minus"), ("=", "Equals"), ("+", "Plus"),
        (":", "Colon"), ("\"", "Quotation Mark"), ("?", "Question Mark"), ("{", "Left Brace"),
        ("}", "Right Brace"), ("|", "Vertical Bar"), ("_", "Underscore"), ("~", "Tilde"),
        ("!", "Exclamation Mark"), ("@", "At Sign"), ("#", "Number Sign"), ("$", "Dollar Sign"),
        ("%", "Percent Sign"), ("^", "Caret"), ("&", "Ampersand"), ("*", "Asterisk"),
        ("(", "Left Parenthesis"), (")", "Right Parenthesis"),
    ].map { mark, words in
        KeyName(key: mark, words: words, shown: mark, configName: mark, keyCode: nil)
    }

    /// The name of the AppKit function key whose constant is `code`: its
    /// character as a binding holds it, shown and spoken as `words`, and
    /// written `configName` in config.json.
    private static func functionKey(_ code: Int, _ words: String, _ configName: String) -> KeyName {
        let character = UInt32(exactly: code).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        return KeyName(key: character, words: words, shown: words, configName: configName, keyCode: nil)
    }

    /// The table by the key a binding holds.
    private static let keyNamesByKey = Dictionary(keyNames.map { ($0.key, $0) }) { first, _ in first }

    /// The keys matched by their key codes, by those codes.
    private static let keyNamesByKeyCode = Dictionary(
        keyNames.compactMap { name in name.keyCode.map { ($0, name) } }
    ) { first, _ in first }

    /// The table by config.json's names that are words, in lower case; a
    /// punctuation mark is read as the one character it is.
    private static let keyNamesByConfigName = Dictionary(
        keyNames.filter { $0.configName.count > 1 }.map { ($0.configName.lowercased(), $0) }
    ) { first, _ in first }

    /// The name of the key `key`, as a binding holds it, if it has one.
    static func keyName(forKey key: String) -> KeyName? {
        keyNamesByKey[key]
    }

    /// The key `key` in words, as VoiceOver speaks it and a braille display
    /// shows it: a named key's words, or the character in capitals. The
    /// Shortcuts tab and the audio editor's hints both say keys so.
    static func words(forKey key: String) -> String {
        keyName(forKey: key)?.words ?? key.uppercased()
    }

    /// Whether `characters` are one character of the private-use area that
    /// no name says: no key TextMouth can show, speak, or write.
    static func isUnnamedPrivateUseCharacter(_ characters: String) -> Bool {
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return false }
        return (0xE000...0xF8FF).contains(scalar.value) && keyName(forKey: characters) == nil
    }
}

// MARK: - A Binding as the Preferences Store Saves It

/// Written by hand, in an extension so the memberwise initializer stays, to
/// keep every binding saved before double presses existed readable (FR12):
/// Swift's synthesized decoding would require `isDoublePress` in every
/// saved binding, and a record that fails to read is lost. A single press
/// is written exactly as before, with no flag, so this user's record and
/// config.json read and write unchanged, and an older build reads a double
/// press as its single press rather than failing.
extension KeyBinding {
    /// The binding's fields as they are saved, in the order every release
    /// has written them.
    private enum CodingKeys: String, CodingKey {
        case key, command, option, shift, control, isDoublePress
    }

    /// Reads a saved binding: its key and four modifiers, which every
    /// release writes, and the double press flag, written only when true,
    /// so a binding saved without it is a single press.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        command = try container.decode(Bool.self, forKey: .command)
        option = try container.decode(Bool.self, forKey: .option)
        shift = try container.decode(Bool.self, forKey: .shift)
        control = try container.decode(Bool.self, forKey: .control)
        isDoublePress = try container.decodeIfPresent(Bool.self, forKey: .isDoublePress) ?? false
    }

    /// Writes the key and the four modifiers as every release has, and the
    /// double press flag only for a double press.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(command, forKey: .command)
        try container.encode(option, forKey: .option)
        try container.encode(shift, forKey: .shift)
        try container.encode(control, forKey: .control)
        if isDoublePress {
            try container.encode(true, forKey: .isDoublePress)
        }
    }
}

// MARK: - Shortcuts as config.json Writes Them

extension KeyBinding {
    /// The word config.json also reads before a double press's shortcut, as
    /// in "double w", though it writes "w twice".
    static let doubleWord = "double"

    /// The binding as config.json writes it: its modifiers in the order
    /// Settings shows them (Control, Option, Shift, Command), then its key,
    /// joined by "+", such as "space", "command+rightArrow", or
    /// "option+shift+command+b", and " twice" after a double press, such as
    /// "w twice" (FR12). A named key is written by its name in
    /// `KeyBinding.keyNames`, such as "command+pageDown" or "f5", never as
    /// the private-use character a binding holds for it.
    var configText: String {
        let keyText = Self.keyName(forKey: key)?.configName ?? key
        return withTwice((ConfigModifier.allCases.filter { $0.isHeld(in: self) }.map(\.word) + [keyText]).joined(separator: "+"))
    }

    /// Reads a shortcut written in config.json: modifier names joined to a
    /// key by "+", as `configText` writes them, and "twice" after a double
    /// press.
    ///
    /// Text edited by hand is read generously: names may be capitalized,
    /// spaces are ignored, cmd, ctrl, opt, and alt stand for command,
    /// control, and option, and a letter key may be a capital. The key comes
    /// last and may itself be the plus key, as in "command++". A double
    /// press may say "twice" after the shortcut, in any letter case, with or
    /// without a space before it, or "double" before it: "w twice",
    /// "W Twice", "wtwice", and "double w" are all W pressed twice. Returns
    /// nil for text that names no key, or a key that is neither a special
    /// key's name nor a single character.
    init?(configText: String) {
        var remaining = Substring(configText.filter { !$0.isWhitespace })
        var binding = KeyBinding(key: "", isDoublePress: Self.takeDoublePressWord(from: &remaining))
        // Take modifiers off the front while one is followed by "+"; what
        // remains is the key.
        while let leading = ConfigModifier.leading(in: remaining) {
            leading.modifier.hold(in: &binding)
            remaining = leading.rest
        }
        guard let key = Self.storedKey(named: remaining) else { return nil }
        binding.key = key
        self = binding
    }

    /// Takes the word marking a double press off `text`, spaces already
    /// removed: "twice" at its end, or else "double" at its start, in any
    /// letter case. Returns whether there was one. Only one word is taken,
    /// and never the whole text, so "twice" alone, "w twice twice", and
    /// "double w twice" name no key.
    private static func takeDoublePressWord(from text: inout Substring) -> Bool {
        if text.count > twiceWord.count, text.suffix(twiceWord.count).lowercased() == twiceWord {
            text = text.dropLast(twiceWord.count)
            return true
        }
        if text.count > doubleWord.count, text.prefix(doubleWord.count).lowercased() == doubleWord {
            text = text.dropFirst(doubleWord.count)
            return true
        }
        return false
    }

    /// Reads the shortcuts config.json lists for one action, keeping the
    /// first of any repeated. Returns nil when any of them cannot be read,
    /// so a mistyped shortcut leaves the action's bindings as they are
    /// rather than dropping it and keeping the rest.
    static func bindings(fromConfigTexts texts: [String]) -> [KeyBinding]? {
        var bindings: [KeyBinding] = []
        for text in texts {
            guard let binding = KeyBinding(configText: text) else { return nil }
            if !bindings.contains(binding) {
                bindings.append(binding)
            }
        }
        return bindings
    }

    /// The key as bindings store it: the key a name of `keyNames` names, in
    /// any letter case, such as "pageDown" or "F5"; or a single character
    /// in lower case, as recorded, AppKit's own for a named key included, so
    /// a file that wrote one reads back as the name does. Nil for anything
    /// else, a private-use character no name says among them.
    private static func storedKey(named text: Substring) -> String? {
        if let named = keyNamesByConfigName[text.lowercased()] {
            return named.key
        }
        guard text.count == 1 else { return nil }
        let character = text.lowercased()
        return isUnnamedPrivateUseCharacter(character) ? nil : character
    }
}

/// A modifier key as config.json names it, in the order Settings shows the
/// modifiers (⌃⌥⇧⌘).
private enum ConfigModifier: CaseIterable {
    case control, option, shift, command

    /// Every name config.json accepts for the modifier, the one it writes
    /// first.
    var names: [String] {
        switch self {
        case .control: return ["control", "ctrl"]
        case .option: return ["option", "opt", "alt"]
        case .shift: return ["shift"]
        case .command: return ["command", "cmd"]
        }
    }

    /// The name config.json writes.
    var word: String { names[0] }

    /// Whether `binding` holds this modifier down.
    func isHeld(in binding: KeyBinding) -> Bool {
        switch self {
        case .control: return binding.control
        case .option: return binding.option
        case .shift: return binding.shift
        case .command: return binding.command
        }
    }

    /// Makes `binding` hold this modifier down.
    func hold(in binding: inout KeyBinding) {
        switch self {
        case .control: binding.control = true
        case .option: binding.option = true
        case .shift: binding.shift = true
        case .command: binding.command = true
        }
    }

    /// The modifier `text` starts with, named in any letter case and
    /// followed by "+", and the text after that "+"; nil when `text` starts
    /// with none.
    static func leading(in text: Substring) -> (modifier: ConfigModifier, rest: Substring)? {
        for modifier in allCases {
            for name in modifier.names where text.prefix(name.count + 1).lowercased() == name + "+" {
                return (modifier, text.dropFirst(name.count + 1))
            }
        }
        return nil
    }
}

// MARK: - An Action's Entry in config.json

/// One action's entry in config.json's `keyboardShortcuts`, in any of the
/// file's three forms (FR12, as the user chose on October 7, 2026, and its
/// branch E):
/// - a list of shortcuts, written as `KeyBinding.configText` writes them,
///   makes the action the user's, with those keys or, for an empty list,
///   none, working where it does by default: `"Release Media Controls":
///   ["shift+r"]`. In a file in the old form, which earlier releases wrote
///   as a list for every action and which holds neither of the two other
///   forms, a list equal to a default of its action edits nothing
///   (`ShortcutEdits.keysAreADefault`); in a file in the new form, one
///   entry in either of the other forms is enough, a list equal to the
///   default still makes the action the user's;
/// - an object holding such a list and the kind of window the action works
///   in makes it the user's, working there: `"New from Text…": {"keys":
///   ["shift+command+t"], "worksIn": "Every window"}`. TextMouth writes the
///   Works in pop-up's words, the ones the Shortcuts tab says, and reads a
///   scope's short name too, as "library", in any letter case
///   (`ShortcutScope.named(_:)`); its field names may be in any letter case,
///   its keys may be one shortcut written as text, and one without
///   "worksIn" is a list;
/// - text beginning with "default", in any letter case, gives the action
///   TextMouth's defaults, its keys and where it works, and, as TextMouth
///   writes it, says what they are: `"Where Am I?": "default: w"`, or, for
///   an action working in one kind of window by default, `"Show Sleep
///   Timer": "default in reader windows: shift+command+t"`.
///
/// Any other text is one shortcut, read as a list of one. The words after
/// "default" are never read back, so changing them changes nothing: that is
/// what lets a later release's defaults reach every action written so,
/// however old the file, without TextMouth ever having to tell an older
/// release's defaults from the user's edits.
enum ShortcutListing: Codable, Equatable, Sendable, ExpressibleByArrayLiteral, ExpressibleByStringLiteral {
    /// A list of shortcuts: the user's keys for the action.
    case list([String])
    /// Text: "default" and what the defaults are, or one shortcut.
    case text(String)
    /// An object: the user's keys for the action and, when it names one,
    /// the kind of window it works in, as the file names it (FR12's branch
    /// E).
    case object(keys: [String], worksIn: String?)

    /// The word that begins an entry following the defaults.
    static let defaultWord = "default"

    /// The entry TextMouth writes for an action the user edited: its keys,
    /// as a list.
    static func edited(_ keys: [KeyBinding]) -> ShortcutListing {
        .list(keys.map(\.configText))
    }

    /// The entry TextMouth writes for an action the user edited that works
    /// in a scope the user chose (FR12's branch E): its keys, and the scope
    /// in the Works in pop-up's words, as in `{"keys": ["shift+command+t"],
    /// "worksIn": "Every window"}`.
    static func edited(_ keys: [KeyBinding], worksIn scope: ShortcutScope) -> ShortcutListing {
        .object(keys: keys.map(\.configText), worksIn: scope.title)
    }

    /// The entry TextMouth writes for an action following the defaults:
    /// "default: " and its keys in force, such as "default: space, k", or
    /// "default: none" for an action that has none; and, for one working
    /// where its default scope is said (`ShortcutScope.isSaidAsADefault`,
    /// FR12's branch E), that kind of window after "default", so the file
    /// says why another action may have the same key: "default in reader
    /// windows: shift+command+t".
    static func followingDefaults(_ keysInForce: [KeyBinding], worksIn scope: ShortcutScope = .app) -> ShortcutListing {
        let keys = keysInForce.isEmpty ? "none" : keysInForce.map(\.configText).joined(separator: ", ")
        let words = scope.isSaidAsADefault ? "\(defaultWord) in \(scope.inSentence)" : defaultWord
        return .text("\(words): \(keys)")
    }

    /// Whether the entry gives the action TextMouth's defaults: text that
    /// begins with "default", in any letter case, after any spaces.
    var followsDefaults: Bool {
        guard case .text(let words) = self else { return false }
        return words.drop(while: \.isWhitespace).lowercased().hasPrefix(Self.defaultWord)
    }

    /// Whether the entry is in a form only the record of the user's edits
    /// writes (FR12): text following the defaults, or an object (FR12's
    /// branch E). The form earlier releases wrote, a list for every
    /// action, holds neither.
    var isInTheRecordsForm: Bool {
        if case .object = self {
            return true
        }
        return followsDefaults
    }

    /// The keys the entry makes the user's: a list's or an object's, each
    /// read as `KeyBinding(configText:)` reads it and kept once, or the one
    /// shortcut other text names. Nil for an entry following the defaults,
    /// and for one holding a shortcut that cannot be read, which leaves the
    /// action as it is rather than dropping that shortcut and keeping the
    /// rest.
    var bindings: [KeyBinding]? {
        switch self {
        case .list(let shortcuts), .object(let shortcuts, _):
            return KeyBinding.bindings(fromConfigTexts: shortcuts)
        case .text(let shortcut):
            guard !followsDefaults else { return nil }
            return KeyBinding(configText: shortcut).map { [$0] }
        }
    }

    /// Where the entry has `action` work (FR12's branch E): the kind of
    /// window an object names, read as `ShortcutScope.named(_:)` reads it,
    /// or the action's default for every other entry and an object naming
    /// none. Nil for an object naming no kind of window TextMouth knows,
    /// which cannot be used. Whether `action` may work there is
    /// `ShortcutEdits.entriesLeftOut(of:)`'s to say.
    func scope(for action: ShortcutAction) -> ShortcutScope? {
        guard case .object(_, let name?) = self else { return action.defaultScope }
        return ShortcutScope.named(name)
    }

    /// The entry as TextMouth writes it, or nil when it cannot be used: a
    /// list, one shortcut written as text, or an object naming no kind of
    /// window becomes a list of shortcuts written as TextMouth writes them,
    /// and an object naming one holds them with that kind of window in the
    /// Works in pop-up's words; text following the defaults is kept as
    /// written, since TextMouth never reads its words. An object naming a
    /// kind of window TextMouth does not know cannot be used, as a shortcut
    /// it cannot read cannot.
    var validated: ShortcutListing? {
        if followsDefaults {
            return self
        }
        guard let keys = bindings else { return nil }
        guard case .object(_, let name?) = self else { return .edited(keys) }
        return ShortcutScope.named(name).map { .edited(keys, worksIn: $0) }
    }

    /// Why the keys this entry gives `action` cannot be its keys
    /// (`ShortcutAction.refusal(ofKeys:holding:)`, FR12's branch D, holding
    /// none: an entry the record holds already is let through before this
    /// is asked, `ShortcutEdits.entriesLeftOut(of:)`), or nil when they can
    /// or the entry gives none.
    func refusal(for action: ShortcutAction) -> ShortcutRefusal? {
        bindings.flatMap { action.refusal(ofKeys: $0) }
    }

    /// A list of shortcuts, written as an array literal.
    init(arrayLiteral shortcuts: String...) {
        self = .list(shortcuts)
    }

    /// Text, written as a string literal.
    init(stringLiteral words: String) {
        self = .text(words)
    }

    /// Reads a list of text, text, or an object holding its keys and, when
    /// it names one, the kind of window they work in (`object(from:)`);
    /// anything else cannot be read.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let shortcuts = try? container.decode([String].self) {
            self = .list(shortcuts)
        } else if let words = try? container.decode(String.self) {
            self = .text(words)
        } else {
            self = try Self.object(from: decoder)
        }
    }

    /// Reads an entry written as an object (FR12's branch E): "keys", a list
    /// of text or one text, and "worksIn", text, which may be left out or
    /// null; each field named in any letter case, with spaces or without, as
    /// "Works In". An object without keys cannot be read.
    private static func object(from decoder: Decoder) throws -> ShortcutListing {
        let object = try decoder.container(keyedBy: ShortcutJSONKey.self)
        // The object's own spelling of `field`, if it has the field.
        func spelling(of field: ShortcutJSONKey) -> ShortcutJSONKey? {
            object.allKeys.first { $0.comparableName == field.comparableName }
        }
        guard let keysField = spelling(of: .keys) else {
            throw DecodingError.keyNotFound(ShortcutJSONKey.keys, DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "An entry written as an object lists its keys"
            ))
        }
        let keys: [String]
        if let shortcuts = try? object.decode([String].self, forKey: keysField) {
            keys = shortcuts
        } else {
            keys = [try object.decode(String.self, forKey: keysField)]
        }
        let worksIn = try spelling(of: .worksIn).flatMap { try object.decodeIfPresent(String.self, forKey: $0) }
        return .object(keys: keys, worksIn: worksIn)
    }

    /// Writes a list as a list, text as text, and an object as an object of
    /// its keys and, when it names one, the kind of window they work in.
    func encode(to encoder: Encoder) throws {
        switch self {
        case .list(let shortcuts):
            var container = encoder.singleValueContainer()
            try container.encode(shortcuts)
        case .text(let words):
            var container = encoder.singleValueContainer()
            try container.encode(words)
        case .object(let shortcuts, let worksIn):
            var container = encoder.container(keyedBy: ShortcutJSONKey.self)
            try container.encode(shortcuts, forKey: .keys)
            try container.encodeIfPresent(worksIn, forKey: .worksIn)
        }
    }
}

extension ShortcutAction {
    /// The action config.json's `name` names: its name as Settings shows it,
    /// in any letter case, the exact name tried first, so "where am i?" is
    /// Where Am I?; and a name ending in an ellipsis may end in three periods
    /// or none instead (FR12's branch D), so "open book..." and "Open Book"
    /// are Open Book…, as a name typed on a braille display is likely to
    /// read. A renamed action's former name (`formerNames`) names it the same
    /// ways. Nil for a name that names none.
    static func named(_ name: String) -> ShortcutAction? {
        if let exact = exactlyNamed(name) {
            return exact
        }
        let wanted = comparableName(name)
        return allCases.first { comparableName($0.rawValue) == wanted }
            ?? formerNames.first { comparableName($0.key) == wanted }?.value
    }

    /// The action `name` is, letter for letter: the name TextMouth writes for
    /// it now (its raw value), or one it wrote before (`formerNames`), as the
    /// record of the user's edits names actions (`ShortcutEdits.reading(_:)`).
    static func exactlyNamed(_ name: String) -> ShortcutAction? {
        ShortcutAction(rawValue: name) ?? formerNames[name]
    }

    /// The names actions had before they were renamed, each with its
    /// action, still read in config.json and in the record of the user's
    /// edits (`named(_:)`, `exactlyNamed(_:)`), so an edit made under a
    /// former name is never lost; TextMouth writes only the names in force.
    /// The Record window's buttons were named under "Recording Window" until
    /// their group took the window's own name, New Recording (REV11). The
    /// bookmark command was named Add Bookmark until the Bookmarks menu's
    /// name for it, Toggle Bookmark, became its one name (#1937). Import
    /// Folder… was Import DAISY Folder… until it took folders of audio
    /// tracks too (FR17).
    static let formerNames: [String: ShortcutAction] = [
        "Recording Window: Record": .recordingRecord,
        "Recording Window: Pause or Resume": .recordingPauseOrResume,
        "Recording Window: Stop": .recordingStop,
        "Add Bookmark": .addBookmark,
        "Import DAISY Folder…": .importDAISYFolder,
    ]

    /// `name` as `named(_:)` compares names: in lower case, without an
    /// ellipsis at its end, written as one character or as three periods.
    /// No two actions' names, nor former names, compare alike (a test
    /// checks).
    static func comparableName(_ name: String) -> String {
        var compared = name.lowercased()
        for ellipsis in ["…", "..."] where compared.hasSuffix(ellipsis) {
            compared.removeLast(ellipsis.count)
        }
        return compared
    }
}

/// All default keyboard shortcut bindings
extension ShortcutAction {
    /// Default bindings for each action (primary + optional secondary),
    /// built once: every Shortcuts row and Record window button reads them,
    /// through the keys in force, as it is drawn, and so does each key's
    /// refusal check (`refusal(of:)`), which once rebuilt the whole table
    /// each time (REV11).
    static let defaultBindings: [ShortcutAction: [KeyBinding]] = {
        let everywhereElse: [ShortcutAction: [KeyBinding]] = [
            .togglePlayback: [
                KeyBinding(key: "space"),
                KeyBinding(key: "k")
            ],
            .releaseMediaControls: [],
            .skipForward: [
                KeyBinding(key: "rightArrow", command: true),
                KeyBinding(key: "l")
            ],
            .skipBackward: [
                KeyBinding(key: "leftArrow", command: true),
                KeyBinding(key: "j")
            ],
            .cycleForwardNavigationUnit: [
                // A plain key keeps unit changes as quick as J/K/L playback
                // navigation while text-input focus protection prevents typing
                // in search and metadata fields from triggering it.
                KeyBinding(key: "f")
            ],
            .cycleBackwardNavigationUnit: [
                KeyBinding(key: "b")
            ],
            .increaseSpeed: [
                KeyBinding(key: "+", command: true)
            ],
            .decreaseSpeed: [
                KeyBinding(key: "-", command: true)
            ],
            // The menu commands' keys, fixed before FR12's branch D and
            // their defaults since, as are the Record window's below: one
            // press with Command or Control each, the key equivalent of its
            // menu item or button.
            .copyReadingPosition: [KeyBinding(key: "p", command: true, shift: true)],
            .searchInBook: [KeyBinding(key: "f", command: true)],
            // Option-Command-F, which no other default uses, no menu of the
            // app has, and `KeyBinding.systemCommands` does not list (a test
            // checks each): Search Library… works in every window, so its key
            // may be no window's other action, and Command-F is Search in
            // Book's in a reader.
            .searchLibrary: [KeyBinding(key: "f", command: true, option: true)],
            .goToLibrary: [
                KeyBinding(key: "l", command: true)
            ],
            .goBack: [
                KeyBinding(key: "[", command: true)
            ],
            .goForward: [
                KeyBinding(key: "]", command: true)
            ],
            .navigateUpLevel: [
                KeyBinding(key: "upArrow", command: true)
            ],
            .nextHeading: [
                KeyBinding(key: "downArrow", command: true, option: true)
            ],
            .previousHeading: [
                KeyBinding(key: "upArrow", command: true, option: true)
            ],
            // Go to Page… (PG03): Option-Command-G, which no other default
            // uses.
            .goToPage: [
                KeyBinding(key: "g", command: true, option: true)
            ],
            // No keys by default (FR09): the user gives them keys of their
            // choosing in Settings, as the reading list's Library commands.
            .nextInReadingList: [],
            .previousInReadingList: [],
            // No keys by default either (0.2.5).
            .nextInFolder: [],
            .previousInFolder: [],
            .addBookmark: [
                KeyBinding(key: "b", command: true)
            ],
            .nextBookmark: [
                KeyBinding(key: "b", command: true, option: true, shift: true)
            ],
            .previousBookmark: [
                KeyBinding(key: "b", command: true, option: true)
            ],
            .showHeadingList: [
                KeyBinding(key: "h", command: true, shift: true)
            ],
            .showBookmarkList: [
                KeyBinding(key: "b", command: true, shift: true)
            ],
            .showSleepTimer: [
                KeyBinding(key: "t", command: true, shift: true)
            ],
            .restartSleepTimer: [
                // Cmd+Shift+R — chosen to avoid existing bindings.
                // KeyboardShortcutManager.addBinding strips this from
                // any other action automatically if a user reassigns
                // it later, so conflicts resolve themselves.
                KeyBinding(key: "r", command: true, shift: true)
            ],
            .whereAmI: [
                KeyBinding(key: "w")
            ],
            // W twice (FR12, the user's yes of October 7): the first W
            // speaks the brief summary at once, and a second within the
            // double-press time switches to the full one, which escalates
            // it (`escalates`), so W never waits.
            .whereAmIFull: [
                KeyBinding(key: "w", isDoublePress: true)
            ],
            .speakInfo: [
                // Shift-Command-I, as the user chose on October 17: a
                // letter pressed alone belongs to the Library list's
                // letter navigation (it jumps to the first book of that
                // letter), so Speak Info needs a modified key. Book Info
                // keeps Command-I, and the audio editor's Mark In has I
                // in its own scope.
                KeyBinding(key: "i", command: true, shift: true)
            ],
            // The same stroke twice speaks the full summary (FR12), as W
            // twice does for Where Am I?: the dispatcher compares whole
            // strokes, modifiers included, so the escalation holds.
            .speakFullInfo: [
                KeyBinding(key: "i", command: true, shift: true, isDoublePress: true)
            ],
            // No key by default (FR10): the user gives it a key of their
            // choosing in Settings, as Release Media Controls.
            .speakImportProgress: [],
            // Likewise for the feed downloads (FR10's feed half).
            .speakDownloadProgress: [],
            .openSelectedBook: [
                KeyBinding(key: "return")
            ],
            .showBookInfo: [
                KeyBinding(key: "i", command: true)
            ],
            .removeFromLibrary: [
                KeyBinding(key: "delete", command: true)
            ],
            .newFolder: [
                KeyBinding(key: "n", command: true, shift: true)
            ],
            .moveToFolder: [
                KeyBinding(key: "m", command: true, shift: true)
            ],
            // No key by default (FR11, branch D): the user gives it one of
            // their choosing in Settings.
            .moveToLibrary: [],
            .selectAll: [
                KeyBinding(key: "a", command: true)
            ],
            .toggleEditMode: [
                KeyBinding(key: "e", command: true)
            ],
            .moveBookUp: [
                KeyBinding(key: "upArrow", command: true, shift: true)
            ],
            .moveBookDown: [
                KeyBinding(key: "downArrow", command: true, shift: true)
            ],
            // No keys by default (FR09): the user gives them keys of their
            // choosing in Settings, as Release Media Controls.
            .addToReadingList: [],
            .removeFromReadingList: [],
            // No key by default (FR19), as the reading-list commands have
            // none: the user gives it one of their choosing in Settings.
            .folderOrFeedSettings: [],
            // Command-1 to Command-9, which no other default uses: the first
            // to the ninth view a Library window offers (October 30, 2026).
            .goToView1: [KeyBinding(key: "1", command: true)],
            .goToView2: [KeyBinding(key: "2", command: true)],
            .goToView3: [KeyBinding(key: "3", command: true)],
            .goToView4: [KeyBinding(key: "4", command: true)],
            .goToView5: [KeyBinding(key: "5", command: true)],
            .goToView6: [KeyBinding(key: "6", command: true)],
            .goToView7: [KeyBinding(key: "7", command: true)],
            .goToView8: [KeyBinding(key: "8", command: true)],
            .goToView9: [KeyBinding(key: "9", command: true)],
            .importDAISYFolder: [KeyBinding(key: "o", command: true, shift: true)],
            // Shift-Command-F: Command-F alone searches a book.
            .addFeed: [KeyBinding(key: "f", command: true, shift: true)],
            .openBook: [KeyBinding(key: "o", command: true)],
            // Show Sleep Timer's default too: New from Text has it in
            // Library windows, and Show Sleep Timer in reader windows (FR12's
            // branch E, #1451), where each works.
            .newFromText: [KeyBinding(key: "t", command: true, shift: true)],
            // Beside Command-N for a new Library window.
            .newRecording: [KeyBinding(key: "n", command: true, option: true)],
            // The Record window's Record, Pause or Resume, and Stop.
            .recordingRecord: [KeyBinding(key: "r", command: true)],
            .recordingPauseOrResume: [KeyBinding(key: "p", command: true)],
            .recordingStop: [KeyBinding(key: ".", command: true)],
        ]
        return everywhereElse.merging(audioEditorDefaultBindings) { existing, _ in existing }
    }()

    /// The defaults actions had before today's, for the move to the record
    /// of the user's edits alone (FR12, `ShortcutEdits.migrating`): a saved
    /// key equal to one of them is a default the whole-map save froze, not
    /// the user's choice, so the action follows today's default from then
    /// on. Only three defaults ever changed: Move Book Up and Move Book Down
    /// left Control-Option-Up and Control-Option-Down for Shift-Command-Up
    /// and Shift-Command-Down on March 22, 2026 (1ec35f02), and Next
    /// Bookmark left Shift-Command-B for Option-Shift-Command-B on March 24
    /// (ffb538b1), when Show Bookmarks took Shift-Command-B. The move runs
    /// once; a default changed after it reaches every unedited action
    /// through the record, and needs no entry here.
    static let formerDefaultBindings: [ShortcutAction: [[KeyBinding]]] = [
        .moveBookUp: [[KeyBinding(key: "upArrow", option: true, control: true)]],
        .moveBookDown: [[KeyBinding(key: "downArrow", option: true, control: true)]],
        .nextBookmark: [[KeyBinding(key: "b", command: true, shift: true)]],
    ]

    /// The audio editor's default bindings (FR04): single keys wherever one
    /// fits, as the user chose on October 4, matched only in an editor
    /// window (`ShortcutScope.audioEditor`), so Space, J, K, and L play and
    /// move there as they do in a reader. None of them is any other editor
    /// action's, and the Command ones are no menu command's but the Edit
    /// menu's own Undo, Redo, Cut, Copy, Paste, and Select All, which the
    /// editor answers itself (the shortcut tests check both). Built once, as
    /// `defaultBindings` is.
    static let audioEditorDefaultBindings: [ShortcutAction: [KeyBinding]] = [
        .editorPlayPause: [KeyBinding(key: "space"), KeyBinding(key: "k")],
        .editorStop: [KeyBinding(key: "s")],
        // J and Comma go back, L and Period forward: a second; Shift-J
        // and Shift-L ten; with Option, a tenth.
        .editorSkipBack: [KeyBinding(key: "j"), KeyBinding(key: ",")],
        .editorSkipForward: [KeyBinding(key: "l"), KeyBinding(key: ".")],
        .editorSkipBackLong: [KeyBinding(key: "j", shift: true)],
        .editorSkipForwardLong: [KeyBinding(key: "l", shift: true)],
        .editorSkipBackShort: [KeyBinding(key: "j", option: true), KeyBinding(key: ",", option: true)],
        .editorSkipForwardShort: [KeyBinding(key: "l", option: true), KeyBinding(key: ".", option: true)],
        // The start and the end of the audio, as of a document.
        .editorGoToStart: [KeyBinding(key: "upArrow", command: true)],
        .editorGoToEnd: [KeyBinding(key: "downArrow", command: true)],
        .editorGoToTime: [KeyBinding(key: "g")],
        // Chapter markers by the reader's keys for headings.
        .editorPreviousChapter: [KeyBinding(key: "upArrow", command: true, option: true)],
        .editorNextChapter: [KeyBinding(key: "downArrow", command: true, option: true)],
        .editorPreviousPause: [KeyBinding(key: "n", shift: true)],
        .editorNextPause: [KeyBinding(key: "n")],
        .editorWhereAmI: [KeyBinding(key: "w")],
        // In and Out, as in video editors; the selection said in full
        // with Shift-W, beside Where Am I.
        .editorMarkIn: [KeyBinding(key: "i")],
        .editorMarkOut: [KeyBinding(key: "o")],
        .editorSelectToPreviousPause: [KeyBinding(key: "n", option: true, shift: true)],
        .editorSelectToNextPause: [KeyBinding(key: "n", option: true)],
        .editorSelectChapter: [KeyBinding(key: "c")],
        .editorSelectAll: [KeyBinding(key: "a", command: true)],
        .editorClearSelection: [KeyBinding(key: "escape")],
        .editorSpeakSelection: [KeyBinding(key: "w", shift: true)],
        .editorPlaySelection: [KeyBinding(key: "p")],
        .editorAddMarker: [KeyBinding(key: "m")],
        .editorShowMarkers: [KeyBinding(key: "m", shift: true)],
        // The Edit menu's keys, which the editor answers itself, and
        // Delete for Cut, as the user asked.
        .editorUndo: [KeyBinding(key: "z", command: true)],
        .editorRedo: [KeyBinding(key: "z", command: true, shift: true)],
        .editorCut: [KeyBinding(key: "delete"), KeyBinding(key: "x", command: true)],
        .editorCopy: [KeyBinding(key: "c", command: true)],
        .editorPaste: [KeyBinding(key: "v", command: true)],
        .editorTrimToSelection: [KeyBinding(key: "t")],
        .editorInsertSilence: [KeyBinding(key: "s", shift: true)],
        .editorInsertChapter: [KeyBinding(key: "c", shift: true)],
        .editorApplyFilter: [KeyBinding(key: "f")],
        .editorPunchIn: [KeyBinding(key: "r")],
        // Saving, as documents save; Revert beside Undo, asking first.
        .editorSave: [KeyBinding(key: "s", command: true)],
        .editorExport: [KeyBinding(key: "e", command: true, shift: true)],
        .editorRevert: [KeyBinding(key: "z", command: true, option: true)],
        .editorInfo: [KeyBinding(key: "i", command: true)],
    ]
}
