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
/// ## One timer for each window
/// The sheet shows its own window's timer (November 13, 2026: each reader
/// window has its own), so two windows' sheets show two timers, and opening
/// one no longer closes the other. While the app had one timer, every sheet
/// showed the same one, and a sheet opening closed the others, which the
/// user had reported as two timer sheets for two book windows.
struct SleepTimerView: View {
    /// Presets share one source of truth for rendering and initial focus.
    /// Constants, so nonisolated: tests read them from any context.
    nonisolated static let presetMinutes = [10, 15, 30, 45, 60]
    nonisolated static let initialFocusPresetMinutes = presetMinutes[0]

    /// The reader the timer pauses, whose methods start and stop it. Not
    /// observed: the sheet shows nothing of the reader, only the timer, so
    /// the reader's publishes, about one a second while it plays, never redraw
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

    var body: some View {
        let _ = ViewBodyCounter.record("SleepTimerView")
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(Self.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button(Self.closeTitle) { closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(Self.closeHint)
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
        .navigationTitle(Self.title)
        .onAppear {
            // Once the initial focus attempts have had time to complete,
            // remove the trigger so countdown updates cannot request focus
            // again. Timer actions also clear it immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                shouldRequestInitialFocus = false
            }
        }
    }

    // MARK: - Current Timer Section

    /// Shown while `sleepTimerService.isActive`. Heading, remaining time
    /// or the place the timer stops at, Reset and Cancel buttons. The
    /// Reset/Cancel actions go through the view-model wrappers so they
    /// always touch the window's timer via the same code path the timer
    /// sheet uses to arm a timer.
    private var currentTimerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.currentTimerHeading)
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
                Button(Self.resetTimerTitle) {
                    shouldRequestInitialFocus = false
                    viewModel.restartSleepTimer(startPlaybackIfNeeded: true)
                    viewModel.announceToVoiceOver(Self.resetAnnouncement(status: sleepTimerService.spokenStatus))
                    if autoClose {
                        closeSheet()
                    }
                }
                .accessibilityHint(Self.resetTimerHint)

                Button(Self.cancelTimerTitle, role: .destructive) {
                    shouldRequestInitialFocus = false
                    viewModel.cancelSleepTimer()
                    viewModel.announceToVoiceOver(Self.cancelledAnnouncement)
                }
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
            Text(Self.newTimerHeading)
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text(Self.newTimerNote(isActive: sleepTimerService.isActive))
                .font(.caption)
                .foregroundColor(.secondary)

            // Preset minute durations
            ForEach(Self.presetMinutes, id: \.self) { minutes in
                Button(SleepTimerDuration.minutes(minutes).displayName) {
                    setNewTimer(.minutes(minutes))
                }
                .accessibilityLabel(Self.setTimerLabel(minutes: minutes))
                .accessibilityHint(Self.minutesTimerHint)
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
                // "Custom minutes", says both, so VoiceOver skips
                // them as stops of their own (TODO A10).
                Text(Self.customPrefix)
                    .accessibilityHidden(true)
                TextField(Self.minutesFieldTitle, value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        customMinutes = Self.clampedCustomMinutes(customMinutes)
                        setNewTimer(.minutes(customMinutes))
                    }
                    .accessibilityLabel(Self.customMinutesLabel)
                    .accessibilityValue(customMinutesSpoken)
                    .accessibilityHint(Self.customMinutesHint)
                // Its value is the field's, unit and all: it was the bare
                // number, "Adjust minutes, 30" (TODO A10). It has no title of
                // its own: an empty title was a string of its own for
                // translators, with nothing to translate (FR35), and a hidden
                // title is read before the label on the Mac ("Adjust minutes,
                // Adjust minutes", board #121), so the label stands alone.
                Stepper(value: $customMinutes, in: Self.customMinutesRange, step: Self.customMinutesStep) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel(Self.adjustMinutesLabel)
                .accessibilityValue(customMinutesSpoken)
                Text(Self.minutesUnit)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button(Self.setTitle) {
                    customMinutes = Self.clampedCustomMinutes(customMinutes)
                    setNewTimer(.minutes(customMinutes))
                }
                .accessibilityLabel(Self.setTimerLabel(minutes: customMinutes))
                .accessibilityHint(Self.minutesTimerHint)
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
    /// unit and all: "1 minute", "30 minutes", the name a timer of that many
    /// minutes has.
    private var customMinutesSpoken: String {
        SleepTimerDuration.minutes(customMinutes).displayName
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

    // Every word of the sheet, localized (FR35): each is computed, so it is
    // read from the String Catalog in the interface's language whenever it is
    // asked for, and each carries a comment saying where it is seen or heard
    // and what each placeholder holds. The iPhone's sheet says the same words
    // through these (`PhoneSleepTimerVocabulary`).

    /// The sheet's title, read as its heading.
    nonisolated static var title: String {
        String(localized: "Sleep Timer",
               comment: "Title of the sleep timer sheet over a book's reader, read by VoiceOver as its heading.")
    }

    /// The button that closes the sheet.
    nonisolated static var closeTitle: String {
        String(localized: "Close",
               comment: "Button that closes a sheet, such as the sleep timer sheet over a book's reader.")
    }

    /// What VoiceOver says the Close button does: the result, which its
    /// label does not say (FR35's cut; it was "Close the sleep timer and
    /// return to the book").
    nonisolated static var closeHint: String {
        String(localized: "Returns to the book.",
               comment: "VoiceOver hint of the sleep timer sheet's Close button: closing the sheet goes back to the book's reader.")
    }

    /// The heading over the timer running.
    nonisolated static var currentTimerHeading: String {
        String(localized: "Current Timer",
               comment: "Heading of the sleep timer sheet's section about the timer running now.")
    }

    /// The button that starts the running timer again from its whole length.
    nonisolated static var resetTimerTitle: String {
        String(localized: "Reset Timer",
               comment: "Button of the sleep timer sheet that starts the running timer again from its whole length.")
    }

    /// What VoiceOver says Reset Timer does.
    nonisolated static var resetTimerHint: String {
        String(localized: "Restarts the timer at its full length.",
               comment: "VoiceOver hint of the sleep timer sheet's Reset Timer button: the running timer starts again from the length it was set to.")
    }

    /// The button that stops the running timer.
    nonisolated static var cancelTimerTitle: String {
        String(localized: "Cancel Timer",
               comment: "Button of the sleep timer sheet that stops the running timer.")
    }

    /// What VoiceOver says once Cancel Timer has stopped the timer.
    nonisolated static var cancelledAnnouncement: String {
        String(localized: "Sleep timer cancelled.",
               comment: "VoiceOver announcement after the Cancel Timer button stopped the sleep timer.")
    }

    /// The heading over the timers to set.
    nonisolated static var newTimerHeading: String {
        String(localized: "New Timer",
               comment: "Heading of the sleep timer sheet's section of timers to set: the minute presets and a custom number of minutes.")
    }

    /// The note under New Timer: that a new timer replaces the one running,
    /// while one runs (`isActive`), else what the presets do.
    nonisolated static func newTimerNote(isActive: Bool) -> String {
        isActive
            ? String(localized: "A new timer replaces the one running.",
                     comment: "Note under the sleep timer sheet's New Timer heading while a timer runs: setting one of the timers below stops it.")
            : String(localized: "Pause playback after:",
                     comment: "Note under the sleep timer sheet's New Timer heading while no timer runs; the minute presets follow it, such as 10 minutes.")
    }

    /// The word before the custom minutes field, for the eye only: the
    /// field's own label says it to VoiceOver.
    nonisolated static var customPrefix: String {
        String(localized: "Custom:",
               comment: "Shown before the sleep timer sheet's field of a custom number of minutes. Hidden from VoiceOver, which reads the field's label.")
    }

    /// The custom minutes field's title, shown in the field while it is empty.
    nonisolated static var minutesFieldTitle: String {
        String(localized: "Minutes",
               comment: "Placeholder of the sleep timer sheet's field of a custom number of minutes.")
    }

    /// What VoiceOver calls the custom minutes field.
    nonisolated static var customMinutesLabel: String {
        String(localized: "Custom minutes",
               comment: "VoiceOver label of the sleep timer sheet's field of a custom number of minutes.")
    }

    /// The unit after the custom minutes field, for the eye only.
    nonisolated static var minutesUnit: String {
        String(localized: "min",
               comment: "Short for minutes, shown after the sleep timer sheet's custom minutes field. Hidden from VoiceOver.")
    }

    /// The button that sets the custom timer.
    nonisolated static var setTitle: String {
        String(localized: "Set",
               comment: "Button after the sleep timer sheet's custom minutes field: sets a timer for those minutes.")
    }

    /// How many minutes the Adjust minutes stepper changes the custom timer
    /// by.
    nonisolated static let customMinutesStep = 5

    /// The fewest and most minutes the custom timer takes: the field, its
    /// stepper, and its hint, on the Mac and the iPhone.
    nonisolated static let customMinutesRange = 1...480

    /// `minutes` held to `customMinutesRange`.
    nonisolated static func clampedCustomMinutes(_ minutes: Int) -> Int {
        min(max(minutes, customMinutesRange.lowerBound), customMinutesRange.upperBound)
    }

    /// The custom timer's stepper's label, on the Mac and the iPhone.
    nonisolated static var adjustMinutesLabel: String {
        String(localized: "Adjust minutes",
               comment: "VoiceOver label of the stepper beside the sleep timer sheet's custom minutes field.")
    }

    /// What VoiceOver calls a button that sets a timer for `minutes`, a
    /// preset's or the custom timer's Set: "Set timer for 1 minute" (TODO
    /// A10; it said "1 minutes"). One phrase with its own plural forms in the
    /// catalog (FR35); what the button also does is its hint,
    /// `minutesTimerHint` (FR35's cut; the label went on "and start
    /// playing").
    nonisolated static func setTimerLabel(minutes: Int) -> String {
        String(localized: "Set timer for \(minutes) minutes",
               comment: "VoiceOver label of a sleep timer button that sets a timer of so many minutes. %lld is the number of minutes.")
    }

    /// What VoiceOver says a button that sets a timer of minutes does
    /// besides: it plays the book, if it is not playing already.
    nonisolated static var minutesTimerHint: String {
        String(localized: "Plays the book.",
               comment: "VoiceOver hint of the sleep timer sheet's minute presets and Set button: setting the timer also plays the book.")
    }

    /// The custom minutes field's hint: the minutes it takes, which nothing
    /// else says (FR35's cut; it named the Return key and the stepper, which
    /// a hint never does, in "Type the minutes, or change them 5 at a time
    /// with Adjust minutes. Return sets the timer and starts playing.").
    nonisolated static var customMinutesHint: String {
        String(localized: "Takes \(customMinutesRange.lowerBound) to \(customMinutesRange.upperBound) minutes.",
               comment: "VoiceOver hint of the sleep timer sheet's custom minutes field: the fewest and most minutes it takes. %1$lld is the fewest (1); %2$lld the most (480).")
    }

    /// The heading of the section of timers that stop at a place.
    nonisolated static var stopAtHeading: String {
        String(localized: "Stop At",
               comment: "Heading of the sleep timer sheet's section of timers that stop at a place in the book: End of heading and End of book.")
    }

    /// The End of heading button's title: the timer's own name.
    nonisolated static var endOfHeadingTitle: String {
        SleepTimerDuration.endOfHeading.displayName
    }

    /// What VoiceOver reads for the End of heading button (FR35's cut: it
    /// went on "and start playing", which its hint says).
    nonisolated static var endOfHeadingLabel: String {
        String(localized: "Stop at the end of this heading",
               comment: "VoiceOver label of the sleep timer sheet's End of heading button, which sets a timer that stops where the heading playing ends.")
    }

    /// What the End of heading button does, for VoiceOver and as its help:
    /// it plays the book, as far as the next heading (FR35's cut; it said
    /// "Pauses playback where the heading playing now ends: where the next
    /// heading begins, or the book ends.").
    nonisolated static var endOfHeadingHint: String {
        String(localized: "Plays the book until the next heading.",
               comment: "VoiceOver hint and help tag of the sleep timer sheet's End of heading button: the book plays, and pauses where the next heading begins.")
    }

    /// The End of book button's title: the timer's own name.
    nonisolated static var endOfBookTitle: String {
        SleepTimerDuration.endOfBook.displayName
    }

    /// What VoiceOver reads for the End of book button (FR35's cut: it went
    /// on "and start playing", which its hint says).
    nonisolated static var endOfBookLabel: String {
        String(localized: "Stop at the end of the book",
               comment: "VoiceOver label of the sleep timer sheet's End of book button, which sets a timer that stops where the book ends.")
    }

    /// What the End of book button does, for VoiceOver and as its help, for
    /// a book whose end-of-book behavior is `behavior`: it plays the book and
    /// pauses before the next book or the book's own start would follow, and
    /// says so when the book stops at its end on its own anyway (FR35's cut:
    /// each said the When book ends choice's name and the pause in more
    /// words).
    nonisolated static func endOfBookHint(for behavior: EndOfBookBehavior) -> String {
        switch behavior {
        case .continueNext:
            return String(localized: "Plays the book and pauses before the next book.",
                          comment: "VoiceOver hint and help tag of the sleep timer sheet's End of book button, for a book set to go on to the next book when it ends.")
        case .loop:
            return String(localized: "Plays the book and pauses before it starts again.",
                          comment: "VoiceOver hint and help tag of the sleep timer sheet's End of book button, for a book set to start again from its beginning when it ends.")
        case .stop, .stopAndPlayStartsOver:
            return String(localized: "Plays the book; it stops at its end anyway.",
                          comment: "VoiceOver hint and help tag of the sleep timer sheet's End of book button, for a book that stops at its end on its own, so the timer adds nothing there.")
        }
    }

    /// What VoiceOver announces as a timer is set for `duration`: where a
    /// timer for a place stops playback ("Sleep timer: stops at the end of
    /// this heading."), or the minutes a timer counts ("Timer set for 15
    /// minutes.", one sentence with its own plural forms).
    nonisolated static func announcement(forSetting duration: SleepTimerDuration) -> String {
        switch duration {
        case .minutes(let minutes):
            return String(localized: "Timer set for \(minutes) minutes.",
                          comment: "VoiceOver announcement after a sleep timer of so many minutes was set. %lld is the number of minutes.")
        case .endOfHeading, .endOfBook:
            return String(localized: "Sleep timer: \(duration.spokenStop ?? duration.displayName).",
                          comment: "VoiceOver announcement after a sleep timer that stops at a place was set. %@ says where it stops, such as \"stops at the end of this heading\".")
        }
    }

    /// What VoiceOver announces as Reset Timer restarts the timer, whose
    /// state `status` gives as `SleepTimerService.spokenStatus` reads it.
    nonisolated static func resetAnnouncement(status: String) -> String {
        String(localized: "Timer reset: \(status).",
               comment: "VoiceOver announcement after Reset Timer started the sleep timer again. %@ is the timer's state, such as \"15:00 remaining\" or \"stops at the end of the book\".")
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
/// makes it again each time it draws, about once a second while a book
/// plays, with new closures; closures cannot be compared, so without this
/// SwiftUI redrew the sheet every time. The closures are not compared: they
/// act on the presenter's state as it is when they run. Nor is the timer
/// service: a reader's is always its window's timer, the same for the
/// reader's whole life.
extension SleepTimerView: Equatable {
    nonisolated static func == (lhs: SleepTimerView, rhs: SleepTimerView) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.autoClose == rhs.autoClose
    }
}
