import SwiftUI

// MARK: - Window Type Tracking

/// Identifies which type of window currently has focus, used to show/hide
/// menus that only apply to a specific window type.
enum ActiveWindowType {
    case library
    case reader
}

/// FocusedValue key for the active window type
struct ActiveWindowTypeKey: FocusedValueKey {
    typealias Value = ActiveWindowType
}

extension FocusedValues {
    var activeWindowType: ActiveWindowType? {
        get { self[ActiveWindowTypeKey.self] }
        set { self[ActiveWindowTypeKey.self] = newValue }
    }
}

// MARK: - Menu Commands

struct PlaybackCommands: Commands {
    @FocusedValue(\.activeWindowType) var windowType
    var body: some Commands {
        CommandMenu("Playback") {
            if windowType == .reader {
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
}

struct NavigationCommands: Commands {
    @FocusedValue(\.activeWindowType) var windowType
    var body: some Commands {
        CommandMenu("Navigate") {
            if windowType == .reader {
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

                Button("Book Info") {
                    NotificationCenter.default.post(name: .showBookInfo, object: nil)
                }
                // Cmd+I is handled by KeyboardShortcutManager which includes window focus
                // info in the notification. Adding .keyboardShortcut here would cause
                // a second notification without focus info, opening dialogs in every window.
            }
        }
    }
}

struct LibraryCommands: Commands {
    @FocusedValue(\.activeWindowType) var windowType
    var body: some Commands {
        CommandMenu("Library") {
            if windowType == .library {
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

            Button("Remove from Library") {
                NotificationCenter.default.post(name: .removeFromLibrary, object: nil)
            }
            // Cmd+Delete handled by KeyboardShortcutManager for window targeting
            }
        }
    }
}

struct BookmarkCommands: Commands {
    @FocusedValue(\.activeWindowType) var windowType
    var body: some Commands {
        CommandMenu("Bookmarks") {
            if windowType == .reader {
                Button("Add Bookmark") {
                    NotificationCenter.default.post(name: .addBookmark, object: nil)
                }

                Button("Next Bookmark") {
                    NotificationCenter.default.post(name: .nextBookmark, object: nil)
                }

                Button("Previous Bookmark") {
                    NotificationCenter.default.post(name: .previousBookmark, object: nil)
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let togglePlayback = Notification.Name("togglePlayback")
    static let skipForward = Notification.Name("skipForward")
    static let skipBackward = Notification.Name("skipBackward")
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
    static let showBookInfo = Notification.Name("showBookInfo")
    static let openSelectedBook = Notification.Name("openSelectedBook")
    static let copyReadingPosition = Notification.Name("copyReadingPosition")
    static let searchInBook = Notification.Name("searchInBook")
    static let newFromText = Notification.Name("newFromText")
    static let continueToNextBook = Notification.Name("continueToNextBook")
    static let removeFromLibrary = Notification.Name("removeFromLibrary")
    static let newFolder = Notification.Name("newFolder")
    static let moveToFolder = Notification.Name("moveToFolder")
    static let selectAll = Notification.Name("selectAll")
    static let toggleEditMode = Notification.Name("toggleEditMode")
    static let moveBookUp = Notification.Name("moveBookUp")
    static let moveBookDown = Notification.Name("moveBookDown")
}
