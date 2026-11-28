import SwiftUI

// MARK: - Wording

/// Every word the Library's sheets say that no other wording enum owns
/// (FR34): Book Information's rows, the New Folder, Move, Rename, and Move
/// Contents sheets, and their announcements. Shared words come from
/// `LibraryWindowWording` (Cancel, Save) and `MetadataEditorWording` (the book's
/// fields), one definition for each.
enum LibrarySheetWording {
    // MARK: Book Information

    /// The heading of the Book Information sheet.
    static var bookInformation: String {
        // Translators: Heading of the sheet that shows and edits a book's title and author, and lists its other details.
        InterfaceText.line("common.bookInformation", "Book Information")
    }

    /// What VoiceOver says for the author field, before "edited by hand".
    static var bookAuthorLabel: String {
        // Translators: What VoiceOver says for the book information sheet's field for the book's author.
        InterfaceText.line("librarySheet.bookAuthorLabel", "Book author")
    }

    /// The row that shows when the book was added.
    static var addedRow: String {
        // Translators: Name of the book information sheet's row that shows the date the book was added to the library.
        InterfaceText.line("librarySheet.addedRow", "Added")
    }

    /// The row that shows when the book was last opened.
    static var lastOpenedRow: String {
        // Translators: Name of the book information sheet's row that shows the date the book was last opened.
        InterfaceText.line("common.lastOpened", "Last Opened")
    }

    /// The row that shows how many words the book has.
    static var wordCountRow: String {
        // Translators: Name of the book information sheet's row that shows how many words the book has.
        InterfaceText.line("librarySheet.wordCountRow", "Word Count")
    }

    /// The window title of the Book Information sheet.
    static func infoTitle(_ bookTitle: String) -> String {
        // Translators: Window title of the sheet that shows a book's information. %@ is the book's title.
        InterfaceText.line("common.infoValue", "Info: \(bookTitle)")
    }

    // MARK: Folder fields

    /// The title of the New Folder sheet and of its fields' group.
    static var newFolderTitle: String {
        // Translators: Heading of the sheet that makes a new folder, and of the group of fields that makes one inside a folder chooser.
        InterfaceText.line("common.newFolder", "New Folder")
    }

    /// The name field of a folder sheet.
    static var folderNameField: String {
        // Translators: Name of the text field that holds a folder's name, in the New Folder and Rename Folder sheets.
        InterfaceText.line("common.folderName", "Folder name")
    }

    /// What VoiceOver says for the name field of a folder that is made or renamed.
    static var newFolderNameLabel: String {
        // Translators: What VoiceOver says for the text field that holds the name a folder is made or renamed with.
        InterfaceText.line("librarySheet.newFolderNameLabel", "New folder name")
    }

    /// The pop-up that chooses a new folder's parent.
    static var parentFolder: String {
        // Translators: Name of the pop-up that chooses the folder a new folder is made in.
        InterfaceText.line("librarySheet.parentFolder", "Parent folder")
    }

    /// What VoiceOver says for the parent pop-up of the new folder's fields in a folder chooser.
    static var parentFolderForNewFolder: String {
        // Translators: What VoiceOver says for the pop-up that chooses the folder a new folder is made in, among a folder chooser's new folder fields.
        InterfaceText.line("librarySheet.parentFolderForNewFolder", "Parent folder for new folder")
    }

    /// The button that makes the folder.
    static var create: String {
        // Translators: Button that makes the new folder.
        InterfaceText.line("librarySheet.create", "Create")
    }

    /// The button that opens the new folder's fields.
    static var newFolderButton: String {
        // Translators: Button in a folder chooser that shows the fields that make a new folder. The three dots mean more fields open.
        InterfaceText.line("librarySheet.newFolderButton", "New Folder...")
    }

    // MARK: Move

    /// The button that moves the books or the folder.
    static var move: String {
        // Translators: Button that moves the books or the folder to the place chosen.
        InterfaceText.line("librarySheet.move", "Move")
    }

    /// The caption of the destination pop-up in the Move sheet.
    static var destinationCaption: String {
        // Translators: Caption of the pop-up that chooses the folder the books move into.
        InterfaceText.line("librarySheet.destinationCaption", "Destination")
    }

    /// What VoiceOver says for the destination pop-up in the Move sheet.
    static var destinationFolderLabel: String {
        // Translators: What VoiceOver says for the pop-up that chooses the folder the books move into.
        InterfaceText.line("librarySheet.destinationFolderLabel", "Destination folder")
    }

    /// The heading of the Move sheet for one book.
    static func moveTitle(bookTitle: String) -> String {
        // Translators: Heading of the sheet that moves one book to a folder. %@ is the book's title.
        InterfaceText.line("librarySheet.moveTitle.named", "Move \"\(bookTitle)\"")
    }

    /// The heading of the Move sheet for several books.
    static func moveTitle(count: Int) -> String {
        // Translators: Heading of the sheet that moves several books to a folder. %lld is how many books.
        InterfaceText.line("librarySheet.moveTitle.books", "Move \(number: count) Books")
    }

    /// What the Move sheet says while the books move.
    static func movingBooks(count: Int) -> String {
        // Translators: Status shown and spoken in the Move sheet while the books' packages move. %lld is how many books. The three dots mean it is in progress.
        InterfaceText.line("librarySheet.movingBooks", "Moving \(number: count) books...")
    }

    /// The heading of the sheet that moves a folder under a new parent.
    static func moveTitle(folderName: String) -> String {
        // Translators: Heading of the sheet that moves a folder under a new parent folder. %@ is the folder's name.
        InterfaceText.line("librarySheet.moveTitle.named", "Move \"\(folderName)\"")
    }

    /// The pop-up that chooses the folder's new parent.
    static var newParentFolder: String {
        // Translators: Caption of the pop-up that chooses the folder a moved folder goes into.
        InterfaceText.line("librarySheet.newParentFolder", "New parent folder")
    }

    /// What VoiceOver says for the new parent pop-up.
    static var destinationParentFolder: String {
        // Translators: What VoiceOver says for the pop-up that chooses the folder a moved folder goes into.
        InterfaceText.line("librarySheet.destinationParentFolder", "Destination parent folder")
    }

    /// The window title of the sheet that moves a folder.
    static func moveFolderNavigationTitle(_ name: String) -> String {
        // Translators: Window title of the sheet that moves a folder. %@ is the folder's name.
        InterfaceText.line("librarySheet.moveFolderNavigationTitle", "Move Folder: \(name)")
    }

    /// What the sheet says while the folder moves.
    static var movingTheFolder: String {
        // Translators: Status shown and spoken in the sheet that moves a folder, while its books' packages move. The three dots mean it is in progress.
        InterfaceText.line("librarySheet.movingTheFolder", "Moving the folder...")
    }

    // MARK: Rename

    /// The heading and window title of the Rename Folder sheet.
    static var renameFolderTitle: String {
        // Translators: Heading and window title of the sheet that renames a folder.
        InterfaceText.line("librarySheet.renameFolderTitle", "Rename Folder")
    }

    /// The button that renames the folder.
    static var rename: String {
        // Translators: Button that gives the folder the new name.
        InterfaceText.line("common.rename", "Rename")
    }

    /// What the sheet says while the folder is renamed.
    static var renamingTheFolder: String {
        // Translators: Status shown and spoken in the Rename Folder sheet while the folder's books' packages move to the new name. The three dots mean it is in progress.
        InterfaceText.line("librarySheet.renamingTheFolder", "Renaming the folder...")
    }

    // MARK: Delete a folder, moving its contents

    /// The heading of the sheet that asks where a deleted folder's contents go.
    static func moveContentsTitle(_ name: String) -> String {
        // Translators: Heading of the sheet that chooses where the books and subfolders of a folder go before it is deleted. %@ is the folder's name.
        InterfaceText.line("librarySheet.moveContentsTitle", "Move Contents of \"\(name)\"")
    }

    /// What the sheet explains under its heading.
    static func moveContentsExplanation(_ name: String) -> String {
        // Translators: Explanation in the sheet that chooses where a folder's contents go before the folder is deleted. %@ is the folder's name.
        InterfaceText.line("librarySheet.moveContentsExplanation", "Choose where to move the books and subfolders before deleting \"\(name)\".")
    }

    /// The pop-up that chooses where the contents go.
    static var moveContentsTo: String {
        // Translators: Caption of the pop-up that chooses the folder a deleted folder's books and subfolders move into.
        InterfaceText.line("librarySheet.moveContentsTo", "Move contents to")
    }

    /// What VoiceOver says for that pop-up.
    static var destinationForContents: String {
        // Translators: What VoiceOver says for the pop-up that chooses the folder a deleted folder's books and subfolders move into.
        InterfaceText.line("librarySheet.destinationForContents", "Destination for folder contents")
    }

    /// The button that moves the contents and deletes the folder.
    static var moveContentsAndDelete: String {
        // Translators: Button that moves a folder's books and subfolders to the chosen place and then deletes the folder.
        InterfaceText.line("librarySheet.moveContentsAndDelete", "Move Contents & Delete Folder")
    }

    /// The window title of that sheet.
    static func moveContentsNavigationTitle(_ name: String) -> String {
        // Translators: Window title of the sheet that chooses where a folder's contents go before it is deleted. %@ is the folder's name.
        InterfaceText.line("librarySheet.moveContentsNavigationTitle", "Move Contents: \(name)")
    }

    /// What the sheet says while the contents move.
    static var movingTheFoldersContents: String {
        // Translators: Status shown and spoken while a deleted folder's books and subfolders move to their new place. The three dots mean it is in progress.
        InterfaceText.line("librarySheet.movingTheFoldersContents", "Moving the folder's contents...")
    }
}

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
    /// The Text Encoding pop-up of a text book from the listener's own file
    /// (encodingchoice): what its file is read in, and the re-read in
    /// another encoding. Made for every book the sheet shows, cheaply, and
    /// shown only for one that offers the choice.
    @StateObject private var encoding: TextEncodingChoiceModel
    /// The Braille File Characters pop-up of a BRF or BRL braille book
    /// (braillecodes): the code its file is read with, and the re-read with
    /// another. Made for every book the sheet shows, cheaply, and shown only
    /// for one that offers the choice. A book offers the encoding's pop-up or
    /// this one and the Braille Code pop-up, never the encoding's and one of
    /// the braille pop-ups.
    @StateObject private var fileCode: BrailleFileCodeChoiceModel
    /// The Braille Code pop-up of a braille book (FMT21): the table its text
    /// is translated to print by, and the re-read with another. Made for
    /// every book the sheet shows, cheaply (the tables are listed when the
    /// sheet loads), and shown only for one that offers the choice.
    @StateObject private var brailleCode: BrailleCodeChoiceModel
    @Environment(\.dismiss) private var dismiss
    /// Whether sync is on, which shows the Kept on all devices checkbox (FR43).
    @ObservedObject private var cloudStates = BookCloudStates.shared
    /// The books kept on all devices, which the checkbox shows and changes.
    @ObservedObject private var keptBooks = KeptBooks.shared

    init(book: Book, libraryViewModel: LibraryViewModel) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self._title = State(initialValue: book.title)
        self._author = State(initialValue: book.author)
        self._opened = State(initialValue: Self.values(title: book.title, author: book.author))
        self._encoding = StateObject(wrappedValue: TextEncodingChoiceModel(book: book, library: libraryViewModel))
        self._fileCode = StateObject(wrappedValue: BrailleFileCodeChoiceModel(book: book, library: libraryViewModel))
        self._brailleCode = StateObject(wrappedValue: BrailleCodeChoiceModel(book: book, library: libraryViewModel))
    }

    /// Whether the book offers a re-read pop-up: the Text Encoding pop-up,
    /// the Braille File Characters pop-up, or the Braille Code pop-up.
    private var offersRereadChoice: Bool {
        book.offersTextEncodingChoice || book.offersBrailleFileCodeChoice || book.offersBrailleTableChoice
    }

    /// The message the sheet's one line for a refusal shows: that of the
    /// re-read pop-up used last, if it left one (`RereadFailureOrder`).
    private var rereadFailureMessage: String? {
        RereadFailureOrder.latest(among: [
            (encoding.failureMessage, encoding.failureStamp),
            (fileCode.failureMessage, fileCode.failureStamp),
            (brailleCode.failureMessage, brailleCode.failureStamp),
        ])
    }

    /// Whether the book is being read again from any pop-up, which shows
    /// the work indicator and keeps the sheet open until it ends.
    private var isReadingAgain: Bool {
        encoding.isWorking || fileCode.isWorking || brailleCode.isWorking
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(LibrarySheetWording.bookInformation)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                // Each label says "edited by hand" when the user typed the
                // value (`Book.handEdits`).
                TextField(MetadataEditorWording.titleField, text: $title)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel(MetadataEditorWording.bookTitleLabel, for: .title, in: book.handEdits))
                TextField(MetadataEditorWording.authorField, text: $author)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel(LibrarySheetWording.bookAuthorLabel, for: .author, in: book.handEdits))

                LabeledContent(MetadataEditorWording.formatRow) {
                    Text(book.format.displayName)
                }
                // Keep on All Devices (FR43), only while sync is on. It acts
                // at once, as the menu command does, not with Save.
                if cloudStates.syncIsOn {
                    Toggle(SyncWording.keptState, isOn: Binding(
                        get: { keptBooks.isKeptOnAllDevices(book.id) },
                        set: { // VoiceOver reads the checkbox's new value: no announcement besides.
                        LibraryCloudCommands.shared.setKeptOnAllDevices($0, [book], from: nil, announcing: false) }
                    ))
                    .accessibilityHint(SyncWording.keepHint)
                    // Remove Download for a book whole on this device (FR46), as a row's menu offers it.
                    SyncRemoveDownloadRow(book: book, library: libraryViewModel)
                }
                // A braille book names its code (FMT21) and offers others:
                // VoiceOver reads "Unified English Braille, contracted
                // (Grade 2), Braille Code, pop-up button". A braille book
                // that offers no choice (a feed's item) keeps the plain row,
                // which VoiceOver reads as "Braille Code, Unified English
                // Braille, contracted (Grade 2)".
                if book.offersBrailleTableChoice {
                    BookRereadPopUp(model: brailleCode, label: BrailleCodeWording.bookInfoLabel, hint: BrailleCodeWording.popUpHint)
                    // A book read as UEB whose braille is English Braille,
                    // American Edition's: say so, in words VoiceOver reads
                    // as the next item after the pop-up. The table is never
                    // changed by itself.
                    if let suggestion = brailleCode.suggestion {
                        Text(suggestion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // A guessed code says where it came from and how to
                    // correct or keep it, as the next item after the pop-up.
                    if let guessNote = brailleCode.guessNote {
                        Text(guessNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // A menu pop-up gives no choice for the item already
                        // selected, so keeping the guess is a button.
                        Button(BrailleCodeWording.keepGuessLabel) { brailleCode.keepGuessedTable() }
                            .accessibilityHint(BrailleCodeWording.keepGuessHint)
                            .disabled(!brailleCode.isEnabled)
                    }
                } else if let row = book.bookInfoBrailleCodeRow {
                    LabeledContent(row.label) {
                        Text(row.value)
                    }
                }
                // A BRF or BRL braille book names the braille file characters
                // its file is read with, and offers others (braillecodes):
                // VoiceOver reads "North American Braille ASCII, Braille File
                // Characters, pop-up button".
                if book.offersBrailleFileCodeChoice {
                    BookRereadPopUp(model: fileCode, label: BrailleFileCodeWording.bookInfoLabel, hint: BrailleFileCodeWording.popUpHint)
                }
                // A text book from the listener's own file names the encoding
                // its file is read in, and offers another (FMT16,
                // encodingchoice): VoiceOver reads "Windows-1251 (Cyrillic),
                // guessed, Text Encoding, pop-up button".
                if book.offersTextEncodingChoice {
                    BookRereadPopUp(model: encoding, label: TextEncodingWording.bookInfoLabel, hint: TextEncodingWording.popUpHint)
                }
                LabeledContent(LibrarySheetWording.addedRow) {
                    Text(book.dateAdded, style: .date)
                }
                if let lastOpened = book.lastOpened {
                    LabeledContent(LibrarySheetWording.lastOpenedRow) {
                        Text(lastOpened, style: .date)
                    }
                }
                if let words = book.totalWordCount {
                    LabeledContent(LibrarySheetWording.wordCountRow) {
                        Text(words.interfaceFormatted())
                    }
                }
            }

            // Why the last choice of an encoding, or of braille file
            // characters, or of a braille code, changed nothing, and the
            // re-read under way (encodingchoice, braillecodes). Only the
            // pop-up that was used last has a message to show, its own: a
            // new choice or re-read in either braille pop-up clears the
            // other's older one.
            OperationFailureNotice(message: rereadFailureMessage)
            if isReadingAgain {
                SheetWorkIndicator(label: TextEncodingWording.workingLabel)
            }

            HStack {
                Button(LibraryWindowWording.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                // The sheet stays open until a re-read in another encoding,
                // or with other braille file characters, ends.
                .disabled(isReadingAgain)

                Spacer()

                Button(LibraryWindowWording.save) {
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
                .disabled(isReadingAgain || Self.edit(from: opened, title: title, author: author) == nil)
            }
        }
        .padding()
        // Taller with either re-read pop-up, the Text Encoding or the Braille
        // File Characters one, and room for a refusal of a few lines below
        // the form.
        .frame(width: 400, height: (offersRereadChoice ? 470 : 350) + (cloudStates.syncIsOn ? 90 : 0))
        .navigationTitle(LibrarySheetWording.infoTitle(book.title))
        .task {
            // What the file is read in, worked out off the main actor, so the
            // sheet never waits on a large file; and the braille file
            // characters the book's record keeps, which stand over a row
            // that lags behind a re-read; and the braille tables this Mac
            // offers, whose headers take a moment to read.
            if book.offersTextEncodingChoice {
                await encoding.load()
            }
            if book.offersBrailleFileCodeChoice {
                await fileCode.load()
            }
            if book.offersBrailleTableChoice {
                await brailleCode.load()
            }
        }
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

// MARK: - Re-read Pop-ups (encodingchoice, braillecodes)

/// One of Book Information's rows that names what a book's file is read
/// with and reads it again with another choice: a pop-up button of
/// `model`'s items, with what the book is read with now selected and named,
/// so the button shows, and VoiceOver reads, the value before `label`:
/// "Windows-1251 (Cyrillic), guessed, Text Encoding, pop-up button"
/// (`TextEncodingChoiceModel.name(of:)`), or "North American Braille ASCII,
/// Braille File Characters, pop-up button"
/// (`BrailleFileCodeChoiceModel.name(of:)`). Choosing another item asks
/// first, in the alert this view carries, so each pop-up's alert hangs on
/// its own view and no view carries two; the pop-up is dimmed while its
/// model takes no choice (`BookRereadChoosing.isEnabled`), as while the
/// book is read again.
struct BookRereadPopUp<Model: BookRereadChoosing>: View {
    /// What the pop-up lists, the choice, and the re-read.
    @ObservedObject var model: Model
    /// The pop-up's label, which VoiceOver speaks after its value.
    let label: String
    /// The pop-up's hint, which VoiceOver speaks after its label.
    let hint: String

    var body: some View {
        Picker(
            label,
            selection: Binding(get: { model.selection }, set: { item in Task { await model.choose(item) } })
        ) {
            ForEach(model.items, id: \.self) { item in
                Text(model.name(of: item)).tag(item)
            }
        }
        .pickerStyle(.menu)
        // The label is spoken from the control itself: a pop-up button takes
        // no label from the picker's title.
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .disabled(!model.isEnabled)
        // The confirmation asked before the book is read again with the
        // choice: its title names the book and the choice ("Read “Ledger”
        // again as Shift JIS (Japanese)?"), its message says what changes
        // (an edit of the text kept, and Edit Text stopping, included), Read
        // Again (Return) reads it again, and Cancel (Escape) leaves
        // everything, the pop-up included, as it was.
        .alert(
            model.pending.map { model.confirmTitle(for: $0.option) } ?? "",
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } }),
            presenting: model.pending
        ) { confirmation in
            Button(TextEncodingWording.confirmButton) {
                Task { await model.confirm(confirmation.option) }
            }
            Button(LibraryWindowWording.cancel, role: .cancel) {
                model.cancel()
            }
        } message: { confirmation in
            Text(model.confirmMessage(for: confirmation))
        }
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
        // Translators: What VoiceOver reads for the reason an operation failed in a sheet: the word Error, then the reason. %@ is the reason.
        InterfaceText.line("common.errorValue", "Error: \(message)")
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

    /// What VoiceOver hears once the sheet has closed on a folder made: the
    /// new folder's `name` and the place it is in, as in "Folder Q3 created
    /// in Reports.", or "Folder Q3 created in Library Root." at the top
    /// level (`parentPath` is "" there). The sheet and the Create button
    /// the focus was on are gone by then, so the window says it.
    nonisolated static func createdAnnouncement(name: String, parentPath: String) -> String {
        let place = parentPath.isEmpty ? LibraryFolderOption.rootLabel : parentPath
        // Translators: VoiceOver announcement once the New Folder sheet has closed on a folder made. %1$@ is the new folder's name. %2$@ is the place it is in: its parent folder's path, or the name of the library's top level.
        return InterfaceText.line("newFolderSheet.createdAnnouncement", "Folder \(name) created in \(place).")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(LibrarySheetWording.newFolderTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField(LibrarySheetWording.folderNameField, text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(LibrarySheetWording.folderNameField)

            Picker(LibrarySheetWording.parentFolder, selection: $parentPath) {
                Text(LibraryFolderOption.rootLabel).tag("")
                ForEach(folders.sortedTreeOrder()) { folder in
                    if folder.depth < BookFolder.maxDepth {
                        Text(folder.fullPath).tag(folder.fullPath)
                    }
                }
            }
            .accessibilityLabel(LibrarySheetWording.parentFolder)

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button(LibraryWindowWording.cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(LibrarySheetWording.create) {
                    failureMessage = OperationFailureNotice.message(after: onCreate())
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(BookFolder.normalizedName(folderName) == nil)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle(LibrarySheetWording.newFolderTitle)
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
    nonisolated static var rootLabel: String { FolderOperationConflict.libraryRootName }

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
/// While the fields are shown, Return presses their Create and Escape their
/// Cancel New Folder, which closes them, saying so, before a second Escape
/// closes the sheet; an owner with a Return-key or Escape button of its own
/// withdraws that shortcut meanwhile, following `isMakingFolder`, so one
/// press does one thing, and Create gives Return up while the owner hands it
/// to a button of its own (`createTakesReturn`), so one button at a time is
/// the default.
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
    /// kept current by the picker, so a Return-key or Escape button of the
    /// owner's can stand down while they are; its first value says whether
    /// the fields start shown. Nil for an owner with no such button.
    let isMakingFolder: Binding<Bool>?
    /// Whether the fields' Create takes Return while they are shown: true,
    /// unless the owner gives the key to a button of its own for now, as Add
    /// Feed gives it to Search while the Search field has the keyboard, so
    /// one button at a time is the default button and draws as one.
    let createTakesReturn: Bool

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
    nonisolated static var cancelNewFolderTitle: String {
        // Translators: Title of the button, in a folder chooser, that closes the new folder's fields without making a folder. It is not named Cancel, so VoiceOver tells it apart from the sheet's own Cancel.
        InterfaceText.line("libraryFolderPicker.cancelNewFolderTitle", "Cancel New Folder")
    }
    /// What that button does, for VoiceOver: the fields close, and the
    /// folder chosen in the pop-up stays chosen.
    nonisolated static var cancelNewFolderHint: String {
        // Translators: Hint of the button, in a folder chooser, that closes the new folder's fields: the folder chosen in the pop-up stays chosen.
        InterfaceText.line("libraryFolderPicker.cancelNewFolderHint", "Closes the new folder's fields and keeps the folder chosen.")
    }

    /// What VoiceOver hears as the new folder's fields close without a
    /// folder made, by Escape or Cancel New Folder: that New Folder was
    /// cancelled, then the pop-up by its spoken label with the place still
    /// chosen in it, as in "New Folder cancelled. Destination folder:
    /// Reports."; the cancel alone when no place offered is chosen.
    nonisolated static func newFolderCancelledAnnouncement(pickerLabel: String, chosen: String?) -> String {
        guard let chosen else {
            // Translators: VoiceOver announcement when the new folder's fields close without a folder made, and no place is chosen in the pop-up.
            return InterfaceText.line("libraryFolderPicker.newFolderCancelled.alone", "New Folder cancelled.")
        }
        // Translators: VoiceOver announcement when the new folder's fields close without a folder made. %1$@ is the pop-up's spoken label, such as Destination folder. %2$@ is the place still chosen in it.
        return InterfaceText.line("libraryFolderPicker.newFolderCancelled.detail", "New Folder cancelled. \(pickerLabel): \(chosen).")
    }

    /// What VoiceOver hears as a folder is made with the fields' Create: the
    /// new folder's `name`, then the pop-up by its spoken label with the new
    /// folder chosen in it, as in "Folder Q3 created. Destination folder:
    /// Reports/Q3." `chosen` is the folder as the pop-up labels it, by its
    /// full path. Without it the focus, on the Create button that goes away
    /// with the fields, would land nowhere and VoiceOver would say nothing.
    nonisolated static func newFolderCreatedAnnouncement(name: String, pickerLabel: String, chosen: String) -> String {
        // Translators: VoiceOver announcement when a folder is made with the new folder's fields. %1$@ is the new folder's name. %2$@ is the pop-up's spoken label, such as Destination folder. %3$@ is the new folder's full path, now chosen in the pop-up.
        InterfaceText.line("libraryFolderPicker.newFolderCreatedAnnouncement", "Folder \(name) created. \(pickerLabel): \(chosen).")
    }

    /// The picker with its pop-up's `options`, the `newFolderParents` a new
    /// folder may go in, and the `selection` it keeps; `isDisabled`,
    /// `isMakingFolder`, and `createTakesReturn` are for the owners that
    /// need them.
    init(
        options: [LibraryFolderOption],
        newFolderParents: [LibraryFolderOption],
        selection: Binding<String>,
        caption: String,
        accessibilityLabel: String,
        onCreateFolder: @escaping (String, String) -> OperationOutcome,
        failureMessage: Binding<String?>,
        isDisabled: Bool = false,
        isMakingFolder: Binding<Bool>? = nil,
        createTakesReturn: Bool = true
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
        self.createTakesReturn = createTakesReturn
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
                    Button(LibrarySheetWording.newFolderButton) {
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
        GroupBox(LibrarySheetWording.newFolderTitle) {
            VStack(spacing: 8) {
                TextField(LibrarySheetWording.folderNameField, text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .accessibilityLabel(LibrarySheetWording.newFolderNameLabel)

                Picker(LibrarySheetWording.parentFolder, selection: $newFolderParent) {
                    ForEach(newFolderParents, id: \.path) { option in
                        Text(option.label).tag(option.path)
                    }
                }
                .accessibilityLabel(LibrarySheetWording.parentFolderForNewFolder)

                HStack {
                    // Named apart from the sheet's own Cancel, which closes
                    // the whole sheet, so VoiceOver never meets two Cancels
                    // with different jobs. Escape presses it while the
                    // fields are shown, closing them before the sheet: an
                    // owner's own Escape button stands down meanwhile
                    // (`isMakingFolder`), and one that doesn't comes after
                    // the picker, and the first button in view order with
                    // a key takes it.
                    Button(Self.cancelNewFolderTitle, action: cancelNewFolder)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint(Self.cancelNewFolderHint)
                    Spacer()
                    // Return presses Create while the fields are shown; the
                    // owner's Return-key button stands down meanwhile
                    // (`isMakingFolder`), so one press does one thing, and
                    // Create stands down while the owner gives the key to
                    // a button of its own (`createTakesReturn`), so one
                    // button at a time is the default.
                    Button(LibrarySheetWording.create, action: createFolder)
                        .keyboardShortcut(createTakesReturn ? KeyboardShortcut.defaultAction : nil)
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

    /// Closes the new folder's fields without making a folder, by Escape or
    /// Cancel New Folder: the name typed goes, the place chosen stays, and
    /// VoiceOver hears both (`newFolderCancelledAnnouncement`), since the
    /// field it was on goes away with the fields.
    private func cancelNewFolder() {
        newFolderName = ""
        showNewFolder = false
        VoiceOverAnnouncer.announce(Self.newFolderCancelledAnnouncement(
            pickerLabel: accessibilityLabel,
            chosen: options.first { $0.path == selection }?.label
        ))
    }

    /// Makes the folder named in the fields, and chooses it once it is made.
    private func createFolder() {
        guard let name = BookFolder.normalizedName(newFolderName) else { return }
        failureMessage = OperationFailureNotice.message(after: onCreateFolder(name, newFolderParent))
        // A refused or failed folder keeps the fields open with the name,
        // beside the reason.
        guard failureMessage == nil else { return }
        let createdPath = newFolderParent.isEmpty ? name : "\(newFolderParent)/\(name)"
        selection = createdPath
        newFolderName = ""
        showNewFolder = false
        // Said at once: the sheet stays open, so nothing cuts the words off.
        VoiceOverAnnouncer.announce(Self.newFolderCreatedAnnouncement(
            name: name,
            pickerLabel: accessibilityLabel,
            chosen: createdPath
        ))
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
    /// What moving does, shown under the heading, where VoiceOver reads it
    /// in order after the heading, as Move to Library… says it (FR11,
    /// branch D); nil for none. The Move button gives no hint repeating it
    /// (REV13 feeds 8).
    let explanation: String?

    /// The folder path currently selected in the picker
    @State private var selectedPath: String = ""
    /// Why the last Move or Create failed, until the user changes an input.
    @State private var failureMessage: String?
    /// Whether the books are moving now.
    @State private var isWorking = false
    /// Whether the picker's new-folder fields are showing, while Return
    /// presses their Create rather than Move, and Escape closes them rather
    /// than the sheet.
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
            return LibrarySheetWording.moveTitle(bookTitle: book.title)
        }
        return LibrarySheetWording.moveTitle(count: books.count)
    }

    /// All available destination paths, including "Library Root" (empty string)
    private var folderOptions: [LibraryFolderOption] {
        LibraryFolderOption.options(in: library)
    }

    var body: some View {
        let _ = ViewBodyCounter.record("MoveFolderSheet")
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
                caption: LibrarySheetWording.destinationCaption,
                accessibilityLabel: LibrarySheetWording.destinationFolderLabel,
                onCreateFolder: onCreateFolder,
                failureMessage: $failureMessage,
                isDisabled: isWorking,
                isMakingFolder: $isMakingFolder
            )

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: LibrarySheetWording.movingBooks(count: books.count))
            }

            HStack {
                Button(LibraryWindowWording.cancel, action: onCancel)
                    // Escape closes the sheet, except while the new
                    // folder's fields are shown, when it closes them first
                    // (their Cancel New Folder) and a second Escape closes
                    // the sheet.
                    .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut(.escape, modifiers: []))

                Spacer()

                // No hint: the explanation, read in order after the
                // heading, already says what moving does, and a hint would
                // say it a second time (REV13 feeds 8).
                Button(LibrarySheetWording.move) {
                    OperationFailureNotice.run(
                        { await onMove(selectedPath) },
                        isWorking: $isWorking,
                        failureMessage: $failureMessage
                    )
                }
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
            // Say in the debug log what the sheet shows as it appears, so a
            // report of an empty sheet can be checked against the log. Only
            // counts: never a title or a path.
            DiagnosticLog.event(.app, Self.shownLine(
                command: heading == nil ? "Move to Folder" : "Move to Library", // l10n: no (log-only: the debug log's wording)
                places: folderOptions.count,
                items: books.count
            ))
            // Default to last moved folder if it still exists, otherwise Library Root
            if !lastMovedFolderPath.isEmpty,
               folderOptions.contains(where: { $0.path == lastMovedFolderPath }) {
                selectedPath = lastMovedFolderPath
            }
        }
    }

    /// The debug log's line for a sheet appearing: which command opened it,
    /// how many places it lists, and how many items it moves. Counts only,
    /// so the line holds no title or path.
    nonisolated static func shownLine(command: String, places: Int, items: Int) -> String {
        "MOVE_SHEET_SHOWN: \(command) lists \(places) place(s) for \(items) item(s)"
    }
}

// MARK: - Move to Folder's Presentation

/// What Move to Folder… moves while its sheet shows: the books of a row's
/// command, the edit bar's Move, or Command-Shift-M. The sheet is handed
/// this request, so its content comes from it and never from the owner's
/// state captured when the owner's body last ran, which left the sheet
/// empty for VoiceOver on a first presentation.
struct MoveToFolderRequest: Identifiable, Equatable {
    /// Tells two requests apart, so a second Move opens a sheet of its own.
    let id = UUID()
    /// The books that move, as the library held them.
    let books: [Book]
}

/// Shows Move to Folder…'s sheet while `request` names what moves. A
/// modifier of its own, so the Library window's long chain of modifiers
/// stays within what the type checker takes, and so a test can host the
/// presentation without the window.
struct MoveToFolderSheetPresentation: ViewModifier {
    /// What moves while the sheet shows; nil closes it.
    @Binding var request: MoveToFolderRequest?
    /// The library the books move in.
    let library: LibraryViewModel
    /// Moves the request's books into the folder at the path, answering what
    /// happened; the owner closes the sheet after a success.
    let onMove: @MainActor (MoveToFolderRequest, String) async -> OperationOutcome
    /// Runs once the sheet has closed, as the owner says what the move left.
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        // The sheet's content comes only from the request `sheet(item:)`
        // hands the closure, never from state captured when this body last
        // ran, so it is never built empty.
        content.sheet(item: $request, onDismiss: onDismiss) { request in
            MoveFolderSheet(
                books: request.books,
                library: library.library,
                lastMovedFolderPath: library.lastMovedFolderPath,
                onMove: { path in await onMove(request, path) },
                onCreateFolder: { library.createFolderReturningOutcome(name: $0, parentPath: $1) },
                onCancel: { self.request = nil }
            )
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
            Text(LibrarySheetWording.renameFolderTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField(LibrarySheetWording.folderNameField, text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(LibrarySheetWording.newFolderNameLabel)
                .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: LibrarySheetWording.renamingTheFolder)
            }

            HStack {
                Button(LibraryWindowWording.cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(LibrarySheetWording.rename) {
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
        .navigationTitle(LibrarySheetWording.renameFolderTitle)
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
        var options: [(String, String)] = [(LibraryFolderOption.rootLabel, "")]
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
            Text(LibrarySheetWording.moveTitle(folderName: folder.name))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker(LibrarySheetWording.newParentFolder, selection: $selectedParent) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel(LibrarySheetWording.destinationParentFolder)
            .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: LibrarySheetWording.movingTheFolder)
            }

            HStack {
                Button(LibraryWindowWording.cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(LibrarySheetWording.move) {
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
        .navigationTitle(LibrarySheetWording.moveFolderNavigationTitle(folder.name))
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
        var options: [(String, String)] = [(LibraryFolderOption.rootLabel, "")]
        for f in library.folders.sortedTreeOrder() {
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(LibrarySheetWording.moveContentsTitle(folder.name))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(LibrarySheetWording.moveContentsExplanation(folder.name))
                .font(.callout)
                .foregroundColor(.secondary)

            Picker(LibrarySheetWording.moveContentsTo, selection: $selectedDestination) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel(LibrarySheetWording.destinationForContents)
            .disabled(isWorking)

            OperationFailureNotice(message: failureMessage)

            if isWorking {
                SheetWorkIndicator(label: LibrarySheetWording.movingTheFoldersContents)
            }

            HStack {
                Button(LibraryWindowWording.cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(LibrarySheetWording.moveContentsAndDelete) {
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
        .navigationTitle(LibrarySheetWording.moveContentsNavigationTitle(folder.name))
        .clearingFailure($failureMessage, whenChanged: selectedDestination)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            // Default to the parent of the folder being deleted
            selectedDestination = folder.parentPath
        }
    }
}
