import SwiftUI

/// The unified sleep-timer sheet. One sheet, two sections:
///
/// 1. **New Timer** — always shown. Tapping a preset starts (or restarts)
///    the timer with that duration. If a timer is already running, the
///    underlying `SleepTimerService.start(...)` call replaces it — the
///    user's mental model is "set the timer to X minutes", not
///    "start a fresh timer if and only if none is running".
/// 2. **Current Timer** — visible only while a timer is running. Shows
///    the remaining time and exposes Reset (restart with the same
///    duration) and Cancel buttons.
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
    static let presetMinutes = [10, 15, 30, 45, 60]
    static let initialFocusPresetMinutes = presetMinutes[0]

    @ObservedObject var viewModel: ReaderViewModel
    @ObservedObject var sleepTimerService: SleepTimerService
    var onStartPlayback: (() -> Void)?
    /// Whether to dismiss the sheet after starting a NEW timer.
    /// Current-timer actions honor the same sheet auto-close policy so
    /// reset/restart behave the same way as a fresh timer selection.
    var autoClose: Bool = true

    @Environment(\.dismiss) private var dismiss

    @State private var customMinutes: Int = 30
    /// Unique identifier for this sheet instance. Other sheets close
    /// themselves when they receive a `sleepTimerSheetOpened`
    /// notification with a different ID — so only one timer sheet is
    /// ever open across all book windows.
    @State private var viewID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button("Back to Book") { dismiss() }
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

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .sleepTimerSheetOpened)) { notif in
            // Another sheet opened. If it's not us, dismiss ourselves.
            if let otherID = notif.userInfo?["sheetID"] as? UUID, otherID != viewID {
                dismiss()
            }
        }
    }

    // MARK: - Current Timer Section

    /// Shown while `sleepTimerService.isActive`. Heading, remaining time,
    /// Reset and Cancel buttons. The Reset/Cancel actions go through the
    /// view-model wrappers so they always touch the shared service via
    /// the same code path the timer sheet uses to arm a timer.
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
                    .accessibilityLabel("\(sleepTimerService.formattedRemaining) remaining")
            }

            HStack(spacing: 12) {
                Button("Reset Timer") {
                    viewModel.restartSleepTimer(startPlaybackIfNeeded: true)
                    viewModel.announceToVoiceOver(
                        "Timer reset. \(sleepTimerService.formattedRemaining) remaining."
                    )
                    if autoClose {
                        dismiss()
                    }
                }
                .accessibilityHint("Restart the timer with its original duration")

                Button("Cancel Timer", role: .destructive) {
                    viewModel.cancelSleepTimer()
                    viewModel.announceToVoiceOver("Sleep timer cancelled.")
                }
                .accessibilityHint("Stop the timer and discard the remaining time")
            }
        }
    }

    // MARK: - New Timer Section

    /// Always visible. Lists preset durations + a custom-minutes field +
    /// the heading-end / document-end options. Selecting any of these
    /// calls `viewModel.startSleepTimer(duration:startPlaybackIfNeeded:)`
    /// which ALWAYS replaces any timer already running — the sheet's UI
    /// for "set a new timer" is the same whether or not one is currently
    /// running.
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
                Button("\(minutes) minutes") {
                    setNewTimer(.minutes(minutes))
                }
                .accessibilityLabel("Set timer for \(minutes) minutes and start playing")
                // The top Back to Book control remains immediately
                // available, but opening the sheet places VoiceOver on the
                // first primary timer action instead of the dismiss action.
                .modifier(InitialVoiceOverFocusModifier(
                    isTarget: minutes == Self.initialFocusPresetMinutes,
                    delay: 0.2
                ))
            }

            // Custom duration
            HStack(spacing: 8) {
                Text("Custom:")
                TextField("Minutes", value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        customMinutes = max(1, min(customMinutes, 480))
                        setNewTimer(.minutes(customMinutes))
                    }
                    .accessibilityLabel("Custom timer minutes")
                    .accessibilityValue("\(customMinutes) minutes")
                    .accessibilityHint("Type a number or use the stepper arrows. Press Return to start the timer.")
                Stepper("", value: $customMinutes, in: 1...480, step: 5)
                    .labelsHidden()
                    .accessibilityLabel("Adjust minutes")
                    .accessibilityValue("\(customMinutes)")
                Text("min")
                    .foregroundColor(.secondary)

                Button("Set") {
                    customMinutes = max(1, min(customMinutes, 480))
                    setNewTimer(.minutes(customMinutes))
                }
                .accessibilityLabel("Set timer for \(customMinutes) minutes and start playing")
            }

            Button("End of current heading") {
                setNewTimer(.endOfHeading)
            }
            .accessibilityLabel("Stop at end of current heading and start playing")

            Button("End of document") {
                setNewTimer(.endOfDocument)
            }
            .accessibilityLabel("Stop at end of document and start playing")
        }
    }

    /// Start (or restart) the timer and optionally dismiss the sheet.
    /// Plays the book if it isn't already playing — the user clearly
    /// intends to read until the timer fires.
    private func setNewTimer(_ duration: SleepTimerDuration) {
        viewModel.startSleepTimer(duration: duration, startPlaybackIfNeeded: true)
        // Announce so VoiceOver users know the timer was set even if
        // the sheet auto-dismisses immediately.
        viewModel.announceToVoiceOver("Timer set for \(duration.displayName).")
        if autoClose {
            dismiss()
        }
    }
}

// MARK: - Notification Bridge

extension Notification.Name {
    /// Posted when any sleep-timer sheet appears. Other open sheets
    /// listen and dismiss themselves so only one is visible at a time
    /// across all book windows. UserInfo carries `sheetID: UUID`.
    static let sleepTimerSheetOpened = Notification.Name("sleepTimerSheetOpened")
}
