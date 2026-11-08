import SwiftUI

/// Which of a folder form's elements VoiceOver's focus is asked onto.
private enum PhoneFolderFormElement: Hashable, Sendable {
    /// The name field.
    case nameField
    /// The row choosing the folder.
    case folderRow
    /// Move to Folder's New Folder... row.
    case newFolderRow
}

/// The form every folder sheet shows, rebuilt for the phone from the Mac's
/// sheets (the spec, "Folder sheets"): a `Form` with the name field, the row
/// choosing the folder, and the failure and the work under it, with the
/// sheet's title, Cancel, and the confirm button in the navigation bar. It
/// holds no decision: `PhoneFolderSheetModel` makes each, so the Mac's test
/// host tests them.
///
/// VoiceOver's order: the title (a heading), Cancel, the confirm button (the
/// bar's buttons are trailing, `PhoneSheetButton`), then
/// the explanation, the name field, the folder row, Move to Folder's New
/// Folder..., and the failure. Focus
/// lands on the name field, which takes the keyboard, or else on the folder
/// row (`PhoneFolderSheetModel.arrival`).
///
/// Nothing here has run on iOS: where focus lands, that the name's selection
/// takes, and how the toolbar's long "Move Contents & Delete Folder" looks are
/// on the hand-check list.
struct PhoneFolderSheetForm: View {
    /// What the form shows and does.
    @ObservedObject var model: PhoneFolderSheetModel
    /// The screen's title, read as its heading.
    let title: String
    /// What the screen is for, read first in the form; nil for none.
    let explanation: String?
    /// Whether the navigation bar has Cancel: false on Delete Folder's Move
    /// Contents screen, which the system's Back button leaves for the
    /// question, whose own Cancel closes the sheet.
    let showsCancel: Bool
    /// Closes the sheet: with what was done after a success, or nil.
    let finish: @MainActor (PhoneFolderSheetResult?) -> Void

    /// Whether the name field has the keyboard.
    @FocusState private var nameHasKeyboard: Bool
    /// Where VoiceOver's focus is asked to go, on arrival and on return.
    @AccessibilityFocusState private var focus: PhoneFolderFormElement?
    /// The name field's selection, set once on arrival when the model asks.
    @State private var nameSelection: TextSelection?
    /// Whether the list of folders is showing.
    @State private var isChoosingFolder = false
    /// Whether Move to Folder's New Folder... sheet is showing.
    @State private var isMakingFolder = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if let explanation {
                    Section {
                        Text(explanation)
                    }
                }
                if let nameLabel = model.nameLabel {
                    Section {
                        nameField(label: nameLabel)
                    }
                }
                if let label = model.destinationLabel, let caption = model.destinationCaption {
                    Section {
                        folderRow(label: label, caption: caption)
                        if model.offersNewFolder {
                            newFolderRow(proxy: proxy)
                        }
                    }
                }
                // The failure sits under what it was about, as the Mac's
                // sheets show it; the work indicator says what is under way.
                if model.failureMessage != nil || model.isWorking {
                    Section {
                        OperationFailureNotice(message: model.failureMessage)
                        if model.isWorking, let workLabel = model.workLabel {
                            SheetWorkIndicator(label: workLabel)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarButtons }
            // The work can't be left halfway, as on the Mac.
            .interactiveDismissDisabled(model.isWorking)
            // Picking a folder is a list of the app's own, never a menu, which
            // wouldn't return focus (the spec, "Choices"). Focus comes back to
            // the folder row as the list closes, which reads its new value.
            .sheet(isPresented: $isChoosingFolder, onDismiss: {
                PhoneListFocus.focus(PhoneFolderFormElement.folderRow, proxy: proxy, state: $focus)
            }) {
                PhoneChoiceSheet(
                    title: model.destinationLabel ?? title,
                    choices: model.destinationChoices,
                    selected: model.destination
                ) { path in
                    model.destination = path
                }
            }
            .task {
                arrive(proxy: proxy)
            }
        }
    }

    /// The name field: the Mac's placeholder and spoken label. Return does the
    /// sheet's work, as the Mac's Return presses its default button.
    private func nameField(label: String) -> some View {
        TextField(PhoneFolderVocabulary.folderName, text: $model.name, selection: $nameSelection)
            .focused($nameHasKeyboard)
            .accessibilityLabel(label)
            .accessibilityFocused($focus, equals: .nameField)
            .submitLabel(.done)
            .onSubmit { confirm() }
            .disabled(model.isWorking)
            .id(PhoneFolderFormElement.nameField)
    }

    /// The row choosing the folder: the Mac's caption, with the folder chosen
    /// beside it; VoiceOver reads the Mac's spoken label and the folder as its
    /// value. It opens the list of folders.
    private func folderRow(label: String, caption: String) -> some View {
        Button {
            isChoosingFolder = true
        } label: {
            LabeledContent(caption, value: model.destinationValue)
        }
        .accessibilityLabel(label)
        .accessibilityValue(model.destinationValue)
        .accessibilityFocused($focus, equals: .folderRow)
        .disabled(model.isWorking)
        .id(PhoneFolderFormElement.folderRow)
    }

    /// Move to Folder's New Folder...: a sheet of its own making a folder,
    /// which becomes the destination once made, as the Mac's folder picker's
    /// fields make one. Focus comes back to this row as that sheet closes,
    /// and the sheet says what it made.
    private func newFolderRow(proxy: ScrollViewProxy) -> some View {
        Button(PhoneFolderVocabulary.newFolderButton) {
            isMakingFolder = true
        }
        .disabled(model.isWorking)
        .accessibilityFocused($focus, equals: .newFolderRow)
        .id(PhoneFolderFormElement.newFolderRow)
        // On this row rather than beside the folder list's sheet, so each
        // sheet has a view of its own to hang on.
        .sheet(isPresented: $isMakingFolder, onDismiss: {
            PhoneListFocus.focus(PhoneFolderFormElement.newFolderRow, proxy: proxy, state: $focus)
        }) {
            PhoneFolderSheet(model: model.newFolderModel()) { result in
                if case .createdFolder(let path) = result {
                    model.destination = path
                }
            }
        }
    }

    /// Cancel, where the screen has it, and the confirm button, each dimmed
    /// while the work is under way.
    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        if showsCancel {
            PhoneSheetButton(title: model.cancelTitle, hint: model.cancelHint ?? "", isEnabled: !model.isWorking) {
                finish(nil)
            }
        }
        PhoneSheetButton(title: model.confirmTitle, isEnabled: model.canConfirm, action: confirm)
    }

    /// Does the sheet's work, and closes the sheet once it has worked. After a
    /// failure the sheet stays, the model having said why.
    private func confirm() {
        Task {
            guard let result = await model.confirm() else { return }
            finish(result)
        }
    }

    /// Lands focus on what the sheet is for, once the sheet has settled
    /// (`PhoneListFocus`): the name field, which also takes the keyboard, with
    /// its name selected when the model asks, or else the folder row.
    private func arrive(proxy: ScrollViewProxy) {
        switch model.arrival {
        case .nameField:
            PhoneListFocus.focus(PhoneFolderFormElement.nameField, proxy: proxy, state: $focus)
            Task {
                try? await Task.sleep(for: .seconds(PhoneListFocus.settleDelay))
                nameHasKeyboard = true
                // A turn later, once the field holds the keyboard, so the
                // selection is the field's (unverified until a first run).
                await Task.yield()
                if model.selectsNameOnArrival {
                    nameSelection = TextSelection(range: model.name.startIndex..<model.name.endIndex)
                }
            }
        case .folderRow:
            PhoneListFocus.focus(PhoneFolderFormElement.folderRow, proxy: proxy, state: $focus)
        }
    }
}
