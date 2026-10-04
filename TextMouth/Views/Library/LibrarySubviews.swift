import Combine
import SwiftUI

// MARK: - Edit Mode Bar

/// Toolbar shown at the top of the library when edit mode is active.
/// Provides batch actions and selection controls that work reliably with VoiceOver.
struct EditModeBar: View {
    let selectedCount: Int
    let totalCount: Int
    /// Whether removing asks first and where deleted files go, so the
    /// Remove button says what it will do.
    let removalPreferences: RemovalPreferences
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onMove: () -> Void
    let onRemove: () -> Void
    let onDone: () -> Void

    /// The words for removing the selected books.
    private var removal: LibraryRemoveCommandWording {
        LibraryRemoveCommandWording(preferences: removalPreferences, count: selectedCount)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) of \(totalCount) selected")
                .font(.callout)
                .fontWeight(.medium)

            Spacer()

            Button(selectedCount == totalCount ? "Deselect All" : "Select All") {
                if selectedCount == totalCount {
                    onDeselectAll()
                } else {
                    onSelectAll()
                }
            }
            .accessibilityLabel(selectedCount == totalCount ? "Deselect all books" : "Select all \(totalCount) books")

            Button("Move") { onMove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Move \(CountWording.books(selectedCount)) to folder")

            Button(removal.shortTitle, role: .destructive) { onRemove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel(removal.accessibilityLabel)
                .accessibilityHint(removal.accessibilityHint)

            Button("Done") { onDone() }
                .fontWeight(.semibold)
                .accessibilityLabel("Exit edit mode")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit mode, \(selectedCount) of \(totalCount) books selected")
    }
}

// MARK: - Time Remaining Bar

struct TimeRemainingBar: View {
    let books: [Book]
    let wpm: Double
    /// How many of `books` are in the cloud (FR02), which the bar shows and
    /// speaks when it is more than 0. The list counts them in a cloud
    /// library and passes 0 anywhere else, where the bar is as it was.
    var booksInCloud: Int = 0
    /// How many of `books` are kept on this Mac (Keep on This Mac), which
    /// the bar shows and speaks after the books in the cloud when it is more
    /// than 0. The list counts them in a cloud library and passes 0 anywhere
    /// else.
    var booksKept: Int = 0
    /// Optional fallback focus target for the library when Continue Listening is absent.
    /// This summary is part of the content area and shows up reliably in the AX tree,
    /// unlike List section headers in this view hierarchy.
    var focusIdentifier: String? = nil
    var shouldTriggerFocus = false
    /// Where readers are between checkpoints (TODO PERF11): the bar adds up
    /// the time left from them and redraws as they move, while the list
    /// around it does not. The inert store, the default, holds none.
    @ObservedObject var livePositions: LiveReadingPositions = .inert

    var body: some View {
        let (time, known, unknown) = computeTimeRemaining()
        if known > 0 || unknown > 0 {
            HStack(spacing: 12) {
                Label {
                    if known > 0 {
                        Text("\(TimeFormatting.format(time)) remaining")
                    }
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)

                if unknown > 0 {
                    Text("(\(CountWording.books(unknown)) not yet opened)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if booksInCloud > 0 {
                    Text(Self.cloudCountText(booksInCloud))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if booksKept > 0 {
                    Text(Self.keptCountText(booksKept))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(CountWording.books(books.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(time: time, known: known, unknown: unknown))
            .accessibilityIdentifier(focusIdentifier ?? "")
            .background(
                Group {
                    if shouldTriggerFocus {
                        StandardVoiceOverFocus(delay: 1.2)
                    }
                }
            )
        }
    }

    /// The time left in `books` at `wpm`, each from its reader's live
    /// position while that is newer than the library's, with how many books
    /// have a known and an unknown time left.
    private func computeTimeRemaining() -> (TimeInterval, Int, Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = livePositions.applied(to: book).estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    private func accessibilityLabel(time: TimeInterval, known: Int, unknown: Int) -> String {
        var parts: [String] = []
        parts.append(CountWording.books(books.count))
        if known > 0 {
            parts.append("\(TimeFormatting.spoken(time)) total remaining at current speed")
        }
        if unknown > 0 {
            parts.append("\(CountWording.phrase(unknown, singular: "book has", plural: "books have")) not been opened yet")
        }
        if booksInCloud > 0 {
            parts.append(Self.spokenCount(booksInCloud, "in the cloud"))
        }
        if booksKept > 0 {
            parts.append(Self.spokenCount(booksKept, "kept on this Mac"))
        }
        return parts.joined(separator: ". ")
    }

    /// What VoiceOver says for the whole bar, as its body sets it.
    var summaryAccessibilityLabel: String {
        let (time, known, unknown) = computeTimeRemaining()
        return accessibilityLabel(time: time, known: known, unknown: unknown)
    }

    /// The bar's visible count of books in the cloud: "1 book in the cloud",
    /// "3 books in the cloud".
    static func cloudCountText(_ count: Int) -> String {
        "\(CountWording.books(count)) in the cloud"
    }

    /// The bar's visible count of books kept on this Mac: "1 book kept on
    /// this Mac", "3 books kept on this Mac".
    static func keptCountText(_ count: Int) -> String {
        "\(CountWording.books(count)) kept on this Mac"
    }

    /// `count` books said to be somewhere, as the bar's label speaks it:
    /// "1 book is in the cloud", "3 books are kept on this Mac".
    private static func spokenCount(_ count: Int, _ place: String) -> String {
        "\(CountWording.phrase(count, singular: "book is", plural: "books are")) \(place)"
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void
    let onNavigateRoot: () -> Void

    var body: some View {
        HStack {
            Button("Library") { onNavigateRoot() }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to library root")

            let parts = path.components(separatedBy: "/")
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button(part) {
                    let subPath = parts[0...index].joined(separator: "/")
                    onNavigate(subPath)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to \(part)")
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: BookFolder
    var bookCount: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.headline)
            Spacer()
            Text(CountWording.books(bookCount))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(CountWording.books(bookCount))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to open folder")
    }
}

// MARK: - Book Row

struct BookRow: View {
    let book: Book
    var isOpenInWindow: Bool = false
    var wpm: Double = 200
    var isEditMode: Bool = false
    var isEditSelected: Bool = false
    /// The book's cloud state, shown and spoken after the New or Now Reading
    /// badge (FR02). Nil when the library is not in a cloud location, or the
    /// book has not been checked yet: the row then looks and reads as it
    /// always has. The list passes what `BookCloudStates` recorded, so a row
    /// never asks the file system anything.
    var cloudState: BookCloudState? = nil
    /// Whether the row says the book is kept on this Mac (Keep on This Mac):
    /// "Kept on this Mac", shown and spoken after the cloud note. The list
    /// passes true only for a kept book in a cloud library.
    var isKeptOnThisMac: Bool = false
    /// The book's transcription note (FR05): "Transcribed" or
    /// "Transcribing", shown and spoken after the cloud notes; nil for none.
    var transcriptionNote: TranscriptionRowNote? = nil
    /// The cloud commands of the row's context menu, which are also the
    /// row's VoiceOver actions (VO-Command-Space), under the same names
    /// (FR02).
    var cloudCommands: [LibraryCloudCommand] = []
    /// Runs one of `cloudCommands`.
    var performCloudCommand: (LibraryCloudCommand) -> Void = { _ in }
    /// The transcription commands of the row's context menu, which are also
    /// its VoiceOver actions, after the cloud commands, under the same names
    /// (FR05).
    var transcriptionCommands: [LibraryTranscriptionCommand] = []
    /// Runs one of `transcriptionCommands`.
    var performTranscriptionCommand: (LibraryTranscriptionCommand) -> Void = { _ in }
    /// The book's live position while a reader plays it (TODO PERF11). The
    /// row observes this one entry, so it redraws when its own book's
    /// reader moves and no other row does. The inert entry, the default,
    /// holds none.
    @ObservedObject var livePosition: LiveReadingPosition = .inert

    /// The book as the row shows its progress and time left: with its
    /// reader's live position while that is newer than the library's.
    private var shownBook: Book {
        livePosition.applied(to: book)
    }

    var body: some View {
        let _ = ViewBodyCounter.record("BookRow")
        HStack(spacing: 8) {
            // Selection indicator in edit mode
            if isEditMode {
                Image(systemName: isEditSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEditSelected ? .accentColor : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(book.title)
                        .font(.headline)

                    if book.lastOpened == nil {
                        Text("New")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    } else if isOpenInWindow {
                        Text("Now Reading")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    }

                    // "Downloaded", "In Cloud", and so on, in a cloud library.
                    if let cloudState {
                        BookCloudNote(state: cloudState)
                    }

                    // "Kept on this Mac", after the cloud note.
                    if isKeptOnThisMac {
                        BookKeptNote()
                    }

                    // "Transcribed" or "Transcribing", after the cloud notes (FR05).
                    if let transcriptionNote {
                        RowNoteBadge(symbolName: transcriptionNote.symbolName, text: transcriptionNote.text)
                    }
                }
                HStack {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let progress = Self.progressText(for: shownBook) {
                        Text(progress.visible)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let remaining = shownBook.estimatedTimeRemaining(wpm: wpm) {
                        Text("\(TimeFormatting.format(remaining)) left")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(book.format.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint(isEditMode
            ? "Double-tap to \(isEditSelected ? "deselect" : "select")"
            : "Press Enter to open, Command I for info")
        .accessibilityAddTraits(isEditSelected ? [.isSelected] : [])
        .accessibilityActions {
            ForEach(cloudCommands) { command in
                Button(command.title) { performCloudCommand(command) }
            }
            ForEach(transcriptionCommands) { command in
                Button(command.title) { performTranscriptionCommand(command) }
            }
        }
    }

    /// The names of the row's own VoiceOver actions, in the order VoiceOver
    /// lists them.
    var accessibilityActionNames: [String] {
        cloudCommands.map(\.title) + transcriptionCommands.map(\.title)
    }

    /// Spoken label for the whole row, replacing its combined children.
    var rowAccessibilityLabel: String {
        var parts: [String] = []
        if isEditMode && isEditSelected {
            parts.append("Selected")
        }
        parts.append(book.title)
        parts.append("by \(book.author)")
        if book.lastOpened == nil {
            parts.append("New")
        } else if isOpenInWindow {
            parts.append("Now Reading")
        }
        if let cloudNote = cloudState?.spokenNote {
            parts.append(cloudNote)
        }
        if isKeptOnThisMac {
            parts.append(KeptOnThisMacNote.text)
        }
        if let transcriptionNote {
            parts.append(transcriptionNote.text)
        }
        let besideDownloadPercentage = cloudState?.speaksPercentage ?? false
        if let progress = Self.spokenProgress(for: shownBook, besideDownloadPercentage: besideDownloadPercentage) {
            parts.append(progress)
        }
        if let remaining = shownBook.estimatedTimeRemaining(wpm: wpm) {
            parts.append("\(TimeFormatting.spoken(remaining)) remaining")
        }
        parts.append(book.format.displayName)
        return parts.joined(separator: ", ")
    }

    /// Progress shown in a library row — visible "42%", spoken "42 percent" —
    /// or nil to hide it when it cannot be known without parsing the book.
    /// Whole percents are rounded the same way Where Am I speaks them.
    static func progressText(for book: Book) -> (visible: String, spoken: String)? {
        guard let percent = book.percentComplete else { return nil }
        let wholePercent = String(format: "%.0f", percent)
        return (visible: "\(wholePercent)%", spoken: "\(wholePercent) percent")
    }

    /// The reading progress as the row's label speaks it: "42 percent", or
    /// "42 percent read" when the label also speaks a download's percentage
    /// (FR02), so it never holds two bare percentages. Nil when the row
    /// shows no progress.
    static func spokenProgress(for book: Book, besideDownloadPercentage: Bool) -> String? {
        guard let progress = progressText(for: book) else { return nil }
        return besideDownloadPercentage ? "\(progress.spoken) read" : progress.spoken
    }
}

// MARK: - Library List Row

/// Whether a book can move up, and whether it can move down, in the manual
/// order the list shows (TODO A06), read from the list's own order rather
/// than by sorting the folder again for every row (PERF28).
struct LibraryManualMoves: Equatable {
    /// Whether Move Up is offered: the book is not first.
    let canMoveUp: Bool
    /// Whether Move Down is offered: the book is not last.
    let canMoveDown: Bool

    /// Whether either move is offered, so the menu shows them apart.
    var canMove: Bool {
        canMoveUp || canMoveDown
    }

    /// Each book's moves in `ordered`, a folder's books in their manual
    /// order as the list shows it, by ID: every book but the first can move
    /// up, and every book but the last can move down, as
    /// `ManualBookOrder.canMove` decides. A book listed twice keeps its
    /// first place, as it does there.
    static func moves(in ordered: [Book]) -> [UUID: LibraryManualMoves] {
        var moves: [UUID: LibraryManualMoves] = [:]
        moves.reserveCapacity(ordered.count)
        for (index, book) in ordered.enumerated() where moves[book.id] == nil {
            moves[book.id] = LibraryManualMoves(
                canMoveUp: index > 0,
                canMoveDown: index < ordered.count - 1
            )
        }
        return moves
    }
}

/// What a library row's commands do, supplied by the list. Each closure acts
/// on the list's state as it is when the command runs, so rows never compare
/// them (PERF28).
struct LibraryBookRowActions {
    /// Opens a book in its reader.
    let open: (Book) -> Void
    /// Shows a book's Book Info.
    let showInfo: (Book) -> Void
    /// Enters edit mode with a book selected.
    let select: (Book) -> Void
    /// Selects or deselects a book in edit mode.
    let toggleSelection: (Book) -> Void
    /// Asks where to move books, and moves them there.
    let moveToFolder: ([Book]) -> Void
    /// Moves a book one place up (-1) or down (+1) in the folder's manual
    /// order.
    let moveInManualOrder: (Book, Int) -> Void
    /// Runs a cloud command (FR02).
    let performCloudCommand: (LibraryCloudCommand) -> Void
    /// Removes books, as the removal preferences say.
    let remove: ([Book]) -> Void
    /// Opens the Export dialog for books (FR05). Doing nothing unless the
    /// list supplies it, so rows made only to be compared need not.
    var export: ([Book]) -> Void = { _ in }
    /// Opens a book's text in the user's own editor, or, when the flag is
    /// true, in an app they choose (FR05). Doing nothing unless the list
    /// supplies it.
    var editText: (Book, _ choosingApp: Bool) -> Void = { _, _ in }
    /// Runs a transcription command (FR05). Doing nothing unless the list
    /// supplies it.
    var performTranscriptionCommand: (LibraryTranscriptionCommand) -> Void = { _ in }
}

/// One book's row in the library list: the row, its context menu, its
/// default action, and its cloud commands (FR02) and transcription commands
/// (FR05) as VoiceOver actions, which act on the same books.
///
/// Equatable on everything it shows (PERF28). When a change to the library
/// draws the list again, SwiftUI skips every row the change left as it was,
/// so one changed book redraws one row; and SwiftUI builds a row's context
/// menu each time the row draws, which now happens only when the row has
/// something new to show. The comparison lives here, not in `BookRow`,
/// which observes its live position: what a row observes cannot be read by
/// a comparison, which runs outside the main actor.
struct LibraryBookListRow: View, Equatable {
    /// The row's book.
    let book: Book
    /// Whether a reader window has the book open.
    let isOpenInWindow: Bool
    /// The speed the time left is figured at.
    let wpm: Double
    /// Whether the list is in edit mode.
    let isEditMode: Bool
    /// Whether the book is selected in edit mode.
    let isEditSelected: Bool
    /// The book's cloud state, when the library is in a cloud location
    /// (FR02).
    let cloudState: BookCloudState?
    /// Whether the row says the book is kept on this Mac (Keep on This Mac).
    let isKeptOnThisMac: Bool
    /// The books the commands act on: the selection, in list order, when
    /// the row belongs to a selection of several books; otherwise the row's
    /// own book.
    let targets: [Book]
    /// The cloud commands for `targets` (FR02).
    let cloudCommands: [LibraryCloudCommand]
    /// Move Up and Move Down, offered for the row's own book while the list
    /// shows its folder's manual order; nil otherwise.
    let manualMoves: LibraryManualMoves?
    /// Whether removing asks first and where deleted files go, so Remove
    /// says what it will do.
    let removalPreferences: RemovalPreferences
    /// The book's live position while a reader plays it (TODO PERF11): one
    /// object for the book all session, compared by identity. `BookRow`
    /// observes it, so its changes redraw the row's progress alone.
    let livePosition: LiveReadingPosition
    /// The transcription commands for `targets` (FR05): context menu items
    /// and VoiceOver actions alike.
    var transcriptionCommands: [LibraryTranscriptionCommand] = []
    /// The book's transcription note, "Transcribed" or "Transcribing"
    /// (FR05), or nil for none.
    var transcriptionNote: TranscriptionRowNote? = nil
    /// What the commands do. Never compared.
    let actions: LibraryBookRowActions

    /// Whether two rows show the same thing: every input but `actions`.
    nonisolated static func == (lhs: LibraryBookListRow, rhs: LibraryBookListRow) -> Bool {
        lhs.book == rhs.book
            && lhs.isOpenInWindow == rhs.isOpenInWindow
            && lhs.wpm == rhs.wpm
            && lhs.isEditMode == rhs.isEditMode
            && lhs.isEditSelected == rhs.isEditSelected
            && lhs.cloudState == rhs.cloudState
            && lhs.isKeptOnThisMac == rhs.isKeptOnThisMac
            && lhs.targets == rhs.targets
            && lhs.cloudCommands == rhs.cloudCommands
            && lhs.manualMoves == rhs.manualMoves
            && lhs.removalPreferences == rhs.removalPreferences
            && lhs.livePosition === rhs.livePosition
            && lhs.transcriptionCommands == rhs.transcriptionCommands
            && lhs.transcriptionNote == rhs.transcriptionNote
    }

    var body: some View {
        let _ = ViewBodyCounter.record("LibraryBookListRow")
        BookRow(
            book: book,
            isOpenInWindow: isOpenInWindow,
            wpm: wpm,
            isEditMode: isEditMode,
            isEditSelected: isEditSelected,
            cloudState: cloudState,
            isKeptOnThisMac: isKeptOnThisMac,
            transcriptionNote: transcriptionNote,
            cloudCommands: cloudCommands,
            performCloudCommand: actions.performCloudCommand,
            transcriptionCommands: transcriptionCommands,
            performTranscriptionCommand: actions.performTranscriptionCommand,
            livePosition: livePosition
        )
        .accessibilityAction(.default) {
            if isEditMode {
                actions.toggleSelection(book)
            } else {
                actions.open(book)
            }
        }
        .contextMenu {
            menu
        }
    }

    /// The row's context menu. Its commands act on `targets`: the selection
    /// when the row belongs to one, otherwise the row's book. The cloud
    /// commands (FR02) and the transcription commands (FR05) are also the
    /// row's VoiceOver actions.
    @ViewBuilder
    private var menu: some View {
        let isMulti = targets.count > 1

        if !isMulti {
            Button("Open") {
                actions.open(book)
            }
            Button("Book Info") {
                actions.showInfo(book)
            }
        }
        if !isEditMode {
            Button("Select") {
                actions.select(book)
            }
        }
        Button(isMulti ? "Move \(targets.count) Books to Folder..." : "Move to Folder...") {
            actions.moveToFolder(targets)
        }
        // The Export dialog for the row's book or the selection (FR05).
        Button(BookExportWording.commandTitle(count: targets.count)) {
            actions.export(targets)
        }
        // A text book's text in the user's own editor (FR05).
        if !isMulti && BookTextEditor.canEditText(of: book) {
            Button(BookTextEditWording.editTitle) {
                actions.editText(book, false)
            }
            Button(BookTextEditWording.editWithTitle) {
                actions.editText(book, true)
            }
        }
        // Transcribe Audio… for an audiobook, and Delete Transcript… for a transcribed
        // one (FR05), also VoiceOver actions.
        ForEach(transcriptionCommands) { command in
            Button(command.title) {
                actions.performTranscriptionCommand(command)
            }
        }
        // Manual order move commands: single book only, where
        // the list shows one folder's manual order (TODO A06)
        if let manualMoves, manualMoves.canMove {
            Divider()
            if manualMoves.canMoveUp {
                Button("Move Up") {
                    actions.moveInManualOrder(book, -1)
                }
            }
            if manualMoves.canMoveDown {
                Button("Move Down") {
                    actions.moveInManualOrder(book, 1)
                }
            }
        }
        // Download Now and Remove Download in a cloud library, and Show in
        // Finder in every library (FR02).
        if !cloudCommands.isEmpty {
            Divider()
            ForEach(cloudCommands) { command in
                Button(command.title) {
                    actions.performCloudCommand(command)
                }
            }
        }
        Divider()
        // Says what removal will do: ask first, or
        // move the files to the Trash, or delete them.
        Button(
            LibraryRemoveCommandWording(
                preferences: removalPreferences,
                books: targets
            ).menuTitle,
            role: .destructive
        ) {
            actions.remove(targets)
        }
    }
}

// MARK: - Tree-Order Folder Sorting

extension Array where Element == BookFolder {
    /// Sort folders in tree order: each parent is immediately followed by its children,
    /// then the next sibling. Siblings are sorted alphabetically.
    /// This prevents unrelated folders like "Misc SciFi anthologies" from appearing
    /// between "Misc SciFi" and "Misc SciFi/Sub" in picker lists.
    func sortedTreeOrder() -> [BookFolder] {
        // Sort so that a folder's children appear immediately after it,
        // before any unrelated folder that shares a prefix (e.g. "Misc SciFi"
        // children before "Misc SciFi anthologies").
        //
        // Replace "/" with "\0" for comparison so path separators sort before
        // any printable character (space is 0x20, "/" is 0x2F — both after "\0").
        // This ensures "Misc SciFi\0Sub" < "Misc SciFi anthologies".
        sorted {
            let a = $0.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            let b = $1.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            return a < b
        }
    }
}

// MARK: - Removal Preferences

extension View {
    /// Keeps `preferences` equal to the removal preferences in config.json,
    /// so removal buttons and confirmations always describe what removing
    /// will really do, even right after the preferences change in Settings.
    /// Only a change to one of the two preferences updates it, so other
    /// settings changes cause no redraw. Every view subscribes to the one
    /// shared model, so a view that draws again keeps its subscription.
    @MainActor
    func trackingRemovalPreferences(_ preferences: Binding<RemovalPreferences>) -> some View {
        onReceive(RemovalPreferencesModel.shared.$preferences) { current in
            preferences.wrappedValue = current
        }
    }
}
