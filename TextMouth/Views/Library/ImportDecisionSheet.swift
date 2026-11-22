import SwiftUI

// MARK: - The Sheet

/// One import question, as a Library window asks it (TODO I01): a heading
/// with the question's title and its place among the questions waiting, as
/// in "Duplicate Book Found, 1 of 3"; what it asks; then its choices, the
/// one that removes nothing first, each with an explicit label and a hint.
///
/// Whenever a question appears, the next one in a sheet already open
/// included, keyboard focus and VoiceOver move to its first control, and
/// VoiceOver then announces the question, so it is heard in full however the
/// user answered the one before. A question that appears while the user is
/// in another window moves neither, and is not announced
/// (`ImportDecisionPresenter.userIsIn(_:)`). Return and Escape choose the
/// marked choices; deleting a file is never on a key. An answer that fails
/// leaves the question showing, with the reason.
///
/// An answer can take a while (Replace Existing reads a long braille book
/// again, off the main actor): while it runs the choices are dimmed, so it
/// cannot be given twice, a spinner beside the words "Replacing ..." shows
/// that the sheet is working, and VoiceOver is told once if it is still
/// working after a moment (`announcementDelay`).
struct ImportDecisionSheet: View {
    /// The question asked.
    let decision: ImportDecision
    /// Its words, shared with VoiceOver's announcement.
    let wording: ImportDecisionWording
    /// How long VoiceOver waits before moving to the first control
    /// (`voiceOverFocusDelay(position:)`).
    let voiceOverDelay: TimeInterval
    /// Answers the question, off the main actor where that takes long, and
    /// says what happened.
    let onAnswer: @MainActor (ImportDecisionAnswer) async -> OperationOutcome
    /// Asks VoiceOver to speak the question. The app announces through
    /// `VoiceOverAnnouncer`; tests record instead.
    let announce: @MainActor (String) -> Void

    /// Whether the question takes focus and is announced: the user was in
    /// its window as it appeared. Kept for the question's life, so the
    /// library's periodic redraws never move focus again later.
    @State private var takesFocus: Bool
    /// Why the last answer failed, until the folder name changes.
    @State private var failureMessage: String?
    /// Whether an answer is being carried out: the choices are dimmed until
    /// it is done.
    @State private var isAnswering = false
    /// What the sheet says it is doing while the answer to a duplicate's
    /// question is Replace Existing, the one answer that takes a while; nil
    /// for any other, which is done at once.
    @State private var workLabel: String?
    /// The name of a ZIP archive's new folder, at first the archive's name.
    @State private var folderName: String
    /// Whether the first control has keyboard focus.
    @FocusState private var firstControlFocused: Bool

    /// The sheet for `decision`, whose words are `wording`. `onAnswer`
    /// answers it, and `announce` speaks it when it `takesFocus`.
    init(
        decision: ImportDecision,
        wording: ImportDecisionWording,
        voiceOverDelay: TimeInterval,
        takesFocus: Bool = true,
        onAnswer: @escaping @MainActor (ImportDecisionAnswer) async -> OperationOutcome,
        announce: @escaping @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        self.decision = decision
        self.wording = wording
        self.voiceOverDelay = voiceOverDelay
        self.onAnswer = onAnswer
        self.announce = announce
        _takesFocus = State(initialValue: takesFocus)
        var suggestedName = ""
        if case .zipFolder(let batch) = decision.kind {
            suggestedName = batch.suggestedFolderName
        }
        _folderName = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(wording.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(wording.message)
                .fixedSize(horizontal: false, vertical: true)
            choices
                // The choices are dimmed while an answer is carried out, so
                // none is given twice.
                .disabled(isAnswering)
            if isAnswering, let workLabel {
                SheetWorkIndicator(label: workLabel)
            }
        }
        .padding(20)
        .frame(width: 460)
        .clearingFailure($failureMessage, whenChanged: folderName)
        .task { await presentQuestion() }
    }

    /// The question's controls, the first of them marked for focus.
    @ViewBuilder
    private var choices: some View {
        switch decision.kind {
        case .duplicate:
            OperationFailureNotice(message: failureMessage)
            HStack {
                choiceButton(.keepBoth, shortcut: .defaultAction, answer: .keepBoth)
                    .firstQuestionControl($firstControlFocused, movingVoiceOver: takesFocus, after: voiceOverDelay)
                choiceButton(.replaceExisting(acrossKinds: wording.replacesAcrossKinds), answer: .replaceExisting)
                Spacer()
                choiceButton(.cancelDuplicate, shortcut: .cancelAction, answer: .cancel)
            }
        case .originalFile:
            OperationFailureNotice(message: failureMessage)
            HStack {
                choiceButton(.keepOriginal, shortcut: .cancelAction, answer: .cancel)
                    .firstQuestionControl($firstControlFocused, movingVoiceOver: takesFocus, after: voiceOverDelay)
                Spacer()
                if let deletion = wording.originalFile {
                    choiceButton(.deleteOriginal(deletion), role: .destructive, answer: .deleteOriginal)
                }
            }
        case .zipFolder:
            TextField(ImportDecisionChoiceWording.folderNameLabel, text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(ImportDecisionChoiceWording.folderNameLabel)
                .firstQuestionControl($firstControlFocused, movingVoiceOver: takesFocus, after: voiceOverDelay)
            OperationFailureNotice(message: failureMessage)
            HStack {
                choiceButton(.createFolder, shortcut: .defaultAction, answer: .createFolder(named: folderName))
                    .disabled(BookFolder.normalizedName(folderName) == nil)
                Spacer()
                choiceButton(.declineFolder, shortcut: .cancelAction, answer: .cancel)
            }
        case .transcriptionOffer:
            OperationFailureNotice(message: failureMessage)
            HStack {
                choiceButton(.transcribe, shortcut: .defaultAction, answer: .transcribe)
                    .firstQuestionControl($firstControlFocused, movingVoiceOver: takesFocus, after: voiceOverDelay)
                Spacer()
                choiceButton(.notNow, shortcut: .cancelAction, answer: .cancel)
            }
        }
    }

    /// A choice's button, labelled and hinted by `words`, pressed with
    /// `shortcut` when it has one, giving `answer`.
    private func choiceButton(
        _ words: ImportDecisionChoiceWording,
        role: ButtonRole? = nil,
        shortcut: KeyboardShortcut? = nil,
        answer: ImportDecisionAnswer
    ) -> some View {
        Button(words.title, role: role) {
            give(answer)
        }
        .keyboardShortcut(shortcut)
        .accessibilityLabel(words.title)
        .accessibilityHint(words.hint)
    }

    /// Gives `answer` to the question: the choices are dimmed and the last
    /// failure cleared while it is carried out, then the failure it ends in,
    /// if any, is shown and spoken (`OperationFailureNotice.run`). An answer
    /// that takes a while, Replace Existing, says it is working, and tells
    /// VoiceOver once if it is still working after `announcementDelay`.
    private func give(_ answer: ImportDecisionAnswer) {
        guard !isAnswering else { return }
        workLabel = answer == .replaceExisting ? replacingWords : nil
        let onAnswer = onAnswer
        OperationFailureNotice.run({ await onAnswer(answer) }, isWorking: $isAnswering, failureMessage: $failureMessage)
        guard let words = workLabel else { return }
        let announce = announce
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.announcementDelay))
            if isAnswering {
                announce(words)
            }
        }
    }

    /// What the sheet says while Replace Existing works, naming the book.
    private var replacingWords: String? {
        guard case .duplicate(let duplicate) = decision.kind else { return nil }
        return DuplicateCopyWording.replacing(bookTitle: duplicate.book.title)
    }

    /// Gives the first control keyboard focus, then announces the question
    /// once VoiceOver has had time to move to that control too, so the
    /// announcement follows the control's name rather than being cut off by
    /// it. A question answered before then is not announced: its view is
    /// gone, which cancels this task. Nothing happens for a question that
    /// does not take focus.
    private func presentQuestion() async {
        guard takesFocus else { return }
        firstControlFocused = true
        try? await Task.sleep(for: .seconds(voiceOverDelay + Self.announcementLag))
        guard !Task.isCancelled else { return }
        announce(wording.announcement)
    }

    // MARK: Timing

    /// How long VoiceOver waits before moving to the first control of the
    /// question at `position` among those asked since none was waiting: as
    /// long as other sheets wait while the sheet slides in for the first,
    /// and less for a later question, which appears in a sheet already open.
    static func voiceOverFocusDelay(position: Int) -> TimeInterval {
        position == 1 ? 1.2 : 0.5
    }

    /// How long after VoiceOver's move the question is announced: time for
    /// VoiceOver to land on the control and say its name.
    static let announcementLag: TimeInterval = 0.8

    /// How long an answer may take before VoiceOver is told that the sheet is
    /// working: an answer done sooner is heard only as its result.
    static let announcementDelay: TimeInterval = 1.0
}

// MARK: - Choice Words

/// A choice's words in the import question sheet (TODO I01): its title,
/// which is also its explicit VoiceOver label, and a hint saying what it
/// does.
struct ImportDecisionChoiceWording: Equatable {
    /// The button's title and VoiceOver label.
    let title: String
    /// What choosing it does.
    let hint: String

    /// A duplicate: keep both copies.
    static var keepBoth: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button of the duplicate-book question that keeps both copies. Title case.
            title: InterfaceText.line("importDecisionChoice.keepBoth.title", "Keep Both"),
            // Translators: VoiceOver hint of the Keep Both button of the duplicate-book question.
            hint: InterfaceText.line("importDecisionChoice.keepBoth.separate", "Adds the new copy to the library as a separate book.")
        )
    }
    /// A duplicate: replace the library's copy. The hint says what the new
    /// copy keeps of the existing one (ST04): its reading position,
    /// bookmarks, and settings, which the question itself names in full.
    static var replaceExisting: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button of the duplicate-book question that replaces the copy in the library. Title case.
            title: InterfaceText.line("importDecisionChoice.replace", "Replace Existing"),
            // Translators: VoiceOver hint of the Replace Existing button of the duplicate-book question, when both copies are of one kind. "The existing copy" is the copy in the library.
            hint: InterfaceText.line("importDecisionChoice.replaceExisting", "Puts the new copy in place of the one already in the library, keeping the existing copy's reading position, bookmarks, and settings.")
        )
    }
    /// A duplicate whose copies are an audiobook and a book that is not:
    /// replacing keeps only the book's place in the library (ST04), and the
    /// hint promises no more.
    static var replaceExistingAcrossKinds: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button of the duplicate-book question that replaces the copy in the library. Title case.
            title: InterfaceText.line("importDecisionChoice.replace", "Replace Existing"),
            // Translators: VoiceOver hint of the Replace Existing button of the duplicate-book question, when one copy is an audiobook and the other is not. "The existing copy" is the copy in the library.
            hint: InterfaceText.line("importDecisionChoice.replaceExistingAcrossKinds", "Puts the new copy in place of the one already in the library, keeping only the existing copy's folder and place on the reading list.")
        )
    }

    /// Replace Existing's words for a duplicate whose copies differ in kind
    /// when `acrossKinds`, an audiobook and a book that is not.
    static func replaceExisting(acrossKinds: Bool) -> ImportDecisionChoiceWording {
        acrossKinds ? replaceExistingAcrossKinds : replaceExisting
    }
    /// A duplicate: discard the new copy.
    static var cancelDuplicate: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the Cancel button of the duplicate-book question.
            title: InterfaceText.line("common.cancel", "Cancel"),
            // Translators: VoiceOver hint of the Cancel button of the duplicate-book question.
            hint: InterfaceText.line("importDecisionChoice.cancelDuplicate", "Discards the new copy. The library stays as it was.")
        )
    }
    /// An original file: keep it.
    static var keepOriginal: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button that keeps the original file of a book just imported. Title case.
            title: InterfaceText.line("common.keep", "Keep"),
            // Translators: VoiceOver hint of the Keep button of the question about the original file.
            hint: InterfaceText.line("importDecisionChoice.keepOriginal", "Leaves the original file where it is.")
        )
    }
    /// An original file: delete it, to the Trash or permanently, as
    /// `deletion` says.
    static func deleteOriginal(_ deletion: OriginalFileDeletionWording) -> ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(title: deletion.buttonTitle, hint: deletion.consequence)
    }
    /// A ZIP archive's books: put them in a new folder.
    static var createFolder: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button that puts the books of a ZIP archive in a new folder. Title case.
            title: InterfaceText.line("importDecisionChoice.createFolder.title", "Create Folder"),
            // Translators: VoiceOver hint of the Create Folder button of the ZIP archive question. "This name" is the name in the folder name field.
            hint: InterfaceText.line("importDecisionChoice.createFolder.imported", "Moves the imported books into a new folder with this name.")
        )
    }
    /// A ZIP archive's books: leave them where they are.
    static var declineFolder: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            // Translators: Title and VoiceOver label of the button that leaves the books of a ZIP archive where they are. Title case.
            title: InterfaceText.line("importDecisionChoice.declineFolder.thanks", "No Thanks"),
            // Translators: VoiceOver hint of the No Thanks button of the ZIP archive question.
            hint: InterfaceText.line("importDecisionChoice.declineFolder.imported", "Leaves the imported books where they are.")
        )
    }
    /// The label of a ZIP archive's folder name field.
    static var folderNameLabel: String {
        // Translators: Label of the field where the name of the new folder for a ZIP archive's books is typed.
        InterfaceText.line("common.folderName", "Folder name")
    }
    /// An audiobook just imported: transcribe it (FR05).
    static var transcribe: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            title: TranscriptionWording.offerTranscribeTitle,
            hint: TranscriptionWording.offerTranscribeHint
        )
    }
    /// An audiobook just imported: leave it untranscribed for now.
    static var notNow: ImportDecisionChoiceWording {
        ImportDecisionChoiceWording(
            title: TranscriptionWording.offerNotNowTitle,
            hint: TranscriptionWording.offerNotNowHint
        )
    }
}

extension ImportDecision.ZipBatch {
    /// The name the sheet suggests for the archive's new folder: the
    /// archive's own name without its extension.
    var suggestedFolderName: String {
        archiveURL.deletingPathExtension().lastPathComponent
    }
}

private extension View {
    /// Marks the sheet's first control: keyboard focus goes to it when a
    /// question appears, and, when `movesVoiceOver`, VoiceOver moves to it
    /// after `delay`.
    func firstQuestionControl(
        _ focus: FocusState<Bool>.Binding,
        movingVoiceOver movesVoiceOver: Bool,
        after delay: TimeInterval
    ) -> some View {
        focused(focus)
            .modifier(InitialVoiceOverFocusModifier(isTarget: movesVoiceOver, delay: delay))
    }
}
