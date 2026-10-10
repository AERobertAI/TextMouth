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
            startingText: { String(format: "%.1f", viewModel.displayPercentComplete) },
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
/// corrected where it was typed.
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
            text = startingText()
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

    /// Hands what was typed to `submit`: closes the panel once it jumps,
    /// or shows and announces why not, keeping the panel open.
    private func take() {
        if let problem = submit(text) {
            errorMessage = problem
            announce(problem)
        } else {
            errorMessage = ""
            onJump()
        }
    }
}
