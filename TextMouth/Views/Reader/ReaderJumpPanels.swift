import SwiftUI

// The reader's Go to Percent and Go to Time panels, which the status row's
// percent and time buttons open below it (`BookInfoBar`), and the validator
// of what is typed into them.

// MARK: - Jump-To Panels

/// Reads what is typed into Go to Percent's and Go to Time's fields, and
/// says why it will not do, as a sentence the panel shows and announces.
enum JumpInputValidator {
    /// A percent through the book, or why not.
    enum PercentResult: Equatable {
        case value(Double)
        case error(String)
    }

    /// A time on the book's clock, or why not.
    enum TimeResult: Equatable {
        case value(TimeInterval)
        case error(String)
    }

    /// Go to Percent's field: a number from 0 to 100, spaces around it
    /// ignored.
    static func percent(_ raw: String) -> PercentResult {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .error("Enter a percent.") }
        guard let value = Double(trimmed) else { return .error("\"\(trimmed)\" is not a number.") }
        guard (0...100).contains(value) else {
            return .error("Percent must be between 0 and 100.")
        }
        return .value(value)
    }

    /// How far past the end of a book's clock a typed time still names its
    /// end: half the tenth of a second an audiobook's places are counted
    /// in, so a total shown in whole seconds, or a length whose chapters
    /// sum a hair short of it, is never refused.
    static let lengthTolerance: TimeInterval = 0.05

    /// Go to Time's field (P08): the time `raw` names, typed or pasted as
    /// people write a time (`TimeEntry`: "1:02:03", "62:03", "3723",
    /// "12:04.3"), when it is no later than `length`, the end of the clock
    /// the book's places count on (`PlaceClock.length`: an audiobook's
    /// recording, a text book's reading time at its words per minute),
    /// within `lengthTolerance`; a time within it is the end. Otherwise why
    /// not, `count` naming the clock in the refusal. Hours too many for an
    /// integer are refused as no time at all, never trapping.
    static func time(_ raw: String, length: TimeInterval, count: ReaderTimeWording.Count) -> TimeResult {
        switch TimeEntry.reading(raw) {
        case .problem(let sentence):
            return .error(sentence)
        case .seconds(let seconds):
            guard length.isFinite, seconds <= length + lengthTolerance else {
                return .error(ReaderTimeWording.pastTheEnd(length, count))
            }
            return .value(min(seconds, length))
        }
    }
}

/// What Jump, or Return, does with what a jump panel's field holds
/// (`JumpFieldPanel`): nothing at all while the field holds the value it
/// started at, and otherwise the jump the panel makes, or its refusal.
///
/// A starting value names the reading position as every time and percent
/// is shown, so it misses the place itself by a little: a time drops its
/// fraction of a second, so at 2:13:05.7 Go to Time starts at "2:13:05",
/// and an audiobook finished at 9:41:07.4 at "9:41:07"; a percent is
/// rounded to a tenth. Taken as typed, Go to Time's moved the place back by
/// what the field leaves off, up to a second of an audiobook or about 8
/// words of a text book, or onto a heading starting in that second; it also
/// kept a Return position, said "Jumped to…", restarted a playing text
/// book's speech, and left a finished book short of its end (REV14). Go to
/// Percent's moved the place by up to 0.05 percent of the book.
enum JumpFieldOutcome: Equatable {
    /// The field holds the value it started at: nothing moves and nothing
    /// is said, and the panel closes as Cancel closes it.
    case unchanged
    /// The place moved to what was typed, and the panel closes.
    case jumped
    /// What was typed was refused, for the reason given: the panel stays
    /// open, showing and announcing why.
    case refused(String)

    /// What taking `text` does, its field having started at `startingText`:
    /// `unchanged`, without calling `submit`, when the two are the same once
    /// spaces and line breaks around them are set aside; otherwise what
    /// `submit` makes of it, a jump (nil) or why not.
    @MainActor
    static func taking(
        _ text: String,
        startedAt startingText: String,
        submit: @MainActor (String) -> String?
    ) -> JumpFieldOutcome {
        /// The text as the field's value, without what surrounds it.
        func value(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value(text) != value(startingText) else { return .unchanged }
        guard let problem = submit(text) else { return .jumped }
        return .refused(problem)
    }
}

/// Go to Percent's panel: one field, "Percent through the book", starting
/// at the reading position's percent, which jumps to the percent typed.
struct JumpToPercentPanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    var body: some View {
        JumpFieldPanel(
            label: ReaderTimeWording.percentFieldLabel,
            hint: ReaderTimeWording.percentFieldHint,
            fieldWidth: 80,
            // The current percent, so the user can adjust it rather than
            // type from nothing.
            startingText: { viewModel.goToPercentStartingText },
            submit: viewModel.goToPercent(typed:),
            announce: viewModel.announceToVoiceOver,
            onJump: onJump,
            onCancel: onCancel
        )
    }
}

/// Go to Time's panel (P08): one field taking a time typed or pasted as
/// people write it ("1:02:03", "62:03", "3723", "12:04.3"), starting at the
/// reading position's time on the book's clock. For an audiobook the field
/// is "Time in the recording" and counts the recording's own time, whatever
/// its speed, so a time from its chapter list, its show notes, the audio
/// editor, or any of the reader's own times lands where it says; for a text
/// book it is "Time at 500 words a minute", its own speed, as its times
/// always counted. It took the place of three whole-number fields, Hours,
/// Minutes, and Seconds, known to VoiceOver only by their placeholders,
/// which refused a pasted time and counted an audiobook's starting value
/// and limit at its speed while jumping on its recording.
struct JumpToTimePanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    var body: some View {
        JumpFieldPanel(
            label: ReaderTimeWording.timeFieldLabel(viewModel.timeCount),
            hint: ReaderTimeWording.timeFieldHint,
            fieldWidth: 100,
            // The current time, so the user can adjust it rather than type
            // from nothing.
            startingText: { viewModel.goToTimeStartingText },
            submit: viewModel.goToTime(typed:),
            announce: viewModel.announceToVoiceOver,
            onJump: onJump,
            onCancel: onCancel
        )
    }
}

/// One labelled field below the status row, as Go to Percent and Go to
/// Time each are: its name shown before it for the eye and spoken as the
/// field's own label, the field starting at a value and taking the keyboard
/// as the panel opens, Jump (Return) and Cancel (Escape), and what is wrong
/// with a refused answer shown under the field and announced, so it can be
/// corrected where it was typed. Jump on the value the field started at
/// closes the panel as Cancel does, with nothing moved or said
/// (`JumpFieldOutcome.unchanged`).
///
/// ## A plain field
/// Earlier panels layered auto-focus per field, character filtering, an
/// arrow-key monitor, and accessibility overrides on their fields, an
/// overridden value among them, and VoiceOver called the fields "text"
/// rather than "edit text" (stripped by commit 6206c738, May 4). The
/// stripped fields then had no name a Tab user heard: a filled field speaks
/// no placeholder, and their unit words were separate text (REV13). So the
/// field has a label and a hint of its own, as the audio editor's prompt
/// field has (`AudioEditorPromptSheet`), and nothing else: never an
/// overridden value, so VoiceOver reads it as the edit text it is, its
/// value whatever is typed. Validation runs once, on submit.
struct JumpFieldPanel: View {
    /// The field's name, shown before it and spoken as its label.
    let label: String
    /// What the field takes, spoken as its hint.
    let hint: String
    /// How wide the field is drawn.
    let fieldWidth: CGFloat
    /// The value the field starts at, read as the panel opens.
    let startingText: @MainActor () -> String
    /// Takes what was typed: jumps and returns nil, or returns why it will
    /// not do.
    let submit: @MainActor (String) -> String?
    /// Announces a refusal to VoiceOver, which hears it even while its
    /// cursor stays in the field.
    let announce: @MainActor (String) -> Void
    /// Closes the panel after a jump.
    let onJump: () -> Void
    /// Closes the panel with nothing done.
    let onCancel: () -> Void

    /// What is typed in the field.
    @State private var text: String = ""
    /// What the field held as the panel opened (`startingText`), which Jump
    /// takes as no change (`JumpFieldOutcome.unchanged`).
    @State private var openingText: String = ""
    /// Inline error message shown after a refused submit. Cleared on the
    /// next submit that jumps, or as soon as the user edits the field.
    /// Empty means no error.
    @State private var errorMessage: String = ""
    /// Drives the field's focus as the panel opens: a plain Bool
    /// `@FocusState` on the one field, so VoiceOver still classifies it as
    /// a text field.
    @FocusState private var inputFocused: Bool
    /// The focus-after-animation delay, cancellable so a quick dismiss
    /// doesn't focus a vanishing view.
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The field's name, for the eye; VoiceOver hears it once,
                // as the field's own label.
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField(label, text: $text)
                    .frame(width: fieldWidth)
                    .focused($inputFocused)
                    .onSubmit(take)
                    // Clear a stale error as soon as the user starts
                    // editing: it refers to the previous submit.
                    .onChange(of: text) { _, _ in
                        if !errorMessage.isEmpty { errorMessage = "" }
                    }
                    .accessibilityLabel(label)
                    .accessibilityHint(hint)
                Button("Jump", action: take)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("Error: \(errorMessage)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .onAppear {
            openingText = startingText()
            text = openingText
            errorMessage = ""

            // Focus the field after the panel-appearance animation (about
            // 150 ms) settles; an earlier focus change is reverted as
            // SwiftUI finalises the layout.
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                inputFocused = true
            }
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
        }
    }

    /// Takes what the field holds (`JumpFieldOutcome.taking`): the value it
    /// opened with closes the panel as Cancel does, with nothing moved or
    /// said; anything else goes to `submit`, which closes the panel once it
    /// jumps, or shows and announces why not, keeping the panel open.
    private func take() {
        switch JumpFieldOutcome.taking(text, startedAt: openingText, submit: submit) {
        case .unchanged:
            errorMessage = ""
            onCancel()
        case .jumped:
            errorMessage = ""
            onJump()
        case .refused(let problem):
            errorMessage = problem
            announce(problem)
        }
    }
}
