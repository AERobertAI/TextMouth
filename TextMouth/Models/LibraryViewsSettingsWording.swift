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
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The tab's name in the Settings window's toolbar.
        String(localized: "Library")
    }
    /// The heading above the list.
    static var sectionHeader: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The heading above the list.
        String(localized: "Views")
    }
    /// What the list is, and where a new window opens.
    static var orderCaption: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the list is, and where a new window opens.
        String(localized: "The View pop-up of a Library window offers these views in this order. A new window opens at the first one offered.")
    }
    /// What the three visibilities do, and that a window keeps its view.
    static var visibilityCaption: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the three visibilities do, and that a window keeps its view.
        String(localized: "Always offers a view all the time. When Applicable offers it only while it lists something: the Reading List while it holds a book, episode, or article, and Feeds while there is a feed. Hidden leaves it out. A window keeps its view until you choose another.")
    }

    // MARK: - The List

    /// What VoiceOver calls the list.
    static var listLabel: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver calls the list.
        String(localized: "Views")
    }

    /// A view's row as VoiceOver reads it and a braille display shows it, in
    /// one element: "Reading List, built in, always, 5 of 6".
    static func rowLabel(name: String, isBuiltIn: Bool, visibility: LibraryViewVisibility, number: Int, count: Int) -> String {
        // The row's two words, localized on their own and joined by commas as the row has always been.
        let origin = isBuiltIn ? builtIn : custom
        let visibilityText = visibilityWord(visibility)
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A view's row as VoiceOver reads it and a braille display shows it, in one element: "Reading List, built in, always, 5 of 6". %1$@ is the view's name, %2$@ is the word built in or custom, %3$@ is its visibility in lower case (always, when applicable, hidden), %4$lld is its place in the list and %5$lld the number of views.
        return String(localized: "\(name), \(origin), \(visibilityText), \(number) of \(count)")
    }

    /// The row's word for a view TextMouth made.
    static var builtIn: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The row's word for a view TextMouth made.
        String(localized: "built in")
    }
    /// The row's word for a view the listener made.
    static var custom: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The row's word for a view the listener made.
        String(localized: "custom")
    }

    /// A visibility as the row says it, in a sentence: "always", "when
    /// applicable", or "hidden".
    static func visibilityWord(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        case .always:
            // Translators: A Library view's visibility in lower case, inside a row's spoken label: the View pop-up always offers the view.
            return String(localized: "always")
        case .whenApplicable:
            // Translators: A Library view's visibility in lower case, inside a row's spoken label: the View pop-up offers the view only while it lists something.
            return String(localized: "when applicable")
        case .hidden:
            // Translators: A Library view's visibility in lower case, inside a row's spoken label: the View pop-up does not offer the view.
            return String(localized: "hidden")
        }
    }

    /// A visibility as the Visibility pop-up names it: "Always", "When
    /// Applicable", or "Hidden".
    static func visibilityName(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: "Always", "When Applicable", or "Hidden". This is the case .always.
        case .always: return String(localized: "Always")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: "Always", "When Applicable", or "Hidden". This is the case .whenApplicable.
        case .whenApplicable: return String(localized: "When Applicable")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). A visibility as the Visibility pop-up names it: "Always", "When Applicable", or "Hidden". This is the case .hidden.
        case .hidden: return String(localized: "Hidden")
        }
    }

    /// Folders' row hint: what it shows.
    static var foldersHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Folders' row hint: what it shows.
        String(localized: "Shows one folder at a time")
    }
    /// The Reading List's row hint: what it shows.
    static var readingListHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Reading List's row hint: what it shows.
        String(localized: "Shows the books in the order you arrange")
    }

    // MARK: - Commands

    /// The command that moves a view one place up, as a VoiceOver action
    /// and a context menu item.
    static var moveUpAction: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that moves a view one place up, as a VoiceOver action and a context menu item.
        String(localized: "Move Up")
    }
    /// The command that moves a view one place down.
    static var moveDownAction: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that moves a view one place down.
        String(localized: "Move Down")
    }
    /// The command that gives a view `visibility`: "Show Always", "Show When
    /// Applicable", or "Hide".
    static func showAction(_ visibility: LibraryViewVisibility) -> String {
        switch visibility {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: "Show Always", "Show When Applicable", or "Hide". This is the case .always.
        case .always: return String(localized: "Show Always")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: "Show Always", "Show When Applicable", or "Hide". This is the case .whenApplicable.
        case .whenApplicable: return String(localized: "Show When Applicable")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a view visibility: "Show Always", "Show When Applicable", or "Hide". This is the case .hidden.
        case .hidden: return String(localized: "Hide")
        }
    }
    /// The command that makes a custom copy of a view.
    static var duplicateAction: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that makes a custom copy of a view.
        String(localized: "Duplicate")
    }
    /// The command that deletes a custom view, asking first.
    static var deleteAction: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that deletes a custom view, asking first.
        String(localized: "Delete…")
    }
    /// The command that gives a built-in view back its own, asking first.
    static var restoreAction: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The command that gives a built-in view back its own, asking first.
        String(localized: "Restore Default…")
    }

    // MARK: - Visibility

    /// The Visibility pop-up's visible label.
    static var visibilityTitle: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's visible label.
        String(localized: "Visibility")
    }
    /// The Visibility pop-up's spoken label, naming the view it sets.
    static func visibilityLabel(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's spoken label, naming the view it sets. Placeholders in order: name.
        String(localized: "Visibility of \(name)")
    }
    /// The Visibility pop-up's hint.
    static var visibilityHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's hint.
        String(localized: "Sets when the View pop-up offers this view")
    }
    /// The Visibility pop-up's hint for Folders, whose visibility is fixed.
    static var foldersVisibilityHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Visibility pop-up's hint for Folders, whose visibility is fixed.
        String(localized: "Folders is always shown: every folder and feed opens there.")
    }

    // MARK: - Moving

    /// The Move Up button's spoken label, naming the view it moves.
    static func moveUpLabel(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Up button's spoken label, naming the view it moves. Placeholders in order: name.
        String(localized: "Move \(name) Up")
    }
    /// The Move Down button's spoken label.
    static func moveDownLabel(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Down button's spoken label. Placeholders in order: name.
        String(localized: "Move \(name) Down")
    }
    /// The Move Up button's hint.
    static var moveUpHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Up button's hint.
        String(localized: "Moves it one place up")
    }
    /// The Move Down button's hint.
    static var moveDownHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The Move Down button's hint.
        String(localized: "Moves it one place down")
    }
    /// Move Up's hint while the view is first, when it is dimmed.
    static var firstInListHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Move Up's hint while the view is first, when it is dimmed.
        String(localized: "The view is first in the list.")
    }
    /// Move Down's hint while the view is last, when it is dimmed.
    static var lastInListHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Move Down's hint while the view is last, when it is dimmed.
        String(localized: "The view is last in the list.")
    }
    /// What VoiceOver says after a move: the view and its new place,
    /// "Reading List, 4 of 6", short enough to hear after each of many
    /// moves.
    static func placeAnnouncement(name: String, number: Int, count: Int) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a move: the view and its new place, "Reading List, 4 of 6", short enough to hear after each of many moves. Placeholders in order: name, number, count.
        String(localized: "\(name), \(number) of \(count)")
    }

    // MARK: - Duplicate

    /// Duplicate's hint.
    static var duplicateHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Duplicate's hint.
        String(localized: "Makes your own view with these conditions and sort.")
    }
    /// Duplicate's hint for Folders and the Reading List, when it is dimmed.
    static var duplicateUnavailableHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Duplicate's hint for Folders and the Reading List, when it is dimmed.
        String(localized: "Folders and the Reading List have no conditions to copy.")
    }
    /// What VoiceOver says after Duplicate: the copy and its place.
    static func duplicated(name: String, number: Int, count: Int) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after Duplicate: the copy and its place. Placeholders in order: name, number, count.
        String(localized: "Made \(name), \(number) of \(count).")
    }

    // MARK: - Delete

    /// Delete…'s hint.
    static var deleteHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Delete…'s hint.
        String(localized: "Deletes the view. What it lists stays in the library.")
    }
    /// Delete…'s hint for a built-in view, when it is dimmed.
    static var deleteBuiltInHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Delete…'s hint for a built-in view, when it is dimmed.
        String(localized: "A built-in view can be hidden, not deleted.")
    }
    /// The question Delete… asks.
    static func deleteTitle(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question Delete… asks. Placeholders in order: name.
        String(localized: "Delete the view “\(name)”?")
    }
    /// What the question says Delete does, and what it keeps.
    static var deleteMessage: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the question says Delete does, and what it keeps.
        String(localized: "Its conditions and sort are deleted. The books, episodes, articles, and feeds it lists stay in the library, and a Library window showing it shows another view.")
    }
    /// The question's button that deletes.
    static var deleteButton: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question's button that deletes.
        String(localized: "Delete")
    }
    /// The button of either question that changes nothing.
    static var cancelButton: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The button of either question that changes nothing.
        String(localized: "Cancel")
    }
    /// What VoiceOver says once the view is deleted.
    static func deleted(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once the view is deleted. Placeholders in order: name.
        String(localized: "Deleted \(name).")
    }

    // MARK: - Restore Default

    /// Restore Default…'s hint.
    static var restoreHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint.
        String(localized: "Gives the view back the name, conditions, sort, and limit TextMouth gave it.")
    }
    /// Restore Default…'s hint for a built-in view as TextMouth made it, or
    /// Folders or the Reading List, when it is dimmed.
    static var restoreUnchangedHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint for a built-in view as TextMouth made it, or Folders or the Reading List, when it is dimmed.
        String(localized: "This view is as TextMouth made it.")
    }
    /// Restore Default…'s hint for a view the listener made, when it is
    /// dimmed.
    static var restoreCustomHint: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). Restore Default…'s hint for a view the listener made, when it is dimmed.
        String(localized: "A view you made has no default to restore.")
    }
    /// The question Restore Default… asks.
    static func restoreTitle(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question Restore Default… asks. Placeholders in order: name.
        String(localized: "Restore “\(name)” to its default?")
    }
    /// What the question says Restore Default does, and what it keeps.
    static var restoreMessage: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What the question says Restore Default does, and what it keeps.
        String(localized: "Its name, conditions, sort, and limit go back to TextMouth's own. Its place in the list and when it is offered stay as they are.")
    }
    /// The question's button that restores.
    static var restoreButton: String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). The question's button that restores.
        String(localized: "Restore Default")
    }
    /// What VoiceOver says once the view is restored, by its restored name.
    static func restored(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once the view is restored, by its restored name. Placeholders in order: name.
        String(localized: "Restored \(name).")
    }

    // MARK: - Added October 31, 2026 (the review of team/views)

    /// New View… and Duplicate's hint at the limit, when they are dimmed,
    /// and Save's problem there (finding 1).
    static var viewLimit: String {
        // Translators: Hint of New View and Duplicate in the Library tab of Settings when the limit is reached, and the problem Save reports there. %lld is the most views the Library holds, a count.
        String(localized: "The Library holds at most \(LibraryViewDefinitionList.entryLimit) views.")
    }

    /// What Restore Default says, changing nothing, when another view has
    /// the shipped name `name` (finding 5).
    static func restoreNameTaken(name: String) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What Restore Default says, changing nothing, when another view has the shipped name name (finding 5). Placeholders in order: name.
        String(localized: "Another view is named \(name). Rename it first, then restore this view.")
    }

    /// What VoiceOver says after a row's action or the context menu gives
    /// the view `name` a visibility (finding 12): "Feeds, hidden", "Feeds,
    /// shown always", "Feeds, shown when applicable". The pop-up says its
    /// own new value.
    static func visibilityChanged(name: String, to visibility: LibraryViewVisibility) -> String {
        switch visibility {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): "Feeds, hidden", "Feeds, shown always", "Feeds, shown when applicable". The pop-up says its own new value. This is the case .always. Placeholders in order: name.
        case .always: return String(localized: "\(name), shown always")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): "Feeds, hidden", "Feeds, shown always", "Feeds, shown when applicable". The pop-up says its own new value. This is the case .whenApplicable. Placeholders in order: name.
        case .whenApplicable: return String(localized: "\(name), shown when applicable")
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says after a row's action or the context menu gives the view name a visibility (finding 12): "Feeds, hidden", "Feeds, shown always", "Feeds, shown when applicable". The pop-up says its own new value. This is the case .hidden. Placeholders in order: name.
        case .hidden: return String(localized: "\(name), hidden")
        }
    }

    /// What VoiceOver says once a view is deleted, naming the view selected
    /// now and its place (finding 13): "Deleted Mine. Feeds selected, 6 of
    /// 6."
    static func deleted(name: String, selected: String, number: Int, count: Int) -> String {
        // Translators: Text of the Library tab of Settings, a list of the views the Library window offers (built-in views and the listener's own). What VoiceOver says once a view is deleted, naming the view selected now and its place (finding 13): "Deleted Mine. Feeds selected, 6 of 6.". Placeholders in order: name, selected, number, count.
        String(localized: "Deleted \(name). \(selected) selected, \(number) of \(count).")
    }

    // MARK: - Views a Later TextMouth Wrote

    /// What the tab says of entries this TextMouth cannot read: "1 view
    /// needs a newer TextMouth. It is kept as it is, and not offered."
    static func unreadableCaption(count: Int) -> String {
        // Translators: Caption in the Library tab of Settings about views a later TextMouth wrote that this one cannot read. %lld is how many such views there are, a count.
        String(localized: "\(count) views need a newer TextMouth. They are kept as they are, and not offered.")
    }
}
