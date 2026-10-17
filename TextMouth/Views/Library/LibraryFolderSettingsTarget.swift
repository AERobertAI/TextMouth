import Foundation

/// Every word the Library toolbar's "Feed Settings" and "Folder Settings"
/// button says and speaks (FR19), and the line said when its shortcut is
/// pressed where no folder is shown. One place, so a test pins each string:
/// the listener hears them through VoiceOver and reads them in braille.
enum LibraryFolderSettingsWording {

    /// The button's title in a feed's folder.
    static let feedButtonTitle = "Feed Settings"

    /// The button's title in a plain folder.
    static let folderButtonTitle = "Folder Settings"

    /// What VoiceOver calls the button in the folder of the feed `title`.
    static func feedLabel(title: String) -> String {
        "Feed settings for \(title)"
    }

    /// What VoiceOver calls the button in the plain folder `name`.
    static func folderLabel(name: String) -> String {
        "Folder settings for \(name)"
    }

    /// What VoiceOver says the button does, in a feed's folder.
    static let feedHint = "Opens the settings of this feed: where its downloads go, what it lists and downloads, and what happens when an episode ends"

    /// What VoiceOver says the button does, in a plain folder.
    static let folderHint = "Opens the settings of this folder: what it holds, and what happens when one of its books ends"

    /// The symbol both buttons draw.
    static let systemImage = "slider.horizontal.3"

    /// Said when the Folder or Feed Settings shortcut is pressed where the
    /// window shows no folder: the top level, or a category but Folders.
    static let nothingToOpen = "Open a folder first to see its settings"
}

/// What the Library toolbar's settings button opens (FR19): the settings of
/// the folder the window shows. A feed's folder opens the feed's Feed Info
/// sheet, as Command-I on its row does; a plain folder opens the Folder
/// Settings sheet. Nothing opens at the library's top level, nor in any
/// category but Folders, which show no one folder.
enum LibraryFolderSettingsTarget: Equatable {
    /// The folder of the feed `feedID`, whose title is `title`.
    case feed(feedID: UUID, title: String)
    /// The plain folder `folderID`, named `name`.
    case folder(folderID: UUID, name: String)

    /// The target for a window showing `folderPath` of `category`, or nil
    /// when it shows no folder. `feedID` finds the feed whose downloads go
    /// to a folder, and `feedTitle` a feed's title; a feed whose record is
    /// gone falls back to its folder's name.
    static func of(
        category: LibraryCategory,
        folderPath: String,
        folders: [BookFolder],
        feedID: (UUID) -> UUID?,
        feedTitle: (UUID) -> String?
    ) -> LibraryFolderSettingsTarget? {
        // Only the Folders category shows a folder, and the top level, the
        // empty path, is no folder.
        guard category == .folders, !folderPath.isEmpty,
              let folder = folders.first(where: { $0.fullPath == folderPath }) else {
            return nil
        }
        guard let feed = feedID(folder.id) else {
            return .folder(folderID: folder.id, name: folder.name)
        }
        return .feed(feedID: feed, title: feedTitle(feed) ?? folder.name)
    }

    /// Opens the settings `target` names, by the one path the toolbar's
    /// button and the Folder or Feed Settings command share: a feed's goes
    /// through `showFeedInfo`, a plain folder's through `showFolderSettings`,
    /// and with no target (no folder is shown) `announce` says so.
    static func open(
        _ target: LibraryFolderSettingsTarget?,
        showFeedInfo: (UUID) -> Void,
        showFolderSettings: (UUID) -> Void,
        announce: (String) -> Void
    ) {
        switch target {
        case .feed(let feedID, _): showFeedInfo(feedID)
        case .folder(let folderID, _): showFolderSettings(folderID)
        case nil: announce(LibraryFolderSettingsWording.nothingToOpen)
        }
    }

    /// The button's title.
    var buttonTitle: String {
        switch self {
        case .feed: return LibraryFolderSettingsWording.feedButtonTitle
        case .folder: return LibraryFolderSettingsWording.folderButtonTitle
        }
    }

    /// What VoiceOver calls the button.
    var accessibilityLabel: String {
        switch self {
        case .feed(_, let title): return LibraryFolderSettingsWording.feedLabel(title: title)
        case .folder(_, let name): return LibraryFolderSettingsWording.folderLabel(name: name)
        }
    }

    /// What VoiceOver says the button does.
    var accessibilityHint: String {
        switch self {
        case .feed: return LibraryFolderSettingsWording.feedHint
        case .folder: return LibraryFolderSettingsWording.folderHint
        }
    }

    /// The symbol the button draws.
    var systemImage: String { LibraryFolderSettingsWording.systemImage }
}
