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
    static let addBookmark = Notification.Name("addBookmark")
    static let nextBookmark = Notification.Name("nextBookmark")
    static let previousBookmark = Notification.Name("previousBookmark")
    static let goToLibrary = Notification.Name("goToLibrary")
    static let goBack = Notification.Name("goBack")
    static let goForward = Notification.Name("goForward")
    static let navigateUpLevel = Notification.Name("navigateUpLevel")
    static let whereAmI = Notification.Name("whereAmI")
    static let openBookFile = Notification.Name("openBookFile")
    /// Posted by Library > Import DAISY Folder…. One Library window
    /// presents the folder-only panel and imports the folders chosen.
    static let importDAISYFolder = Notification.Name("importDAISYFolder")
    static let showBookInfo = Notification.Name("showBookInfo")
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
    static let showHeadingList = Notification.Name("showHeadingList")
    static let showBookmarkList = Notification.Name("showBookmarkList")
    static let showSleepTimer = Notification.Name("showSleepTimer")
    /// Posted by either the Restart Sleep Timer keyboard shortcut or
    /// the experimental media-gesture detector. ReaderViewModel
    /// listens and either restarts a running timer or re-arms a new
    /// one with the previous duration.
    static let restartSleepTimer = Notification.Name("restartSleepTimer")
}
