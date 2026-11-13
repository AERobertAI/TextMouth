import SwiftUI

/// The Library tab of Settings (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 7): the Library window's
/// views in order, each row one element VoiceOver reads whole, with the
/// commands for the selected view under the list: its visibility, Move Up
/// and Move Down, New View…, Edit…, Duplicate, Delete…, and Restore
/// Default…, the editor in a sheet (`LibraryViewEditorSheet`). A row's
/// VoiceOver actions and the list's context menu offer the same commands
/// (`LibraryViewsSettingsCommand`), and every change goes through the views
/// store, which config.json follows. Under them, the Titles section's Leading
/// articles pop-up (`LeadingArticlesSettingsSection`, November 13, 2026).
///
/// Like the Text tab, it does not scroll as a whole: its list fills the room
/// its other controls leave (`SettingsTab.scrollsAsAWhole`).
struct LibraryViewsSettingsView: View {
    /// The library, whose index keeps the views' sorts.
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    /// The views, the app's unless a test gives its own.
    @ObservedObject private var store: LibraryViewDefinitionStore
    /// The view the controls under the list act on.
    @State private var selection: LibraryViewID?
    /// The custom view Delete… is asking about, or nil.
    @State private var pendingDelete: LibraryViewDefinition?
    /// The built-in view Restore Default… is asking about, or nil.
    @State private var pendingRestore: LibraryViewDefinition?
    /// The editor's draft while its sheet shows, or nil.
    @State private var editor: LibraryViewEditorModel?
    /// Whether the list holds the keyboard's and VoiceOver's focus, set
    /// once a deletion's question has gone, so focus never stays on a
    /// dimmed button (review of October 31, 2026, finding 13).
    @FocusState private var listIsFocused: Bool

    /// The tab on `store`, the app's views unless a test gives its own.
    init(store: LibraryViewDefinitionStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }

    /// The wording, named once.
    private typealias Wording = LibraryViewsSettingsWording

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            list
            Divider()
            controls
                .padding()
            Divider()
            // What a title's leading article does in the Library's lists
            // (November 13, 2026), kept short so the list keeps its room.
            LeadingArticlesSettingsSection()
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .onAppear {
            if selection == nil {
                selection = store.list.views.first?.id
            }
        }
        .alert(
            pendingDelete.map { Wording.deleteTitle(name: $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(Wording.deleteButton, role: .destructive) {
                if let view = pendingDelete {
                    delete(view)
                }
            }
            Button(Wording.cancelButton, role: .cancel) {}
        } message: {
            Text(Wording.deleteMessage)
        }
        .alert(
            pendingRestore.map { Wording.restoreTitle(name: $0.name) } ?? "",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
        ) {
            Button(Wording.restoreButton) {
                if let view = pendingRestore {
                    restore(view)
                }
            }
            Button(Wording.cancelButton, role: .cancel) {}
        } message: {
            Text(Wording.restoreMessage)
        }
        .sheet(item: $editor) { model in
            LibraryViewEditorSheet(
                model: model,
                folders: folderChoices,
                count: { actions.countSentence(for: model) },
                onCancel: { editor = nil },
                onSave: { save(model) }
            )
        }
    }

    // MARK: - Parts

    /// The heading and the two captions above the list.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Wording.sectionHeader)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(Wording.orderCaption)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Wording.visibilityCaption)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The views in order, one row each, selectable, filling the room left.
    private var list: some View {
        let views = store.list.views
        return List(selection: $selection) {
            ForEach(Array(views.enumerated()), id: \.element.id) { index, view in
                row(view, number: index + 1, count: views.count)
                    .tag(view.id)
            }
        }
        .accessibilityLabel(Wording.listLabel)
        .focused($listIsFocused)
        .contextMenu(forSelectionType: LibraryViewID.self) { ids in
            if let id = ids.first, let view = store.list.view(id) {
                ForEach(actions.commands(for: view), id: \.self) { command in
                    Button(command.title) { perform(command, on: view) }
                }
            }
        } primaryAction: { ids in
            // Return or a double-click edits a filter view.
            if let id = ids.first, let view = store.list.view(id), view.kind == .filter {
                perform(.edit, on: view)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// One view's row: its name, then its kind and visibility, read as one
    /// element, "Reading List, built in, always, 5 of 6", with the view's
    /// commands as its VoiceOver actions.
    private func row(_ view: LibraryViewDefinition, number: Int, count: Int) -> some View {
        HStack {
            Text(view.name)
            Spacer()
            Text("\(view.isBuiltIn ? Wording.builtIn : Wording.custom), \(Wording.visibilityWord(view.visibility))")
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Wording.rowLabel(
            name: view.name,
            isBuiltIn: view.isBuiltIn,
            visibility: view.visibility,
            number: number,
            count: count
        ))
        .accessibilityHint(Self.rowHint(of: view, folderName: { LibraryFolderChoice.name(of: $0, among: folderChoices) }))
        .accessibilityActions {
            ForEach(actions.commands(for: view), id: \.self) { command in
                Button(command.title) { perform(command, on: view) }
            }
        }
    }

    /// The controls for the selected view.
    private var controls: some View {
        let view = selectedView
        let commands = view.map(actions.commands(for:)) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(Wording.visibilityTitle, selection: visibilityBinding) {
                    ForEach(LibraryViewVisibility.allCases, id: \.self) { visibility in
                        Text(Wording.visibilityName(visibility)).tag(visibility)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                .disabled(view == nil || view?.id == .category(.folders))
                .accessibilityLabel(Wording.visibilityLabel(name: view?.name ?? ""))
                .accessibilityHint(view?.id == .category(.folders) ? Wording.foldersVisibilityHint : Wording.visibilityHint)
                .help(view?.id == .category(.folders) ? Wording.foldersVisibilityHint : Wording.visibilityHint)

                commandButton(
                    Wording.moveUpAction,
                    label: Wording.moveUpLabel(name: view?.name ?? ""),
                    hint: commands.contains(.moveUp) ? Wording.moveUpHint : Wording.firstInListHint,
                    command: .moveUp,
                    available: commands
                )
                commandButton(
                    Wording.moveDownAction,
                    label: Wording.moveDownLabel(name: view?.name ?? ""),
                    hint: commands.contains(.moveDown) ? Wording.moveDownHint : Wording.lastInListHint,
                    command: .moveDown,
                    available: commands
                )
            }
            HStack(spacing: 12) {
                // Dimmed at the list's limit, its hint saying so (review of
                // October 31, 2026, finding 1).
                Button(LibraryViewEditorWording.newViewButton) {
                    editor = LibraryViewEditorModel()
                }
                .disabled(!store.list.canAdd)
                .accessibilityHint(store.list.canAdd ? LibraryViewEditorWording.newViewHint : Wording.viewLimit)
                .help(store.list.canAdd ? LibraryViewEditorWording.newViewHint : Wording.viewLimit)
                commandButton(
                    LibraryViewEditorWording.editButton,
                    label: LibraryViewEditorWording.editButton,
                    hint: commands.contains(.edit) ? LibraryViewEditorWording.editHint : LibraryViewEditorWording.editDisabledHint,
                    command: .edit,
                    available: commands
                )
                commandButton(
                    Wording.duplicateAction,
                    label: Wording.duplicateAction,
                    hint: Self.duplicateHint(of: view, available: commands.contains(.duplicate), canAdd: store.list.canAdd),
                    command: .duplicate,
                    available: commands
                )
                commandButton(
                    Wording.deleteAction,
                    label: Wording.deleteAction,
                    hint: commands.contains(.delete) ? Wording.deleteHint : Wording.deleteBuiltInHint,
                    command: .delete,
                    available: commands
                )
                commandButton(
                    Wording.restoreAction,
                    label: Wording.restoreAction,
                    hint: Self.restoreHint(of: view, available: commands.contains(.restoreDefault)),
                    command: .restoreDefault,
                    available: commands
                )
            }
            if store.list.unreadableCount > 0 {
                Text(Wording.unreadableCaption(count: store.list.unreadableCount))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A button under the list for `command`, dimmed while it does not apply
    /// to the selected view, its hint saying why then.
    private func commandButton(
        _ title: String,
        label: String,
        hint: String,
        command: LibraryViewsSettingsCommand,
        available: [LibraryViewsSettingsCommand]
    ) -> some View {
        Button(title) {
            if let view = selectedView {
                perform(command, on: view)
            }
        }
        .disabled(!available.contains(command))
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .help(hint)
    }

    // MARK: - State

    /// What the commands do, on this tab's store and library.
    private var actions: LibraryViewsSettingsActions {
        LibraryViewsSettingsActions(store: store, library: libraryViewModel)
    }

    /// The selected view, if it is still in the list.
    private var selectedView: LibraryViewDefinition? {
        selection.flatMap { store.list.view($0) }
    }

    /// The Visibility pop-up's value: the selected view's visibility, set
    /// through the store.
    private var visibilityBinding: Binding<LibraryViewVisibility> {
        Binding(
            get: { selectedView?.visibility ?? .always },
            set: { visibility in
                if let view = selectedView {
                    actions.setVisibility(visibility, of: view)
                }
            }
        )
    }

    /// The folders a Folder condition can name, in tree order.
    private var folderChoices: [LibraryFolderChoice] {
        LibraryFolderChoice.choices(in: libraryViewModel.library)
    }

    /// The row hint of `view`: what Folders and the Reading List show, and
    /// a filter view's filter described, its folders named by `folderName`
    /// (`LibraryViewEditorWording.description(of:folderName:)`).
    static func rowHint(of view: LibraryViewDefinition, folderName: (UUID?) -> String) -> String {
        switch view.kind {
        case .folders: return LibraryViewsSettingsWording.foldersHint
        case .readingList: return LibraryViewsSettingsWording.readingListHint
        case .filter:
            return view.filter.map { LibraryViewEditorWording.description(of: $0, folderName: folderName) } ?? ""
        }
    }

    /// Saves the editor's draft: a problem stays on the sheet and is said; a
    /// saved view is selected, and said once the sheet has closed.
    private func save(_ model: LibraryViewEditorModel) {
        switch actions.save(model) {
        case .problem(let problem):
            model.problem = problem
            VoiceOverAnnouncer.announce(problem)
        case .saved(let id, let announcement):
            editor = nil
            selection = id
            VoiceOverAnnouncer.announceAfterSheetCloses(announcement, from: nil)
        }
    }

    /// Restore Default…'s hint for `view`: what it does when it applies,
    /// otherwise why it is dimmed.
    static func restoreHint(of view: LibraryViewDefinition?, available: Bool) -> String {
        if available {
            return LibraryViewsSettingsWording.restoreHint
        }
        guard let view, view.isBuiltIn else { return LibraryViewsSettingsWording.restoreCustomHint }
        return LibraryViewsSettingsWording.restoreUnchangedHint
    }

    /// Duplicate's hint for `view`: what it does when it applies, or why
    /// it is dimmed: Folders and the Reading List have no conditions, and a
    /// full list has no room (review of October 31, 2026, finding 1).
    static func duplicateHint(of view: LibraryViewDefinition?, available: Bool, canAdd: Bool) -> String {
        if available {
            return LibraryViewsSettingsWording.duplicateHint
        }
        if view?.kind == .filter, !canAdd {
            return LibraryViewsSettingsWording.viewLimit
        }
        return LibraryViewsSettingsWording.duplicateUnavailableHint
    }

    // MARK: - Commands

    /// Runs `command` on `view`: moves and visibilities at once, the others
    /// through their questions or their own steps.
    private func perform(_ command: LibraryViewsSettingsCommand, on view: LibraryViewDefinition) {
        selection = view.id
        switch command {
        case .edit:
            editor = LibraryViewEditorModel(editing: view, sort: actions.shownSortSetting(of: view))
        case .moveUp, .moveDown:
            if let announcement = actions.move(view, by: command == .moveUp ? -1 : 1) {
                VoiceOverAnnouncer.announce(announcement)
            }
        case .show(let visibility):
            // A row's action and the context menu say nothing themselves
            // (review of October 31, 2026, finding 12).
            if let announcement = actions.setVisibilitySaying(visibility, of: view) {
                VoiceOverAnnouncer.announce(announcement)
            }
        case .duplicate:
            if let made = actions.duplicate(view) {
                selection = made.id
                VoiceOverAnnouncer.announce(made.announcement)
            }
        case .delete:
            pendingDelete = view
        case .restoreDefault:
            // When another view has the shipped name, say so at once and
            // ask nothing (review of October 31, 2026, finding 5).
            if let shipped = LibraryViewDefinition.shipped(view.id), store.list.isNameTaken(shipped.name, except: view.id) {
                VoiceOverAnnouncer.announce(Wording.restoreNameTaken(name: shipped.name))
            } else {
                pendingRestore = view
            }
        }
    }

    /// Deletes `view` once its question is answered, selects its neighbour,
    /// and, once the question has gone, puts focus on the list and says
    /// which view is selected now (review of October 31, 2026, finding 13).
    private func delete(_ view: LibraryViewDefinition) {
        pendingDelete = nil
        guard let deleted = actions.delete(view) else { return }
        selection = deleted.nextSelection
        VoiceOverAnnouncer.afterSheetCloses {
            listIsFocused = true
            VoiceOverAnnouncer.announce(deleted.announcement)
        }
    }

    /// Restores `view` once its question is answered, and says so once the
    /// question has gone.
    private func restore(_ view: LibraryViewDefinition) {
        pendingRestore = nil
        guard let announcement = actions.restoreDefault(view) else { return }
        VoiceOverAnnouncer.announceAfterSheetCloses(announcement, from: nil)
    }
}
