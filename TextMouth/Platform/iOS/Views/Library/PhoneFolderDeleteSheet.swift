import SwiftUI

/// Delete Folder's question, rebuilt for the phone from the Mac's alert and
/// its Move Contents sheet (the spec, "Folder sheets"): the Mac's words, then
/// its two choices, each a full-width row.
///
/// - Move Contents Out pushes the Move Contents screen, the Mac's sheet of
///   that name, inside this sheet, where Back returns to the question.
/// - Delete Everything Permanently asks the Mac's second question, as an
///   alert, before the folder and everything in it go.
///
/// VoiceOver's order: the title "Delete Folder?" (a heading), Cancel (the bar's
/// buttons are trailing, `PhoneSheetButton`), the question's text, Move
/// Contents Out, then Delete Everything Permanently.
/// Focus lands on the question's text, as on the phone's import question.
///
/// Nothing here has run on iOS: where focus lands, and where it returns as
/// the alert closes, are on the hand-check list.
struct PhoneFolderDeleteQuestion: View {
    /// What the question shows and does.
    @ObservedObject var model: PhoneFolderSheetModel
    /// Closes the sheet: with what was done after a success, or nil.
    let finish: @MainActor (PhoneFolderSheetResult?) -> Void

    /// Whether the Move Contents screen is pushed.
    @State private var isMovingContents = false
    /// Whether Delete Everything's own question is showing.
    @State private var isConfirmingDeleteEverything = false
    /// Whether VoiceOver's focus is asked onto the question's text.
    @AccessibilityFocusState private var isQuestionFocused: Bool

    var body: some View {
        let wording = model.deleteWording
        Form {
            Section {
                Text(wording?.choiceMessage ?? "")
                    .accessibilityFocused($isQuestionFocused)
            }
            Section {
                Button(PhoneFolderVocabulary.moveContentsOut) {
                    isMovingContents = true
                }
                Button(wording?.buttonTitle ?? "", role: .destructive) {
                    isConfirmingDeleteEverything = true
                }
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            PhoneSheetButton(title: PhoneAppWording.cancel) {
                finish(nil)
            }
        }
        // The Mac's Move Contents sheet, as a screen of this sheet's own.
        .navigationDestination(isPresented: $isMovingContents) {
            PhoneFolderSheetForm(
                model: model,
                title: model.moveContentsTitle ?? model.title,
                explanation: model.moveContentsExplanation,
                showsCancel: false,
                finish: finish
            )
        }
        // The Mac's second question before Delete Everything. The sheet closes
        // after it either way, as the Mac's question does; whatever couldn't
        // be deleted, the library's alert names.
        .alert(wording?.confirmationTitle ?? "", isPresented: $isConfirmingDeleteEverything) {
            Button(wording?.buttonTitle ?? "", role: .destructive) {
                finish(model.deleteEverything())
            }
            Button(PhoneAppWording.cancel, role: .cancel) {}
        } message: {
            Text(wording?.confirmationMessage ?? "")
        }
        .task {
            await focusQuestion()
        }
    }

    /// Lands VoiceOver's focus on the question's text once the sheet has
    /// settled (`PhoneListFocus.settleDelay`), so the question is heard
    /// before its choices. It's the form's first row, always made.
    private func focusQuestion() async {
        try? await Task.sleep(for: .seconds(PhoneListFocus.settleDelay))
        isQuestionFocused = false
        await Task.yield()
        isQuestionFocused = true
    }
}
