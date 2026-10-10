import SwiftUI

// MARK: - Book Info Sheet

/// Book info editor accessible from the library context menu, and the
/// reader's Book Info for a book without the metadata editor.
struct LibraryBookInfoSheet: View {
    let book: Book
    let libraryViewModel: LibraryViewModel
    @State private var title: String
    @State private var author: String
    /// The title and author the sheet opened with, as Save stores them
    /// (`values(title:author:)`), kept for as long as it is open: Save
    /// compares what is typed with them (`Book.MetadataEdit`), so only what
    /// the user changed here is saved and recorded as edited by hand. The
    /// book shown may change meanwhile, since a reader's sheet shows the
    /// reader's copy, which takes every change the library makes; this does
    /// not.
    @State private var opened: Book.MetadataValues
    @Environment(\.dismiss) private var dismiss

    init(book: Book, libraryViewModel: LibraryViewModel) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self._title = State(initialValue: book.title)
        self._author = State(initialValue: book.author)
        self._opened = State(initialValue: Self.values(title: book.title, author: book.author))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Book Information")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                // Each label says "edited by hand" when the user typed the
                // value (`Book.handEdits`).
                TextField("Title", text: $title)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel("Book title", for: .title, in: book.handEdits))
                TextField("Author", text: $author)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel("Book author", for: .author, in: book.handEdits))

                LabeledContent("Format") {
                    Text(book.format.displayName)
                }
                LabeledContent("Added") {
                    Text(book.dateAdded, style: .date)
                }
                if let lastOpened = book.lastOpened {
                    LabeledContent("Last Opened") {
                        Text(lastOpened, style: .date)
                    }
                }
                if let words = book.totalWordCount {
                    LabeledContent("Word Count") {
                        Text("\(words)")
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    // Capture state before dismissing
                    guard let edit = Self.edit(from: opened, title: title, author: author) else { return }
                    let vm = libraryViewModel
                    let bookID = book.id

                    // Dismiss first so shared state updates don't steal focus
                    dismiss()

                    DispatchQueue.main.async {
                        // Saves what the user changed here, and only that,
                        // to the row as it is by then.
                        vm.updateBookMetadata(edit, of: bookID)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(Self.edit(from: opened, title: title, author: author) == nil)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .navigationTitle("Info: \(book.title)")
    }

    /// `title` and `author` as Save stores them: each less the spaces
    /// around it.
    nonisolated static func values(title: String, author: String) -> Book.MetadataValues {
        [
            .title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            .author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
    }

    /// What Save gives the library for the `title` and `author` typed in a
    /// sheet that opened with `opened` (`values(title:author:)`): what was
    /// typed, less the spaces around it, beside what the sheet opened with;
    /// or nil when the title is blank: a book keeps a title, since the
    /// library shows and sorts it by that, so Save is unavailable until one
    /// is typed. A title whose only change is the spaces Save trims, as one
    /// taken from a file named "Notes .txt" has, is no change, since what
    /// the sheet opened with is trimmed the same way.
    nonisolated static func edit(from opened: Book.MetadataValues, title: String, author: String) -> Book.MetadataEdit? {
        let saved = values(title: title, author: author)
        guard let savedTitle = saved[.title], !savedTitle.isEmpty else { return nil }
        return Book.MetadataEdit(opened: opened, saved: saved)
    }
}

// MARK: - Operation Failure Notice

/// Why the operation a sheet started failed, shown inside the sheet (TODO
/// A07). A sheet whose operation fails stays open with the user's input, so
/// the reason sits beside the controls that can put it right. VoiceOver
/// reads the notice as text labelled as an error, where the red color tells
/// sighted users the same, and the failure is announced once as it happens,
/// from the sheet, which keeps focus.
struct OperationFailureNotice: View {
    /// The failure to show, or nil to show nothing.
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.callout)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Self.accessibilityLabel(for: message))
        }
    }

    /// What VoiceOver reads for a failure: the message, introduced as an
    /// error.
    nonisolated static func accessibilityLabel(for message: String) -> String {
        "Error: \(message)"
    }

    /// The message a sheet shows after `outcome`: nil after a success, when
    /// the sheet is closing, or else the reason, which VoiceOver is asked to
    /// speak once so the user hears it without leaving the control they used.
    static func message(after outcome: OperationOutcome) -> String? {
        guard let failure = outcome.failureMessage else { return nil }
        VoiceOverAnnouncer.announce(failure)
        return failure
    }

    /// Starts `operation`, a sheet's edit that moves books and can take a
    /// while (PERF14), and keeps the sheet's state while it runs:
    /// `failureMessage` is cleared as it starts, so a retry of the same
    /// input never shows the attempt before's reason beside the work
    /// indicator; `isWorking` is true until it is done, which shows
    /// `SheetWorkIndicator` and keeps the sheet's buttons disabled, so the
    /// edit cannot start twice nor the sheet close halfway; then
    /// `failureMessage` holds what `message(after:)` gives. The owner closes
    /// the sheet after a success, as it does for an edit that finishes at
    /// once.
    static func run(
        _ operation: @escaping @MainActor () async -> OperationOutcome,
        isWorking: Binding<Bool>,
        failureMessage: Binding<String?>
    ) {
        // The last failure was about the attempt before; a reason that
        // stayed would read as this attempt's until it ends.
        failureMessage.wrappedValue = nil
        isWorking.wrappedValue = true
        Task { @MainActor in
            let outcome = await operation()
            failureMessage.wrappedValue = message(after: outcome)
            isWorking.wrappedValue = false
        }
    }
}

/// What a sheet shows while its edit runs (PERF14): a small spinner beside
/// `label`, such as "Moving books...", read by VoiceOver as one element, so
/// whoever looks or listens finds the sheet working rather than stuck.
struct SheetWorkIndicator: View {
    /// What the sheet is doing.
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Clears a sheet's failure message as soon as the user changes `value`,
    /// an input the failure was about, so a reason that no longer applies is
    /// never read beside new input.
    func clearingFailure<Value: Equatable>(
        _ message: Binding<String?>,
        whenChanged value: Value
    ) -> some View {
        onChange(of: value) { _, _ in
            message.wrappedValue = nil
        }
    }
}

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var parentPath: String
    let folders: [BookFolder]
    /// Creates the folder and returns what happened. The owner closes the
    /// sheet after a success; after a failure the sheet stays open with the
    /// name and parent the user chose, and shows why.
    let onCreate: () -> OperationOutcome
    let onCancel: () -> Void

    /// Why the last Create failed, until the user changes the name or parent.
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder name")

            Picker("Parent folder", selection: $parentPath) {
                Text("Library Root").tag("")
                ForEach(folders.sortedTreeOrder()) { folder in
                    if folder.depth < BookFolder.maxDepth {
                        Text(folder.fullPath).tag(folder.fullPath)
                    }
                }
            }
            .accessibilityLabel("Parent folder")

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Create") {
                    failureMessage = OperationFailureNotice.message(after: onCreate())
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(BookFolder.normalizedName(folderName) == nil)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("New Folder")
        .clearingFailure($failureMessage, whenChanged: folderName)
        .clearingFailure($failureMessage, whenChanged: parentPath)
    }
}

// MARK: - Library Folder Picker

/// One place a folder picker offers: what it shows and VoiceOver reads, and
/// the folder's path, "" for the library's top level.
struct LibraryFolderOption: Hashable {
    /// The words shown: "Library Root", or the folder's full path.
    let label: String
    /// The folder's path; "" for the library's top level.
    let path: String

    /// What the library's top level is called in every folder picker.
    static let rootLabel = "Library Root"

    /// "Library Root", when `includingRoot`, then every folder of `library`
    /// in tree order that `includes` accepts.
    static func options(
        in library: Library,
        includingRoot: Bool = true,
        where includes: (BookFolder) -> Bool = { _ in true }
    ) -> [LibraryFolderOption] {
        let root = includingRoot ? [LibraryFolderOption(label: rootLabel, path: "")] : []
        return root + library.folders.sortedTreeOrder().filter(includes).map {
            LibraryFolderOption(label: $0.fullPath, path: $0.fullPath)
        }
    }
}

/// The folder chooser of the Move dialog, which Add Feed uses as well: a
/// pop-up of the places offered, a New Folder... button, and, once that is
/// pressed, the fields that make a new folder, which then becomes the place
/// chosen; the name field takes the keyboard as the fields open, so a
/// VoiceOver user lands where they type. A folder that can't be made keeps
/// the fields open with the name, and the owner's failure notice says why.
/// While the fields are shown, Return presses their Create; an owner with a
/// Return-key button of its own withdraws that shortcut meanwhile,
/// following `isMakingFolder`, so one press does one thing.
struct LibraryFolderPicker: View {
    /// The places the pop-up offers.
    let options: [LibraryFolderOption]
    /// The folders a new folder may be made in.
    let newFolderParents: [LibraryFolderOption]
    /// The path of the place chosen.
    @Binding var selection: String
    /// The pop-up's visible caption.
    let caption: String
    /// The pop-up's spoken label.
    let accessibilityLabel: String
    /// Makes a folder from a name and a parent path and returns what
    /// happened.
    let onCreateFolder: (String, String) -> OperationOutcome
    /// Why the last folder could not be made, which the owner shows; a new
    /// name or parent clears it.
    @Binding var failureMessage: String?
    /// Whether the controls are unavailable, as while the owner works.
    let isDisabled: Bool
    /// Where the owner follows whether the new-folder fields are showing,
    /// kept current by the picker, so a Return-key button of the owner's
    /// can stand down while they are; its first value says whether the
    /// fields start shown. Nil for an owner with no such button.
    let isMakingFolder: Binding<Bool>?

    /// Whether the new-folder fields are showing.
    @State private var showNewFolder: Bool
    /// The name typed for the new folder.
    @State private var newFolderName = ""
    /// The parent chosen for the new folder.
    @State private var newFolderParent = ""
    /// Whether the new folder's name field has the keyboard, which it takes
    /// as the fields appear (`focusNameField()`).
    @FocusState private var isNameFieldFocused: Bool

    /// The title of the button that closes the new folder's fields: not
    /// "Cancel", which the sheet's own button is, so VoiceOver tells the
    /// two apart.
    nonisolated static let cancelNewFolderTitle = "Cancel New Folder"
    /// What that button does, for VoiceOver: the fields close, and the
    /// folder chosen in the pop-up stays chosen.
    nonisolated static let cancelNewFolderHint = "Closes the new folder's fields and keeps the folder chosen."

    /// The picker with its pop-up's `options`, the `newFolderParents` a new
    /// folder may go in, and the `selection` it keeps; `isDisabled` and
    /// `isMakingFolder` are for the owners that need them.
    init(
        options: [LibraryFolderOption],
        newFolderParents: [LibraryFolderOption],
        selection: Binding<String>,
        caption: String,
        accessibilityLabel: String,
        onCreateFolder: @escaping (String, String) -> OperationOutcome,
        failureMessage: Binding<String?>,
        isDisabled: Bool = false,
        isMakingFolder: Binding<Bool>? = nil
    ) {
        self.options = options
        self.newFolderParents = newFolderParents
        _selection = selection
        self.caption = caption
        self.accessibilityLabel = accessibilityLabel
        self.onCreateFolder = onCreateFolder
        _failureMessage = failureMessage
        self.isDisabled = isDisabled
        self.isMakingFolder = isMakingFolder
        _showNewFolder = State(initialValue: isMakingFolder?.wrappedValue ?? false)
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker(caption, selection: $selection) {
                ForEach(options, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel(accessibilityLabel)
            .disabled(isDisabled)

            if showNewFolder {
                newFolderFields
            } else {
                HStack {
                    Spacer()
                    Button("New Folder...") {
                        showNewFolder = true
                    }
                    .disabled(isDisabled)
                }
            }
        }
        .clearingFailure($failureMessage, whenChanged: newFolderName)
        .clearingFailure($failureMessage, whenChanged: newFolderParent)
        .onChange(of: showNewFolder) { _, shown in
            isMakingFolder?.wrappedValue = shown
        }
    }

    /// The new folder's name and parent, with Cancel and Create, which
    /// Return presses. The name field takes the keyboard as they appear.
    private var newFolderFields: some View {
        GroupBox("New Folder") {
            VStack(spacing: 8) {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .accessibilityLabel("New folder name")

                Picker("Parent folder", selection: $newFolderParent) {
                    ForEach(newFolderParents, id: \.path) { option in
                        Text(option.label).tag(option.path)
                    }
                }
                .accessibilityLabel("Parent folder for new folder")

                HStack {
                    // Named apart from the sheet's own Cancel, which closes
                    // the whole sheet, so VoiceOver never meets two Cancels
                    // with different jobs.
                    Button(Self.cancelNewFolderTitle) {
                        newFolderName = ""
                        showNewFolder = false
                    }
                    .accessibilityHint(Self.cancelNewFolderHint)
                    Spacer()
                    // Return presses Create while the fields are shown; the
                    // owner's Return-key button stands down meanwhile
                    // (`isMakingFolder`), so one press does one thing.
                    Button("Create", action: createFolder)
                        .keyboardShortcut(.defaultAction)
                        .disabled(BookFolder.normalizedName(newFolderName) == nil)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(isDisabled)
        .onAppear(perform: focusNameField)
    }

    /// Gives the new folder's name field the keyboard, as the fields
    /// appear, whether New Folder... opened them or they were shown from
    /// the start: typing names the folder at once, and VoiceOver, which
    /// follows the keyboard, lands on the field the user types in rather
    /// than on the button that went away. On the next turn of the run
    /// loop, once AppKit holds the field the focus goes to.
    private func focusNameField() {
        DispatchQueue.main.async {
            isNameFieldFocused = true
        }
    }

    /// Makes the folder named in the fields, and chooses it once it is made.
    private func createFolder() {
        guard let name = BookFolder.normalizedName(newFolderName) else { return }
        failureMessage = OperationFailureNotice.message(after: onCreateFolder(name, newFolderParent))
        // A refused or failed folder keeps the fields open with the name,
        // beside the reason.
        guard failureMessage == nil else { return }
        selection = newFolderParent.isEmpty ? name : "\(newFolderParent)/\(name)"
        newFolderName = ""
        showNewFolder = false
    }
}

// MARK: - Move Folder Sheet

struct MoveFolderSheet: View {
    let books: [Book]
    let library: Library
    let lastMovedFolderPath: String
    /// Moves the books into the folder at the given path and returns what
    /// happened, once their packages have moved (PERF14). The owner closes
    /// the sheet after a success; after a failure the sheet stays open with
    /// the chosen destination and shows why.
    let onMove: @MainActor (String) async -> OperationOutcome
    /// Creates a folder from a name and a parent path and returns what
    /// happened. After a success the new folder becomes the destination;
    /// after a failure the new-folder fields keep their input and the sheet
    /// shows why.
    let onCreateFolder: (String, String) -> OperationOutcome
    let onCancel: () -> Void
    /// The sheet's heading in place of "Move …", as Move to Library… heads
    /// it (FR11, branch D); nil for Move to Folder's own.
    let heading: String?
    /// What moving does, shown under the heading and spoken as the Move
    /// button's hint, as Move to Library… says it (FR11, branch D); nil for
    /// none.
    let explanation: String?

    /// The folder path currently selected in the picker
    @State private var selectedPath: String = ""
    /// Why the last Move or Create failed, until the user changes an input.
    @State private var failureMessage: String?
    /// Whether the books are moving now.
    @State private var isWorking = false
    /// Whether the picker's new-folder fields are showing, while Return
    /// presses their Create rather than Move.
    @State private var isMakingFolder: Bool

    /// The sheet that moves `books` within `library`, offering
    /// `lastMovedFolderPath` first; `makingFolder` opens it with the new
    /// folder's fields already shown, as the tests of the Return key need.
    /// Move to Library… (FR11, branch D) gives its own `heading` and the
    /// `explanation` of what moving does.
    init(
        books: [Book],
        library: Library,
        lastMovedFolderPath: String,
        onMove: @escaping @MainActor (String) async -> OperationOutcome,
        onCreateFolder: @escaping (String, String) -> OperationOutcome,
        onCancel: @escaping () -> Void,
        makingFolder: Bool = false,
        heading: String? = nil,
        explanation: String? = nil
    ) {
        self.books = books
        self.library = library
        self.lastMovedFolderPath = lastMovedFolderPath
        self.onMove = onMove
        self.onCreateFolder = onCreateFolder
        self.onCancel = onCancel
        self.heading = heading
        self.explanation = explanation
        _isMakingFolder = State(initialValue: makingFolder)
    }

    /// Title shown in the sheet header
    private var headerTitle: String {
        if let heading {
            return heading
        }
        if books.count == 1, let book = books.first {
            return "Move \"\(book.title)\""
        }
        return "Move \(books.count) Books"
    }

    /// All available destination paths, including "Library Root" (empty string)
    private var folderOptions: [LibraryFolderOption] {
        LibraryFolderOption.options(in: library)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(headerTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // What moving does, as Move to Library… says it (FR11, branch
            // D), read in order after the heading.
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The destination, with New Folder... below it.
            LibraryFolderPicker(
                options: folderOptions,
                newFolderParents: LibraryFolderOption.options(in: library) { $0.depth < BookFolder.maxDepth },
                selection: $selectedPath,
                caption: "Destination",
                accessibilityLabel: "Destination folder",
                onCreateFolder: onCreateFolder,
                failureMessage: $failureMessage,
                isDisabled: isWorking,
                isMakingFolder: $isMakingFolder
            )

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: "Moving \(CountWording.books(books.count))...")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Move") {
                    OperationFailureNotice.run(
                        { await onMove(selectedPath) },
                        isWorking: $isWorking,
                        failureMessage: $failureMessage
                    )
                }
                .accessibilityHint(explanation ?? "")
                // Return moves, except while the new folder's fields are
                // shown, when it presses their Create.
                .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut.defaultAction)
            }
            .disabled(isWorking)
        }
        .padding()
        .frame(width: 400)
        .navigationTitle(headerTitle)
        .interactiveDismissDisabled(isWorking)
        .clearingFailure($failureMessage, whenChanged: selectedPath)
        .onAppear {
            // Default to last moved folder if it still exists, otherwise Library Root
            if !lastMovedFolderPath.isEmpty,
               folderOptions.contains(where: { $0.path == lastMovedFolderPath }) {
                selectedPath = lastMovedFolderPath
            }
        }
    }
}

// MARK: - Rename Folder Sheet

/// Sheet for renaming a folder
struct RenameFolderSheet: View {
    let currentName: String
    @Binding var newName: String
    /// Renames the folder and returns what happened, once the packages of
    /// its books have moved (PERF14). The owner closes the sheet after a
    /// success; after a failure the sheet stays open with the typed name and
    /// shows why.
    let onRename: @MainActor () async -> OperationOutcome
    let onCancel: () -> Void

    /// Why the last Rename failed, until the user changes the name.
    @State private var failureMessage: String?
    /// Whether the folder is being renamed now.
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New folder name")
                .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: "Renaming the folder...")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Rename") {
                    OperationFailureNotice.run(onRename, isWorking: $isWorking, failureMessage: $failureMessage)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(BookFolder.normalizedName(newName) == nil
                          || BookFolder.normalizedName(newName) == currentName)
            }
            .disabled(isWorking)
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Rename Folder")
        .clearingFailure($failureMessage, whenChanged: newName)
        .interactiveDismissDisabled(isWorking)
    }
}

// MARK: - Move Folder to Parent Sheet

/// Sheet for moving a folder to a new parent folder
struct MoveFolderToParentSheet: View {
    let folder: BookFolder
    let library: Library
    /// Moves the folder under the given parent path and returns what
    /// happened, once the packages of its books have moved (PERF14). The
    /// owner closes the sheet after a success; after a failure the sheet
    /// stays open with the chosen parent and shows why.
    let onMove: @MainActor (String) async -> OperationOutcome
    let onCancel: () -> Void

    @State private var selectedParent = ""
    /// Why the last Move failed, until the user picks another parent.
    @State private var failureMessage: String?
    /// Whether the folder is moving now.
    @State private var isWorking = false

    /// Valid destinations: all folders except the folder itself, its descendants, and its current parent
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            // Exclude: the folder itself, its descendants, and check depth limit
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            // Check that moving here wouldn't exceed max depth
            let newDepth = (f.fullPath.isEmpty ? 0 : f.fullPath.components(separatedBy: "/").count) + 1
            if newDepth > BookFolder.maxDepth { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("New parent folder", selection: $selectedParent) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination parent folder")
            .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: "Moving the folder...")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move") {
                    OperationFailureNotice.run(
                        { await onMove(selectedParent) },
                        isWorking: $isWorking,
                        failureMessage: $failureMessage
                    )
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedParent == folder.parentPath)
            }
            .disabled(isWorking)
        }
        .padding()
        .frame(width: 400)
        .navigationTitle("Move Folder: \(folder.name)")
        .clearingFailure($failureMessage, whenChanged: selectedParent)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            selectedParent = folder.parentPath
        }
    }
}

// MARK: - Delete Folder Move Contents Sheet

/// Sheet for choosing where to move folder contents when deleting a folder
struct DeleteFolderMoveContentsSheet: View {
    let folder: BookFolder
    let library: Library
    /// Moves the folder's contents to the given path, deletes the folder,
    /// and returns what happened, once the packages of its books have moved
    /// (PERF14). The owner closes the sheet after a success; after a failure
    /// the sheet stays open with the chosen destination and shows why.
    let onConfirm: @MainActor (String) async -> OperationOutcome
    let onCancel: () -> Void

    @State private var selectedDestination = ""
    /// Why the last attempt failed, until the user picks another destination.
    @State private var failureMessage: String?
    /// Whether the contents are moving now.
    @State private var isWorking = false

    /// Valid destinations: all folders except the folder being deleted and its descendants
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move Contents of \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Choose where to move the books and subfolders before deleting \"\(folder.name)\".")
                .font(.callout)
                .foregroundColor(.secondary)

            Picker("Move contents to", selection: $selectedDestination) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination for folder contents")
            .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: "Moving the folder's contents...")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move Contents & Delete Folder") {
                    OperationFailureNotice.run(
                        { await onConfirm(selectedDestination) },
                        isWorking: $isWorking,
                        failureMessage: $failureMessage
                    )
                }
                .keyboardShortcut(.return, modifiers: [])
            }
            .disabled(isWorking)
        }
        .padding()
        .frame(width: 450)
        .navigationTitle("Move Contents: \(folder.name)")
        .clearingFailure($failureMessage, whenChanged: selectedDestination)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            // Default to the parent of the folder being deleted
            selectedDestination = folder.parentPath
        }
    }
}
