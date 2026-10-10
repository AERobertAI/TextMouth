import SwiftUI

// The reader's Go to Percent and Go to Time panels, which the status row's
// percent and time buttons open below it (`BookInfoBar`), and the validator
// of what is typed into them.

// MARK: - Jump-To Panels

enum JumpInputValidator {
    enum PercentResult: Equatable {
        case value(Double)
        case error(String)
    }

    enum TimeResult: Equatable {
        case value(TimeInterval)
        case error(String)
    }

    static func percent(_ raw: String) -> PercentResult {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .error("Enter a percent.") }
        guard let value = Double(trimmed) else { return .error("\"\(trimmed)\" is not a number.") }
        guard (0...100).contains(value) else {
            return .error("Percent must be between 0 and 100.")
        }
        return .value(value)
    }

    static func time(
        hours: String,
        minutes: String,
        seconds: String,
        bookLength: TimeInterval
    ) -> TimeResult {
        func parse(_ text: String, field: String) -> (value: Int?, error: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return (0, nil) }
            guard let value = Int(trimmed), value >= 0 else {
                return (nil, "\(field) must be a whole number.")
            }
            return (value, nil)
        }

        let parsed = [
            parse(hours, field: "Hours"),
            parse(minutes, field: "Minutes"),
            parse(seconds, field: "Seconds"),
        ]
        let values = parsed.compactMap(\.value)
        if values.count != 3 {
            let error = parsed.compactMap(\.error).first ?? "Enter a valid time."
            return .error(error)
        }
        let (hoursValue, minutesValue, secondsValue) = (values[0], values[1], values[2])
        guard minutesValue < 60 else { return .error("Minutes must be less than 60.") }
        guard secondsValue < 60 else { return .error("Seconds must be less than 60.") }
        // Convert before multiplying: a valid Int in the hours field can still
        // overflow integer arithmetic before normal book-length validation.
        let total = TimeInterval(hoursValue) * 3_600 + TimeInterval(minutesValue) * 60 + TimeInterval(secondsValue)
        guard bookLength.isFinite, total <= bookLength else {
            return .error("Time exceeds book length. Maximum is \(TimeFormatting.spoken(bookLength)).")
        }
        return .value(total)
    }
}

/// Expanded panel below the info bar offering a single text input for
/// jumping to a percent through the book.
/// Stripped to a plain TextField — earlier iterations layered on
/// auto-focus, character filtering, and accessibility overrides, but
/// each piece of "special handling" turned out to compromise how
/// VoiceOver classified the field (announcing it as "text" instead
/// of "edit text"). Validation now happens on submit; bad input
/// surfaces an inline error instead of being silently clamped or
/// stripped while typing.
struct JumpToPercentPanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    @State private var percentInput: String = ""
    /// Inline error message shown after a failed submit. Cleared on
    /// the next successful submit or when the user starts editing
    /// the field. Empty string means no error.
    @State private var errorMessage: String = ""
    /// Drives the auto-focus on appear. A plain Bool @FocusState on
    /// just this single field — no other accessibility overrides on
    /// the TextField — so VoiceOver still classifies it correctly.
    @FocusState private var inputFocused: Bool
    /// Cancellable Task for the focus-after-animation delay so a
    /// quick dismiss doesn't fire focus against a vanishing view.
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Jump to:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Percent", text: $percentInput)
                    .frame(width: 80)
                    .focused($inputFocused)
                    .onSubmit(performJump)
                    // Clear stale error as soon as the user starts
                    // editing — the message refers to the previous
                    // submit, not the current text.
                    .onChange(of: percentInput) { _, _ in
                        if !errorMessage.isEmpty { errorMessage = "" }
                    }
                // The unit in a word, which VoiceOver reads after the
                // field: the field is left plain, as the note above says,
                // so its placeholder, "Percent", names it only while it is
                // empty, and it opens filled in. It said "%" (TODO A10).
                Text("percent")
                    .foregroundColor(.secondary)
                Button("Jump", action: performJump)
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
            // Pre-fill with the current percent so the user can edit
            // an offset rather than typing from scratch when fine-
            // tuning their position.
            percentInput = String(format: "%.1f", viewModel.displayPercentComplete)
            errorMessage = ""

            // Auto-focus the input after the panel-appearance
            // animation (~150ms) settles. Earlier focus changes get
            // reverted as SwiftUI finalises the layout.
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

    /// Validate the input on submit and either jump or surface an
    /// error. Empty input is rejected (the user typed nothing OR
    /// erased the pre-fill — either way, asking them to be explicit
    /// beats silently jumping to 0%). Out-of-range and non-numeric
    /// input both produce inline errors AND a VoiceOver announcement
    /// so blind users hear the failure even without focus on the
    /// error text.
    private func performJump() {
        switch JumpInputValidator.percent(percentInput) {
        case .value(let value):
            errorMessage = ""
            viewModel.jumpToPercent(value)
            onJump()
        case .error(let message):
            showError(message)
        }
    }

    private func showError(_ msg: String) {
        errorMessage = msg
        viewModel.announceToVoiceOver(msg)
    }
}

/// Expanded panel offering hours / minutes / seconds inputs to jump to
/// a wall-clock time within the book.
///
/// ## Why three plain TextFields
/// Earlier iterations had auto-focus, an NSEvent monitor for arrow
/// keys, a digit-only onChange filter, and overridden accessibility
/// label/value. The combination broke VoiceOver's classification —
/// fields announced as "text" instead of "edit text" — and the arrow
/// monitor ran into stale-state issues across re-renders. Stripped
/// back to bare TextFields so each behaves exactly like a normal
/// macOS text input. Validation runs once on submit; bad input
/// produces an inline error AND a VoiceOver announcement.
///
/// ## Validation rules
/// - Empty / non-numeric in any field → error.
/// - Hours, minutes, seconds individually must be non-negative
///   integers. Minutes / seconds capped at 59 with an explicit
///   error rather than silent clamp.
/// - Total must not exceed the book's estimated total time. This
///   is the "jump past end of book" check the user asked about.
struct JumpToTimePanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    @State private var hoursText: String = "0"
    @State private var minutesText: String = "0"
    @State private var secondsText: String = "0"
    @State private var errorMessage: String = ""
    /// Auto-focus drives ONLY the hours field. Plain Bool focus
    /// state without per-field overrides keeps VoiceOver's text-
    /// field classification intact — the previous design used a
    /// per-field enum @FocusState plus an arrow-key NSEvent monitor,
    /// and those layered customizations were what broke VO's
    /// classification. Tab still works to move between fields
    /// because that's the SwiftUI default for focusable inputs.
    @FocusState private var hoursFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Jump to:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Each unit in a word, which VoiceOver reads after its
                // field: the fields are left plain, as the note above says,
                // so their placeholders name them only while empty, and they
                // open filled in. They said "h", "m", and "s" (TODO A10).
                TextField("Hours", text: $hoursText)
                    .frame(width: 50)
                    .focused($hoursFocused)
                    .onSubmit(performJump)
                    .onChange(of: hoursText) { _, _ in clearError() }
                Text("hours")
                    .foregroundColor(.secondary)

                TextField("Minutes", text: $minutesText)
                    .frame(width: 50)
                    .onSubmit(performJump)
                    .onChange(of: minutesText) { _, _ in clearError() }
                Text("minutes")
                    .foregroundColor(.secondary)

                TextField("Seconds", text: $secondsText)
                    .frame(width: 50)
                    .onSubmit(performJump)
                    .onChange(of: secondsText) { _, _ in clearError() }
                Text("seconds")
                    .foregroundColor(.secondary)

                Button("Jump", action: performJump)
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
            // Pre-fill with current elapsed (totalTime - timeRemaining)
            // so the user can adjust by a delta rather than typing
            // from zero.
            let elapsed = max(0, viewModel.totalEstimatedTime - viewModel.displayTimeRemaining)
            let total = Int(elapsed)
            hoursText = "\(total / 3600)"
            minutesText = "\((total % 3600) / 60)"
            secondsText = "\(total % 60)"
            errorMessage = ""

            // Auto-focus the hours field after the panel-appearance
            // animation (~150ms) settles. Same rationale as the
            // matching code in JumpToPercentPanel.
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                hoursFocused = true
            }
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
        }
    }

    private func clearError() {
        if !errorMessage.isEmpty { errorMessage = "" }
    }

    /// Parse one of the H/M/S fields. Empty input is treated as zero
    /// (typing only minutes shouldn't fail because the seconds field
    /// is blank). Non-numeric input returns nil so the caller can
    /// surface a precise error.
    /// Validate H/M/S and jump or surface an error. The error message
    /// is mirrored to VoiceOver so blind users hear the failure even
    /// when their cursor stays in the input field.
    private func performJump() {
        switch JumpInputValidator.time(
            hours: hoursText,
            minutes: minutesText,
            seconds: secondsText,
            bookLength: viewModel.totalEstimatedTime
        ) {
        case .value(let total):
            errorMessage = ""
            viewModel.jumpToTime(seconds: total)
            onJump()
        case .error(let message):
            showError(message)
        }
    }

    private func showError(_ msg: String) {
        errorMessage = msg
        viewModel.announceToVoiceOver(msg)
    }
}
