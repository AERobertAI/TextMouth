import SwiftUI

/// The unified sleep-timer sheet. One sheet, three sections:
///
/// 1. **New Timer** — always shown. Tapping a preset starts (or restarts)
///    the timer with that duration. If a timer is already running, the
///    underlying `SleepTimerService.start(...)` call replaces it — the
///    user's mental model is "set the timer to X minutes", not
///    "start a fresh timer if and only if none is running".
/// 2. **Stop At** — always shown. End of heading and End of book set a
///    timer that stops playback where the book reaches that place, for
///    text and audio alike, replacing any timer as a preset does (TODO
///    P01). The heading is one concept for any document (October 6,
///    2026): where the next heading of any level begins, or the book
///    ends; an audiobook's chapters are its headings.
/// 3. **Current Timer** — visible only while a timer is running, above the
///    others. Shows the remaining time, or the place the timer stops at,
///    and exposes Reset (restart with the same duration) and Cancel
///    buttons.
///
/// ## Why merged
/// Previously the active and idle states were separate views with
/// different keyboard focus, different Close behavior, and different
/// tab orders. The sheet would also race with playback transitions:
/// pressing a preset dismissed the sheet, but if the timer expired
/// quickly the next reopen put the user back into a different layout.
/// Merging both states into one persistent layout makes the behavior
/// predictable and gives VoiceOver users a single, stable focus order.
///
/// ## Single-sheet enforcement
/// When this view appears, it broadcasts `.sleepTimerSheetOpened` with
/// its own `viewID`. Any other open sheet receives the notification,
/// compares IDs, and if mismatched, closes itself. This stops the
/// "two book windows = two timer sheets" duplication the user reported.
struct SleepTimerView: View {
    /// Presets share one source of truth for rendering and initial focus.
    /// Constants, so nonisolated: tests read them from any context.
    nonisolated static let presetMinutes = [10, 15, 30, 45, 60]
    nonisolated static let initialFocusPresetMinutes = presetMinutes[0]

    /// The reader the timer pauses, whose methods start and stop it. Not
    /// observed: the sheet shows nothing of the reader, only the timer, so
    /// the reader's publishes, eight a second while it plays, never redraw
    /// it (PERF30).
    let viewModel: ReaderViewModel
    @ObservedObject var sleepTimerService: SleepTimerService
    var onStartPlayback: (() -> Void)?
    /// The presenting reader supplies its sheet-binding close action. Using
    /// the source-of-truth binding avoids relying solely on an environment
    /// dismiss action after the timer's observed state changes.
    var onClose: (() -> Void)?
    /// Whether to dismiss the sheet after starting a NEW timer.
    /// Current-timer actions honor the same sheet auto-close policy so
    /// reset/restart behave the same way as a fresh timer selection.
    var autoClose: Bool = true

    @Environment(\.dismiss) private var dismiss

    /// The sheet of `reader`'s window (November 13, 2026: each reader window
    /// has a timer of its own): it sets, shows, resets, and cancels that
    /// window's timer, its start plays the book unless it is playing already,
    /// and its Close, or its closing by itself when Settings say so, calls
    /// `onClose`. The one way a reader's sheet is made, so every window's
    /// sheet shows its own timer.
    static func sheet(for reader: ReaderViewModel, onClose: @escaping () -> Void) -> SleepTimerView {
        SleepTimerView(
            viewModel: reader,
            sleepTimerService: reader.sleepTimerService,
            onStartPlayback: {
                if !reader.isCurrentlyPlaying || reader.isCurrentlyPaused {
                    reader.togglePlayPause()
                }
            },
            onClose: onClose,
            autoClose: reader.settingsViewModel.sleepTimerAutoClose
        )
    }

    @State private var customMinutes: Int = 30
    /// Keep the VoiceOver request alive only for initial presentation. Setting
    /// or cancelling a timer changes the sheet hierarchy; leaving the request
    /// attached would create a new focus bridge that could reactivate a sheet
    /// while it was being dismissed.
    @State private var shouldRequestInitialFocus = true
    /// Unique identifier for this sheet instance. Other sheets close
    /// themselves when they receive a `sleepTimerSheetOpened`
    /// notification with a different ID — so only one timer sheet is
    /// ever open across all book windows.
    @State private var viewID = UUID()

    var body: some View {
        let _ = ViewBodyCounter.record("SleepTimerView")
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button("Close") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Close the sleep timer and return to the book")
            }

            // Current timer section — only when a timer is running
            if sleepTimerService.isActive {
                currentTimerSection
                Divider()
            }

            // New timer section — always visible
            newTimerSection

            Divider()

            // Stop At section — always visible
            stopAtSection
        }
        .padding()
        .frame(width: 320)
        .navigationTitle("Sleep Timer")
        .onAppear {
            // Tell any other open sleep-timer sheets to close themselves —
            // only one sheet visible at a time across all book windows.
            NotificationCenter.default.post(
                name: .sleepTimerSheetOpened,
                object: nil,
                userInfo: ["sheetID": viewID]
            )

            // Once the initial focus attempts have had time to complete,
            // remove the trigger so countdown updates cannot request focus
            // again. Timer actions also clear it immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                shouldRequestInitialFocus = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sleepTimerSheetOpened)) { notif in
            // Another sheet opened. If it's not us, dismiss ourselves.
            if let otherID = notif.userInfo?["sheetID"] as? UUID, otherID != viewID {
                closeSheet()
            }
        }
    }

    // MARK: - Current Timer Section

    /// Shown while `sleepTimerService.isActive`. Heading, remaining time
    /// or the place the timer stops at, Reset and Cancel buttons. The
    /// Reset/Cancel actions go through the view-model wrappers so they
    /// always touch the shared service via the same code path the timer
    /// sheet uses to arm a timer.
    private var currentTimerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Timer")
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Image(systemName: "moon.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text(sleepTimerService.formattedRemaining)
                    .font(.system(.title3, design: .monospaced))
                    .accessibilityLabel(sleepTimerService.spokenLabel)
            }

            HStack(spacing: 12) {
                Button("Reset Timer") {
                    shouldRequestInitialFocus = false
                    viewModel.restartSleepTimer(startPlaybackIfNeeded: true)
                    viewModel.announceToVoiceOver(Self.resetAnnouncement(status: sleepTimerService.spokenStatus))
                    if autoClose {
                        closeSheet()
                    }
                }
                .accessibilityHint("Restart the timer with its original duration")

                Button("Cancel Timer", role: .destructive) {
                    shouldRequestInitialFocus = false
                    viewModel.cancelSleepTimer()
                    viewModel.announceToVoiceOver("Sleep timer cancelled.")
                }
                .accessibilityHint("Stop the timer and discard the remaining time")
            }
        }
    }

    // MARK: - New Timer Section

    /// Always visible. Lists preset durations and a custom-minutes field.
    /// Selecting any of these calls
    /// `viewModel.startSleepTimer(duration:startPlaybackIfNeeded:)`
    /// which ALWAYS replaces any timer already running — the sheet's UI
    /// for "set a new timer" is the same whether or not one is currently
    /// running. The timers that stop at a place in the book are in the
    /// Stop At section below.
    private var newTimerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Timer")
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text(sleepTimerService.isActive
                 ? "Setting a new timer replaces the current one."
                 : "Pause playback after:")
                .font(.caption)
                .foregroundColor(.secondary)

            // Preset minute durations
            ForEach(Self.presetMinutes, id: \.self) { minutes in
                Button(SleepTimerDuration.minutes(minutes).displayName) {
                    setNewTimer(.minutes(minutes))
                }
                .accessibilityLabel(Self.setTimerLabel(minutes: minutes))
                // The top Close control remains immediately available, but
                // opening the sheet places VoiceOver on the first primary
                // timer action instead of the dismiss action.
                .modifier(InitialVoiceOverFocusModifier(
                    isTarget: Self.isInitialFocusTarget(
                        minutes: minutes,
                        shouldRequest: shouldRequestInitialFocus
                    ),
                    delay: 0.2
                ))
            }

            // Custom duration
            HStack(spacing: 8) {
                // "Custom:" and "min" are for the eye: the field's label,
                // "Custom timer minutes", says both, so VoiceOver skips
                // them as stops of their own (TODO A10).
                Text("Custom:")
                    .accessibilityHidden(true)
                TextField("Minutes", value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        customMinutes = max(1, min(customMinutes, 480))
                        setNewTimer(.minutes(customMinutes))
                    }
                    .accessibilityLabel("Custom timer minutes")
                    .accessibilityValue(customMinutesSpoken)
                    .accessibilityHint(Self.customMinutesHint)
                // Its value is the field's, unit and all: it was the bare
                // number, "Adjust minutes, 30" (TODO A10).
                Stepper("", value: $customMinutes, in: 1...480, step: Self.customMinutesStep)
                    .labelsHidden()
                    .accessibilityLabel(Self.adjustMinutesLabel)
                    .accessibilityValue(customMinutesSpoken)
                Text("min")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button("Set") {
                    customMinutes = max(1, min(customMinutes, 480))
                    setNewTimer(.minutes(customMinutes))
                }
                .accessibilityLabel(Self.setTimerLabel(minutes: customMinutes))
            }
        }
    }

    // MARK: - Stop At Section

    /// Always visible. Timers that stop playback where the book reaches a
    /// place rather than after some minutes, for text and audio alike (TODO
    /// P01): the end of the heading playing, where the next heading begins
    /// or the book ends, which is one concept for any document, a text
    /// book's headings of any level and an audiobook's chapters alike
    /// (October 6, 2026); or the end of the book, even where Continue to
    /// Next Book would start the next book. Like a preset, each replaces any
    /// timer running and starts playback. The End of heading hint says where
    /// a heading ends; the End of book hint says what the timer adds to what
    /// this book does at its end on its own.
    private var stopAtSection: some View {
        let endOfBookHint = Self.endOfBookHint(for: viewModel.effectiveEndOfBookBehavior)
        return VStack(alignment: .leading, spacing: 8) {
            Text(Self.stopAtHeading)
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Button(Self.endOfHeadingTitle) {
                setNewTimer(.endOfHeading)
            }
            .accessibilityLabel(Self.endOfHeadingLabel)
            .accessibilityHint(Self.endOfHeadingHint)
            .help(Self.endOfHeadingHint)

            Button(Self.endOfBookTitle) {
                setNewTimer(.endOfBook)
            }
            .accessibilityLabel(Self.endOfBookLabel)
            .accessibilityHint(endOfBookHint)
            .help(endOfBookHint)
        }
    }

    /// The custom minutes as the field and its stepper both speak them,
    /// unit and all: "1 minute", "30 minutes".
    private var customMinutesSpoken: String {
        CountWording.minutes(customMinutes)
    }

    /// Start (or restart) the timer and optionally dismiss the sheet.
    /// Plays the book if it isn't already playing — the user clearly
    /// intends to read until the timer fires.
    private func setNewTimer(_ duration: SleepTimerDuration) {
        // Disable the one-time focus bridge before publishing the active timer
        // state. Otherwise SwiftUI may rebuild it for the new Current Timer
        // section and reactivate the sheet during dismissal.
        shouldRequestInitialFocus = false
        viewModel.startSleepTimer(duration: duration, startPlaybackIfNeeded: true)
        // Announce so VoiceOver users know the timer was set even if
        // the sheet auto-dismisses immediately.
        viewModel.announceToVoiceOver(Self.announcement(forSetting: duration))
        if autoClose {
            closeSheet()
        }
    }

    // MARK: - Wording

    /// How many minutes the Adjust minutes stepper changes the custom timer
    /// by.
    nonisolated static let customMinutesStep = 5
    /// The custom timer's stepper's label, which the field's hint names.
    nonisolated static let adjustMinutesLabel = "Adjust minutes"

    /// What VoiceOver calls a button that sets a timer for `minutes`, a
    /// preset's or the custom timer's Set: "Set timer for 1 minute and start
    /// playing", by the timer's own name (TODO A10; it said "1 minutes").
    nonisolated static func setTimerLabel(minutes: Int) -> String {
        "Set timer for \(SleepTimerDuration.minutes(minutes).displayName) and start playing"
    }
    /// The custom minutes field's hint: what typing does, the stepper beside
    /// it by name and step, and what Return does there (TODO A10; it said
    /// "use the stepper arrows", which name no control VoiceOver lands on).
    nonisolated static let customMinutesHint =
        "Type the minutes, or change them \(customMinutesStep) at a time with \(adjustMinutesLabel). Return sets the timer and starts playing."

    /// The heading of the section of timers that stop at a place.
    nonisolated static let stopAtHeading = "Stop At"
    /// The End of heading button's title.
    nonisolated static let endOfHeadingTitle = "End of heading"
    /// What VoiceOver reads for the End of heading button.
    nonisolated static let endOfHeadingLabel = "Stop at the end of this heading and start playing"
    /// What the End of heading button does, for VoiceOver and as its help:
    /// where a heading ends, for any document.
    nonisolated static let endOfHeadingHint =
        "Pauses playback where the heading playing now ends: where the next heading begins, or the book ends."
    /// The End of book button's title.
    nonisolated static let endOfBookTitle = "End of book"
    /// What VoiceOver reads for the End of book button.
    nonisolated static let endOfBookLabel = "Stop at the end of the book and start playing"

    /// What the End of book button does, for VoiceOver and as its help, for
    /// a book whose end-of-book behavior is `behavior`: it pauses playback
    /// before Continue to Next Book or Loop to Start would go on, and it says
    /// so when the book stops at its end on its own anyway.
    nonisolated static func endOfBookHint(for behavior: EndOfBookBehavior) -> String {
        switch behavior {
        case .continueNext:
            return "Pauses playback when this book ends, before Continue to Next Book starts the next book."
        case .loop:
            return "Pauses playback when this book ends, before Loop to Start plays it again."
        case .stop, .stopAndPlayStartsOver:
            return "This book already stops playing at its end, since Continue to Next Book is off; the timer stops it there too."
        }
    }

    /// What VoiceOver announces as a timer is set for `duration`: where a
    /// timer for a place stops playback ("Sleep timer: stops at the end of
    /// this heading."), or the minutes a timer counts.
    nonisolated static func announcement(forSetting duration: SleepTimerDuration) -> String {
        guard let stop = duration.spokenStop else { return "Timer set for \(duration.displayName)." }
        return "Sleep timer: \(stop)."
    }

    /// What VoiceOver announces as Reset Timer restarts the timer, whose
    /// state `status` gives as `SleepTimerService.spokenStatus` reads it.
    nonisolated static func resetAnnouncement(status: String) -> String {
        "Timer reset: \(status)."
    }

    /// Centralize every close path so buttons, Escape, auto-close, and the
    /// single-sheet notification all update the presenter's binding directly.
    private func closeSheet() {
        shouldRequestInitialFocus = false
        Self.performDismiss(onClose: onClose) {
            dismiss()
        }
    }

    /// Pure routing helper used by tests to guarantee that an explicit parent
    /// close action wins, with Environment dismiss retained as a safe fallback.
    /// Nonisolated, as it only calls what it is given, synchronously, in its
    /// caller's context: the sheet's main actor, or a test's.
    nonisolated static func performDismiss(onClose: (() -> Void)?, fallback: () -> Void) {
        if let onClose {
            onClose()
        } else {
            fallback()
        }
    }

    /// Identify the sole initial VoiceOver target only while the sheet's
    /// one-time focus request remains active. Pure, so nonisolated.
    nonisolated static func isInitialFocusTarget(minutes: Int, shouldRequest: Bool) -> Bool {
        shouldRequest && minutes == initialFocusPresetMinutes
    }
}

/// Two sheets are the same when they set the timer for the same reader with
/// the same closing behavior (PERF30). The reader view presenting the sheet
/// makes it again each time it draws, eight times a second while a book
/// plays, with new closures; closures cannot be compared, so without this
/// SwiftUI redrew the sheet every time. The closures are not compared: they
/// act on the presenter's state as it is when they run. Nor is the timer
/// service: a reader's is always the one shared timer.
extension SleepTimerView: Equatable {
    nonisolated static func == (lhs: SleepTimerView, rhs: SleepTimerView) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.autoClose == rhs.autoClose
    }
}

// MARK: - Notification Bridge

extension Notification.Name {
    /// Posted when any sleep-timer sheet appears. Other open sheets
    /// listen and dismiss themselves so only one is visible at a time
    /// across all book windows. UserInfo carries `sheetID: UUID`.
    static let sleepTimerSheetOpened = Notification.Name("sleepTimerSheetOpened")
}
