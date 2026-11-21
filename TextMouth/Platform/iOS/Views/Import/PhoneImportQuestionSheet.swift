import SwiftUI

/// The import question an import waits on, rebuilt for the phone (the spec's
/// "Import questions"): the Mac's title in the navigation bar, the Mac's
/// question, where focus lands, the folder name field for a ZIP archive's
/// books, then the Mac's choices as a vertical list, each with its hint.
///
/// It can't be swiped away: only an answer settles it, and its Cancel is the
/// question's own (`interactiveDismissDisabled`). What it shows is decided by
/// `PhoneImportQuestion`; this view only lays it out and passes the answer.
///
/// An answer can take a while (Replace Existing reads a long braille book
/// again, off the main actor): the choices are dimmed until it is done, so
/// none is given twice, and a spinner beside "Replacing ..." shows that the
/// sheet is working.
struct PhoneImportQuestionSheet: View {
    /// What the sheet shows.
    let question: PhoneImportQuestion
    /// Answers the question, off the main actor where that takes long, and
    /// says what happened.
    let onAnswer: @MainActor (ImportDecisionAnswer) async -> OperationOutcome

    /// The folder name field's text, at first the archive's name.
    @State private var folderName: String
    /// Why the last answer failed, shown above the choices.
    @State private var failureMessage: String?
    /// Whether an answer is being carried out: the choices are dimmed until
    /// it is done.
    @State private var isAnswering = false
    /// What the sheet says while the answer is Replace Existing, the one
    /// answer that takes a while; nil for any other.
    @State private var workLabel: String?
    /// Whether VoiceOver's focus is on the question's text, where it lands.
    @AccessibilityFocusState private var isMessageFocused: Bool

    /// The sheet for `question`, answered through `onAnswer`.
    init(question: PhoneImportQuestion, onAnswer: @escaping @MainActor (ImportDecisionAnswer) async -> OperationOutcome) {
        self.question = question
        self.onAnswer = onAnswer
        _folderName = State(initialValue: question.suggestedFolderName ?? "")
    }

    /// Gives `answer` to the question: the choices are dimmed and the last
    /// failure cleared while it is carried out, then the failure it ends in,
    /// if any, is shown and spoken (`OperationFailureNotice.run`).
    private func give(_ answer: ImportDecisionAnswer) {
        guard !isAnswering else { return }
        workLabel = answer == .replaceExisting
            ? question.duplicateTitle.map { DuplicateCopyWording.replacing(bookTitle: $0) }
            : nil
        let onAnswer = onAnswer
        OperationFailureNotice.run({ await onAnswer(answer) }, isWorking: $isAnswering, failureMessage: $failureMessage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(question.message)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($isMessageFocused)
                }
                if question.suggestedFolderName != nil {
                    Section {
                        TextField(ImportDecisionChoiceWording.folderNameLabel, text: $folderName)
                            .accessibilityLabel(ImportDecisionChoiceWording.folderNameLabel)
                    }
                }
                Section {
                    OperationFailureNotice(message: failureMessage)
                    if isAnswering, let workLabel {
                        SheetWorkIndicator(label: workLabel)
                    }
                    ForEach(question.choices) { choice in
                        Button(choice.words.title) {
                            give(choice.answer(folderName: folderName))
                        }
                        .disabled(isAnswering || !question.isEnabled(choice, folderName: folderName))
                        .accessibilityLabel(choice.words.title)
                        .accessibilityHint(choice.words.hint)
                    }
                }
            }
            .navigationTitle(question.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
        // A failure is for the name it was given: a new name clears it.
        .onChange(of: folderName) { failureMessage = nil }
        .task(id: question.decisionID) {
            // A moment for the sheet to slide in, then VoiceOver reads the
            // question itself rather than the sheet's first element.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isMessageFocused = true
        }
    }
}
