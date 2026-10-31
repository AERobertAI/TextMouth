import Foundation

/// What the Library tab of Settings says (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 9, "The Library tab"):
/// every label, hint, caption, alert, and announcement of the list of the
/// Library window's views, the same on screen, to VoiceOver, and on a
/// braille display.
enum LibraryViewsSettingsWording {
    // MARK: - The Tab

    /// The tab's name in the Settings window's toolbar.
    static let tabTitle = "Library"
    /// The heading above the list.
    static let sectionHeader = "Views"
    /// What the list is, and where a new window opens.
    static let orderCaption = "The Library window's View pop-up offers these views, in this order. "
        + "A new Library window opens at the first one it offers."
    /// What the three visibilities do, and that a window keeps its view.
    static let visibilityCaption = "Always offers a view all the time. When Applicable offers it only while it lists "
        + "something: the Reading List while it holds a book, an episode, or an article, and Feeds while there is a "
        + "feed. Hidden leaves it out. A window showing a view keeps it until you choose another."

    // MARK: - The List

    /// What VoiceOver calls the list.
    static let listLabel = "Views"

    /// A view's row as VoiceOver reads it and a braille display shows it, in
    /// one element: "Reading List, built in, always, 5 of 6".
    static func rowLabel(name: String, isBuiltIn: Bool, visibility: LibraryViewVisibility, number: Int, count: Int) -> String {
        "\(name), \(isBuiltIn ? builtIn : custom), \(visibilityWord(visibility)), \(number) of \(count)"
    }

    /// The row's word for a view TextMouth made.
    static let builtIn = "built in"
    /// The row's word for a view the listener made.
    static let custom = "custom"

    /// A visibility as the row says it, in a sentence: "always", "when
    /// applicable", or "hidden".
    static func visibilityWord(_ visibility: LibraryViewVisibility) -> String {
        visibilityName(visibility).lowercased()
    }

    /// A visibility as the Visibility pop-up names it: "Always", "When
    /// Applicable", or "Hidden".
    static func visibilityName(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return "Always"
        case .whenApplicable: return "When Applicable"
        case .hidden: return "Hidden"
        }
    }

    /// Folders' row hint: what it shows.
    static let foldersHint = "Shows one folder at a time"
    /// The Reading List's row hint: what it shows.
    static let readingListHint = "Shows the books in the order you arrange"

    // MARK: - Commands

    /// The command that moves a view one place up, as a VoiceOver action
    /// and a context menu item.
    static let moveUpAction = "Move Up"
    /// The command that moves a view one place down.
    static let moveDownAction = "Move Down"
    /// The command that gives a view `visibility`: "Show Always", "Show When
    /// Applicable", or "Hide".
    static func showAction(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return "Show Always"
        case .whenApplicable: return "Show When Applicable"
        case .hidden: return "Hide"
        }
    }
    /// The command that makes a custom copy of a view.
    static let duplicateAction = "Duplicate"
    /// The command that deletes a custom view, asking first.
    static let deleteAction = "Delete…"
    /// The command that gives a built-in view back its own, asking first.
    static let restoreAction = "Restore Default…"

    // MARK: - Visibility

    /// The Visibility pop-up's visible label.
    static let visibilityTitle = "Visibility"
    /// The Visibility pop-up's spoken label, naming the view it sets.
    static func visibilityLabel(name: String) -> String {
        "Visibility of \(name)"
    }
    /// The Visibility pop-up's hint.
    static let visibilityHint = "Sets when the View pop-up offers this view"
    /// The Visibility pop-up's hint for Folders, whose visibility is fixed.
    static let foldersVisibilityHint = "Folders is always shown: every folder and feed opens there."

    // MARK: - Moving

    /// The Move Up button's spoken label, naming the view it moves.
    static func moveUpLabel(name: String) -> String {
        "Move \(name) Up"
    }
    /// The Move Down button's spoken label.
    static func moveDownLabel(name: String) -> String {
        "Move \(name) Down"
    }
    /// The Move Up button's hint.
    static let moveUpHint = "Moves the view one place up the list"
    /// The Move Down button's hint.
    static let moveDownHint = "Moves the view one place down the list"
    /// Move Up's hint while the view is first, when it is dimmed.
    static let firstInListHint = "The view is first in the list."
    /// Move Down's hint while the view is last, when it is dimmed.
    static let lastInListHint = "The view is last in the list."
    /// What VoiceOver says after a move: the view and its new place,
    /// "Reading List, 4 of 6", short enough to hear after each of many
    /// moves.
    static func placeAnnouncement(name: String, number: Int, count: Int) -> String {
        "\(name), \(number) of \(count)"
    }

    // MARK: - Duplicate

    /// Duplicate's hint.
    static let duplicateHint = "Makes a view of your own with this view's conditions and sort."
    /// Duplicate's hint for Folders and the Reading List, when it is dimmed.
    static let duplicateUnavailableHint = "Folders and the Reading List have no conditions to copy."
    /// What VoiceOver says after Duplicate: the copy and its place.
    static func duplicated(name: String, number: Int, count: Int) -> String {
        "Made \(name), \(number) of \(count)."
    }

    // MARK: - Delete

    /// Delete…'s hint.
    static let deleteHint = "Deletes the view. What it lists stays in the library."
    /// Delete…'s hint for a built-in view, when it is dimmed.
    static let deleteBuiltInHint = "A built-in view can be hidden, not deleted."
    /// The question Delete… asks.
    static func deleteTitle(name: String) -> String {
        "Delete the view “\(name)”?"
    }
    /// What the question says Delete does, and what it keeps.
    static let deleteMessage = "Its conditions and sort are deleted. The books, episodes, articles, and feeds it "
        + "lists stay in the library, and a Library window showing it shows another view."
    /// The question's button that deletes.
    static let deleteButton = "Delete"
    /// The button of either question that changes nothing.
    static let cancelButton = "Cancel"
    /// What VoiceOver says once the view is deleted.
    static func deleted(name: String) -> String {
        "Deleted \(name)."
    }

    // MARK: - Restore Default

    /// Restore Default…'s hint.
    static let restoreHint = "Gives the view back the name, conditions, sort, and limit TextMouth gave it."
    /// Restore Default…'s hint for a built-in view as TextMouth made it, or
    /// Folders or the Reading List, when it is dimmed.
    static let restoreUnchangedHint = "This view is as TextMouth made it."
    /// Restore Default…'s hint for a view the listener made, when it is
    /// dimmed.
    static let restoreCustomHint = "A view you made has no default to restore."
    /// The question Restore Default… asks.
    static func restoreTitle(name: String) -> String {
        "Restore “\(name)” to its default?"
    }
    /// What the question says Restore Default does, and what it keeps.
    static let restoreMessage = "Its name, conditions, sort, and limit go back to TextMouth's own. "
        + "Its place in the list and when it is offered stay as they are."
    /// The question's button that restores.
    static let restoreButton = "Restore Default"
    /// What VoiceOver says once the view is restored, by its restored name.
    static func restored(name: String) -> String {
        "Restored \(name)."
    }

    // MARK: - Added October 31, 2026 (the review of team/views)

    /// New View… and Duplicate's hint at the limit, when they are dimmed,
    /// and Save's problem there (finding 1).
    static let viewLimit = "The Library holds at most \(LibraryViewDefinitionList.entryLimit) views."

    /// What Restore Default says, changing nothing, when another view has
    /// the shipped name `name` (finding 5).
    static func restoreNameTaken(name: String) -> String {
        "Another view is named \(name). Rename it first, then restore this view."
    }

    /// What VoiceOver says after a row's action or the context menu gives
    /// the view `name` a visibility (finding 12): "Feeds, hidden", "Feeds,
    /// shown always", "Feeds, shown when applicable". The pop-up says its
    /// own new value.
    static func visibilityChanged(name: String, to visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return "\(name), shown always"
        case .whenApplicable: return "\(name), shown when applicable"
        case .hidden: return "\(name), hidden"
        }
    }

    /// What VoiceOver says once a view is deleted, naming the view selected
    /// now and its place (finding 13): "Deleted Mine. Feeds selected, 6 of
    /// 6."
    static func deleted(name: String, selected: String, number: Int, count: Int) -> String {
        "Deleted \(name). \(selected) selected, \(number) of \(count)."
    }

    // MARK: - Views a Later TextMouth Wrote

    /// What the tab says of entries this TextMouth cannot read: "1 view
    /// needs a newer TextMouth. It is kept as it is, and not offered."
    static func unreadableCaption(count: Int) -> String {
        count == 1
            ? "1 view needs a newer TextMouth. It is kept as it is, and not offered."
            : "\(count) views need a newer TextMouth. They are kept as they are, and not offered."
    }
}
