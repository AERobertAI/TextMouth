import Foundation

// MARK: - The Commands of One View

/// A command of the Library tab for one view (design section 7). A row's
/// VoiceOver actions, the list's context menu, and the buttons under the
/// list all ask `available(for:in:sortIsSaved:)`, so the three never offer
/// different commands.
enum LibraryViewsSettingsCommand: Hashable {
    /// Opens the editor on a filter view.
    case edit
    /// Moves the view one place up the list.
    case moveUp
    /// Moves the view one place down the list.
    case moveDown
    /// Gives the view a visibility.
    case show(LibraryViewVisibility)
    /// Makes a custom copy of a filter view.
    case duplicate
    /// Deletes a custom view, asking first.
    case delete
    /// Gives a built-in filter view back its own name, filter, and sort,
    /// asking first.
    case restoreDefault

    /// The commands that apply to `view` in `list` now, in the order the
    /// menu offers them: Edit… for a filter view, the moves it can make, the
    /// visibilities it does not
    /// have (none for Folders, which is always offered), Duplicate for a
    /// filter view, Delete… for a custom one, and Restore Default… for a
    /// built-in filter view that differs from TextMouth's own, or whose sort
    /// is saved (`sortIsSaved`).
    static func available(
        for view: LibraryViewDefinition,
        in list: LibraryViewDefinitionList,
        sortIsSaved: Bool
    ) -> [LibraryViewsSettingsCommand] {
        var commands: [LibraryViewsSettingsCommand] = []
        if view.kind == .filter {
            commands.append(.edit)
        }
        if let place = list.place(of: view.id) {
            if place.number > 1 { commands.append(.moveUp) }
            if place.number < place.count { commands.append(.moveDown) }
        }
        if view.id != .category(.folders) {
            commands += LibraryViewVisibility.allCases.filter { $0 != view.visibility }.map { LibraryViewsSettingsCommand.show($0) }
        }
        if view.kind == .filter {
            commands.append(.duplicate)
        }
        if !view.isBuiltIn {
            commands.append(.delete)
        }
        if canRestore(view, sortIsSaved: sortIsSaved) {
            commands.append(.restoreDefault)
        }
        return commands
    }

    /// Whether Restore Default applies to `view`: a built-in filter view
    /// that differs from TextMouth's own, or has a sort saved.
    static func canRestore(_ view: LibraryViewDefinition, sortIsSaved: Bool) -> Bool {
        view.isBuiltIn && view.kind == .filter && (view.differsFromShipped || sortIsSaved)
    }

    /// The command's name, as a VoiceOver action and a menu item.
    var title: String {
        switch self {
        case .edit: return LibraryViewEditorWording.editButton
        case .moveUp: return LibraryViewsSettingsWording.moveUpAction
        case .moveDown: return LibraryViewsSettingsWording.moveDownAction
        case .show(let visibility): return LibraryViewsSettingsWording.showAction(visibility)
        case .duplicate: return LibraryViewsSettingsWording.duplicateAction
        case .delete: return LibraryViewsSettingsWording.deleteAction
        case .restoreDefault: return LibraryViewsSettingsWording.restoreAction
        }
    }
}

// MARK: - What the Commands Do

/// What the Library tab's commands do to the views and to their sorts: the
/// views through the store, the sorts in the library's index, where every
/// view's sort is saved (design section 8). Each returns what VoiceOver
/// says after it, or nil when nothing changed. The tab calls these; the
/// tests call them with a store and a library of their own.
@MainActor
struct LibraryViewsSettingsActions {
    /// The views.
    let store: LibraryViewDefinitionStore
    /// The library, whose index keeps the views' sorts.
    let library: LibraryViewModel

    /// Whether a sort is saved for `view`, which Restore Default removes.
    func sortIsSaved(for view: LibraryViewDefinition) -> Bool {
        guard let key = view.sortSettingsKey else { return false }
        return library.library.folderSortSettings[key] != nil
    }

    /// The sort `view` shows, as the Library window restores it, by the one
    /// function every window and list loads a sort with
    /// (`LibraryViewModel.sortState(at:)`), with its rules, such as
    /// Unopened's sort carried over from No Folder.
    func shownSortSetting(of view: LibraryViewDefinition) -> FolderSortSetting {
        library.sortState(at: LibraryLocation(view: view, folderPath: "")).setting
    }

    /// The commands that apply to `view` now.
    func commands(for view: LibraryViewDefinition) -> [LibraryViewsSettingsCommand] {
        LibraryViewsSettingsCommand.available(for: view, in: store.list, sortIsSaved: sortIsSaved(for: view))
    }

    /// Moves `view` one place up (-1) or down (+1), returning its new place
    /// to announce, "Reading List, 4 of 6".
    func move(_ view: LibraryViewDefinition, by offset: Int) -> String? {
        guard store.update({ $0.move(view.id, by: offset) }), let place = store.list.place(of: view.id) else { return nil }
        return LibraryViewsSettingsWording.placeAnnouncement(name: view.name, number: place.number, count: place.count)
    }

    /// Gives `view` `visibility`. Returns whether it changed; the pop-up or
    /// the action's name says the rest.
    @discardableResult
    func setVisibility(_ visibility: LibraryViewVisibility, of view: LibraryViewDefinition) -> Bool {
        store.update { $0.setVisibility(visibility, of: view.id) }
    }

    /// Makes a custom copy of the filter view `view` right after it, always
    /// offered, with its filter and the sort it shows saved under the copy's
    /// key. Returns the copy's identity, to select it, and what to announce.
    func duplicate(_ view: LibraryViewDefinition) -> (id: LibraryViewID, announcement: String)? {
        guard view.kind == .filter, let filter = view.filter else { return nil }
        let copy = LibraryViewDefinition(
            id: .custom(UUID()),
            name: store.list.copyName(for: view.name),
            visibility: .always,
            filter: filter
        )
        guard store.update({ $0.add(copy, after: view.id) }) else { return nil }
        if let key = copy.sortSettingsKey {
            library.setFolderSortSetting(shownSortSetting(of: view), for: key)
        }
        guard let place = store.list.place(of: copy.id) else { return nil }
        return (copy.id, LibraryViewsSettingsWording.duplicated(name: copy.name, number: place.number, count: place.count))
    }

    /// Deletes the custom view `view` and the sort saved for it. Returns the
    /// view to select next, the one after it or else the one before, and
    /// what to announce.
    func delete(_ view: LibraryViewDefinition) -> (nextSelection: LibraryViewID?, announcement: String)? {
        let before = store.list.views
        guard let index = before.firstIndex(where: { $0.id == view.id }),
              store.update({ $0.delete(view.id) }) else {
            return nil
        }
        if let key = view.sortSettingsKey {
            library.removeSortSetting(for: key)
        }
        let after = store.list.views
        let next = after.indices.contains(index) ? after[index].id : after.last?.id
        return (next, LibraryViewsSettingsWording.deleted(name: view.name))
    }

    /// What Save in the editor did: found a problem, which the sheet shows
    /// and VoiceOver says, keeping it open; or saved the view, to select it,
    /// and what to say once the sheet has closed.
    enum SaveOutcome: Equatable {
        /// The draft has this problem; nothing was saved.
        case problem(String)
        /// The view was saved.
        case saved(id: LibraryViewID, announcement: String)
    }

    /// Saves the editor's draft (design section 7): when it has a problem,
    /// says which; otherwise adds the view at the end, or puts it in its
    /// place, and saves its sort under its key when the draft's differs
    /// from the sort the view shows.
    func save(_ model: LibraryViewEditorModel) -> SaveOutcome {
        if let problem = model.firstProblem(in: store.list) {
            return .problem(problem)
        }
        let view = model.definition()
        let isNew = model.original == nil
        let shown = shownSortSetting(of: view)
        store.update { list -> Bool in
            isNew ? list.add(view, after: nil) : list.replace(view)
        }
        let chosen = model.sortSetting(from: shown)
        if chosen != shown, let key = view.sortSettingsKey {
            library.setFolderSortSetting(chosen, for: key)
        }
        guard isNew, let place = store.list.place(of: view.id) else {
            return .saved(id: view.id, announcement: LibraryViewEditorWording.saved(view.name))
        }
        return .saved(id: view.id, announcement: LibraryViewEditorWording.added(view.name, number: place.number, count: place.count))
    }

    /// Gives the built-in filter view `view` back its own name and filter,
    /// and removes the sort saved for it. Returns what to announce, naming
    /// the view by its restored name.
    func restoreDefault(_ view: LibraryViewDefinition) -> String? {
        guard LibraryViewsSettingsCommand.canRestore(view, sortIsSaved: sortIsSaved(for: view)) else { return nil }
        store.update { $0.restoreDefault(view.id) }
        if let key = view.sortSettingsKey {
            library.removeSortSetting(for: key)
        }
        let name = store.list.view(view.id)?.name ?? view.name
        return LibraryViewsSettingsWording.restored(name: name)
    }
}
