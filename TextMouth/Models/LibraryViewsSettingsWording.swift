import Foundation

/// What the Library tab of Settings says (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 9, "The Library tab"):
/// every label, hint, caption, alert, and announcement of the list of the
/// Library window's views, the same on screen, to VoiceOver, and on a
/// braille display.
enum LibraryViewsSettingsWording {
    // MARK: - The Tab

    /// The tab's name in the Settings window's toolbar.
    static var tabTitle: String {
        String(localized: "Library",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The tab's name in the Settings window's toolbar.")
    }
    /// The heading above the list.
    static var sectionHeader: String {
        String(localized: "Views",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The heading above the list.")
    }
    /// What the list is, and where a new window opens.
    static var orderCaption: String {
        String(localized: "The Library window's View pop-up offers these views, in this order. A new Library window opens at the first one it offers.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the list is, and where a new window opens.")
    }
    /// What the three visibilities do, and that a window keeps its view.
    static var visibilityCaption: String {
        String(localized: "Always offers a view all the time. When Applicable offers it only while it lists something: the Reading List while it holds a book, an episode, or an article, and Feeds while there is a feed. Hidden leaves it out. A window showing a view keeps it until you choose another.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the three visibilities do, and that a window keeps its view.")
    }

    // MARK: - The List

    /// What VoiceOver calls the list.
    static var listLabel: String {
        String(localized: "Views",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver calls the list.")
    }

    /// A view's row as VoiceOver reads it and a braille display shows it, in
    /// one element: "Reading List, built in, always, 5 of 6".
    static func rowLabel(name: String, isBuiltIn: Bool, visibility: LibraryViewVisibility, number: Int, count: Int) -> String {
        // The row's two words, localized on their own and joined by commas as the row has always been.
        let origin = isBuiltIn ? builtIn : custom
        let visibilityText = visibilityWord(visibility)
        return String(localized: "\(name), \(origin), \(visibilityText), \(number) of \(count)",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A view's row as VoiceOver reads it and a braille display shows it, in one element: \"Reading List, built in, always, 5 of 6\". %1$@ is the view's name, %2$@ is the word built in or custom, %3$@ is its visibility in lower case (always, when applicable, hidden), %4$lld is its place in the list and %5$lld the number of views.")
    }

    /// The row's word for a view TextMouth made.
    static var builtIn: String {
        String(localized: "built in",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The row's word for a view TextMouth made.")
    }
    /// The row's word for a view the listener made.
    static var custom: String {
        String(localized: "custom",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The row's word for a view the listener made.")
    }

    /// A visibility as the row says it, in a sentence: "always", "when
    /// applicable", or "hidden".
    static func visibilityWord(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always:
            return String(localized: "always",
                          comment: "A Library view's visibility in lower case, inside a row's spoken label: the View pop-up always offers the view.")
        case .whenApplicable:
            return String(localized: "when applicable",
                          comment: "A Library view's visibility in lower case, inside a row's spoken label: the View pop-up offers the view only while it lists something.")
        case .hidden:
            return String(localized: "hidden",
                          comment: "A Library view's visibility in lower case, inside a row's spoken label: the View pop-up does not offer the view.")
        }
    }

    /// A visibility as the Visibility pop-up names it: "Always", "When
    /// Applicable", or "Hidden".
    static func visibilityName(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return String(localized: "Always",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: \"Always\", \"When Applicable\", or \"Hidden\". This is the case .always.")
        case .whenApplicable: return String(localized: "When Applicable",
                                     comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: \"Always\", \"When Applicable\", or \"Hidden\". This is the case .whenApplicable.")
        case .hidden: return String(localized: "Hidden",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: \"Always\", \"When Applicable\", or \"Hidden\". This is the case .hidden.")
        }
    }

    /// Folders' row hint: what it shows.
    static var foldersHint: String {
        String(localized: "Shows one folder at a time",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Folders' row hint: what it shows.")
    }
    /// The Reading List's row hint: what it shows.
    static var readingListHint: String {
        String(localized: "Shows the books in the order you arrange",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Reading List's row hint: what it shows.")
    }

    // MARK: - Commands

    /// The command that moves a view one place up, as a VoiceOver action
    /// and a context menu item.
    static var moveUpAction: String {
        String(localized: "Move Up",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that moves a view one place up, as a VoiceOver action and a context menu item.")
    }
    /// The command that moves a view one place down.
    static var moveDownAction: String {
        String(localized: "Move Down",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that moves a view one place down.")
    }
    /// The command that gives a view `visibility`: "Show Always", "Show When
    /// Applicable", or "Hide".
    static func showAction(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return String(localized: "Show Always",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: \"Show Always\", \"Show When Applicable\", or \"Hide\". This is the case .always.")
        case .whenApplicable: return String(localized: "Show When Applicable",
                                     comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: \"Show Always\", \"Show When Applicable\", or \"Hide\". This is the case .whenApplicable.")
        case .hidden: return String(localized: "Hide",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: \"Show Always\", \"Show When Applicable\", or \"Hide\". This is the case .hidden.")
        }
    }
    /// The command that makes a custom copy of a view.
    static var duplicateAction: String {
        String(localized: "Duplicate",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that makes a custom copy of a view.")
    }
    /// The command that deletes a custom view, asking first.
    static var deleteAction: String {
        String(localized: "Delete…",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that deletes a custom view, asking first.")
    }
    /// The command that gives a built-in view back its own, asking first.
    static var restoreAction: String {
        String(localized: "Restore Default…",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a built-in view back its own, asking first.")
    }

    // MARK: - Visibility

    /// The Visibility pop-up's visible label.
    static var visibilityTitle: String {
        String(localized: "Visibility",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's visible label.")
    }
    /// The Visibility pop-up's spoken label, naming the view it sets.
    static func visibilityLabel(name: String) -> String {
        String(localized: "Visibility of \(name)",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's spoken label, naming the view it sets. Placeholders in order: name.")
    }
    /// The Visibility pop-up's hint.
    static var visibilityHint: String {
        String(localized: "Sets when the View pop-up offers this view",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's hint.")
    }
    /// The Visibility pop-up's hint for Folders, whose visibility is fixed.
    static var foldersVisibilityHint: String {
        String(localized: "Folders is always shown: every folder and feed opens there.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's hint for Folders, whose visibility is fixed.")
    }

    // MARK: - Moving

    /// The Move Up button's spoken label, naming the view it moves.
    static func moveUpLabel(name: String) -> String {
        String(localized: "Move \(name) Up",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Up button's spoken label, naming the view it moves. Placeholders in order: name.")
    }
    /// The Move Down button's spoken label.
    static func moveDownLabel(name: String) -> String {
        String(localized: "Move \(name) Down",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Down button's spoken label. Placeholders in order: name.")
    }
    /// The Move Up button's hint.
    static var moveUpHint: String {
        String(localized: "Moves the view one place up the list",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Up button's hint.")
    }
    /// The Move Down button's hint.
    static var moveDownHint: String {
        String(localized: "Moves the view one place down the list",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Down button's hint.")
    }
    /// Move Up's hint while the view is first, when it is dimmed.
    static var firstInListHint: String {
        String(localized: "The view is first in the list.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Move Up's hint while the view is first, when it is dimmed.")
    }
    /// Move Down's hint while the view is last, when it is dimmed.
    static var lastInListHint: String {
        String(localized: "The view is last in the list.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Move Down's hint while the view is last, when it is dimmed.")
    }
    /// What VoiceOver says after a move: the view and its new place,
    /// "Reading List, 4 of 6", short enough to hear after each of many
    /// moves.
    static func placeAnnouncement(name: String, number: Int, count: Int) -> String {
        String(localized: "\(name), \(number) of \(count)",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a move: the view and its new place, \"Reading List, 4 of 6\", short enough to hear after each of many moves. Placeholders in order: name, number, count.")
    }

    // MARK: - Duplicate

    /// Duplicate's hint.
    static var duplicateHint: String {
        String(localized: "Makes a view of your own with this view's conditions and sort.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Duplicate's hint.")
    }
    /// Duplicate's hint for Folders and the Reading List, when it is dimmed.
    static var duplicateUnavailableHint: String {
        String(localized: "Folders and the Reading List have no conditions to copy.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Duplicate's hint for Folders and the Reading List, when it is dimmed.")
    }
    /// What VoiceOver says after Duplicate: the copy and its place.
    static func duplicated(name: String, number: Int, count: Int) -> String {
        String(localized: "Made \(name), \(number) of \(count).",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after Duplicate: the copy and its place. Placeholders in order: name, number, count.")
    }

    // MARK: - Delete

    /// Delete…'s hint.
    static var deleteHint: String {
        String(localized: "Deletes the view. What it lists stays in the library.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Delete…'s hint.")
    }
    /// Delete…'s hint for a built-in view, when it is dimmed.
    static var deleteBuiltInHint: String {
        String(localized: "A built-in view can be hidden, not deleted.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Delete…'s hint for a built-in view, when it is dimmed.")
    }
    /// The question Delete… asks.
    static func deleteTitle(name: String) -> String {
        String(localized: "Delete the view “\(name)”?",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question Delete… asks. Placeholders in order: name.")
    }
    /// What the question says Delete does, and what it keeps.
    static var deleteMessage: String {
        String(localized: "Its conditions and sort are deleted. The books, episodes, articles, and feeds it lists stay in the library, and a Library window showing it shows another view.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the question says Delete does, and what it keeps.")
    }
    /// The question's button that deletes.
    static var deleteButton: String {
        String(localized: "Delete",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question's button that deletes.")
    }
    /// The button of either question that changes nothing.
    static var cancelButton: String {
        String(localized: "Cancel",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The button of either question that changes nothing.")
    }
    /// What VoiceOver says once the view is deleted.
    static func deleted(name: String) -> String {
        String(localized: "Deleted \(name).",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once the view is deleted. Placeholders in order: name.")
    }

    // MARK: - Restore Default

    /// Restore Default…'s hint.
    static var restoreHint: String {
        String(localized: "Gives the view back the name, conditions, sort, and limit TextMouth gave it.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint.")
    }
    /// Restore Default…'s hint for a built-in view as TextMouth made it, or
    /// Folders or the Reading List, when it is dimmed.
    static var restoreUnchangedHint: String {
        String(localized: "This view is as TextMouth made it.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint for a built-in view as TextMouth made it, or Folders or the Reading List, when it is dimmed.")
    }
    /// Restore Default…'s hint for a view the listener made, when it is
    /// dimmed.
    static var restoreCustomHint: String {
        String(localized: "A view you made has no default to restore.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint for a view the listener made, when it is dimmed.")
    }
    /// The question Restore Default… asks.
    static func restoreTitle(name: String) -> String {
        String(localized: "Restore “\(name)” to its default?",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question Restore Default… asks. Placeholders in order: name.")
    }
    /// What the question says Restore Default does, and what it keeps.
    static var restoreMessage: String {
        String(localized: "Its name, conditions, sort, and limit go back to TextMouth's own. Its place in the list and when it is offered stay as they are.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the question says Restore Default does, and what it keeps.")
    }
    /// The question's button that restores.
    static var restoreButton: String {
        String(localized: "Restore Default",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question's button that restores.")
    }
    /// What VoiceOver says once the view is restored, by its restored name.
    static func restored(name: String) -> String {
        String(localized: "Restored \(name).",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once the view is restored, by its restored name. Placeholders in order: name.")
    }

    // MARK: - Added October 31, 2026 (the review of team/views)

    /// New View… and Duplicate's hint at the limit, when they are dimmed,
    /// and Save's problem there (finding 1).
    static var viewLimit: String {
        String(localized: "The Library holds at most \(LibraryViewDefinitionList.entryLimit) views.",
               comment: "Hint of New View and Duplicate in the Library tab of Settings when the limit is reached, and the problem Save reports there. %lld is the most views the Library holds, a count.")
    }

    /// What Restore Default says, changing nothing, when another view has
    /// the shipped name `name` (finding 5).
    static func restoreNameTaken(name: String) -> String {
        String(localized: "Another view is named \(name). Rename it first, then restore this view.",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What Restore Default says, changing nothing, when another view has the shipped name name (finding 5). Placeholders in order: name.")
    }

    /// What VoiceOver says after a row's action or the context menu gives
    /// the view `name` a visibility (finding 12): "Feeds, hidden", "Feeds,
    /// shown always", "Feeds, shown when applicable". The pop-up says its
    /// own new value.
    static func visibilityChanged(name: String, to visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always: return String(localized: "\(name), shown always",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): \"Feeds, hidden\", \"Feeds, shown always\", \"Feeds, shown when applicable\". The pop-up says its own new value. This is the case .always. Placeholders in order: name.")
        case .whenApplicable: return String(localized: "\(name), shown when applicable",
                                     comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): \"Feeds, hidden\", \"Feeds, shown always\", \"Feeds, shown when applicable\". The pop-up says its own new value. This is the case .whenApplicable. Placeholders in order: name.")
        case .hidden: return String(localized: "\(name), hidden",
                             comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): \"Feeds, hidden\", \"Feeds, shown always\", \"Feeds, shown when applicable\". The pop-up says its own new value. This is the case .hidden. Placeholders in order: name.")
        }
    }

    /// What VoiceOver says once a view is deleted, naming the view selected
    /// now and its place (finding 13): "Deleted Mine. Feeds selected, 6 of
    /// 6."
    static func deleted(name: String, selected: String, number: Int, count: Int) -> String {
        String(localized: "Deleted \(name). \(selected) selected, \(number) of \(count).",
               comment: "Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once a view is deleted, naming the view selected now and its place (finding 13): \"Deleted Mine. Feeds selected, 6 of 6.\". Placeholders in order: name, selected, number, count.")
    }

    // MARK: - Views a Later TextMouth Wrote

    /// What the tab says of entries this TextMouth cannot read: "1 view
    /// needs a newer TextMouth. It is kept as it is, and not offered."
    static func unreadableCaption(count: Int) -> String {
        String(localized: "\(count) views need a newer TextMouth. They are kept as they are, and not offered.",
               comment: "Caption in the Library tab of Settings about views a later TextMouth wrote that this one cannot read. %lld is how many such views there are, a count.")
    }
}
