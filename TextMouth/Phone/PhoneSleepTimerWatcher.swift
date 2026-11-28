import Combine
import Foundation

/// Whether a sleep timer runs for the open reader (FR51, FR52), republished
/// when that changes and not as the timer counts down, so the reader's
/// screen redraws only as the timer starts or ends, as the reader's unlock
/// watcher republishes only its prompt.
///
/// As the timer ends, the Sleep Timer under Play leaves the screen; if
/// VoiceOver's focus was on it, focus goes to Play once the control has gone,
/// rather than VoiceOver dropping it at the top of the screen
/// (`PhoneReaderControl.focusTarget`).
///
/// A timer started again (Reset Timer on the control's Actions rotor, the
/// Restart Sleep Timer shortcut, or a new timer set over the running one)
/// stops for an instant first (`SleepTimerService.start` stops the old timer
/// before it starts the new one), so the watcher sees "ended" and then "runs"
/// in the same turn. Focus must stay on the control then: the move to Play is
/// skipped when, at its moment, a timer runs again (FR55).
///
/// Shared code, with VoiceOver's side handed in, so the Mac's test host checks
/// it (`PhoneReaderModelTests`); the reader's screen gives it the focus
/// registry (`PhoneSleepTimerWatcher.onTheReader()`).
@MainActor
final class PhoneSleepTimerWatcher: ObservableObject {
    /// Whether a timer runs.
    @Published private(set) var runs = false
    /// The subscription to the timer's `isActive`.
    private var subscription: AnyCancellable?
    /// Whether VoiceOver's focus is on the Sleep Timer under Play now.
    private let isFocusedOnTimer: @MainActor () -> Bool
    /// Asks for focus on a control a moment later, unless the closure handed
    /// in says, at that moment, to leave focus where it is.
    private let requestFocus: @MainActor (_ kind: PhoneControlKind, _ unless: @escaping @MainActor () -> Bool) -> Void

    /// A watcher that reads VoiceOver's focus with `isFocusedOnTimer` and
    /// moves it with `requestFocus`.
    init(
        isFocusedOnTimer: @escaping @MainActor () -> Bool,
        requestFocus: @escaping @MainActor (_ kind: PhoneControlKind, _ unless: @escaping @MainActor () -> Bool) -> Void
    ) {
        self.isFocusedOnTimer = isFocusedOnTimer
        self.requestFocus = requestFocus
    }

    /// Watches `timer`, the open reader's sleep timer, or nothing.
    func watch(_ timer: SleepTimerService?) {
        runs = timer?.isActive ?? false
        subscription = timer?.$isActive
            .removeDuplicates()
            .sink { [weak self, weak timer] isActive in
                // `$isActive` publishes just before the change, with the new value.
                MainActor.assumeIsolated { self?.timerChanged(runs: isActive, timer: timer) }
            }
    }

    /// The timer started or ended. Whether focus was on the control is asked
    /// here, before the screen redraws, while the control is still there to
    /// ask; whether the timer runs again is asked when focus would move.
    private func timerChanged(runs isActive: Bool, timer: SleepTimerService?) {
        let focusWasOnTimer = runs && !isActive && isFocusedOnTimer()
        runs = isActive
        guard focusWasOnTimer else { return }
        let target = PhoneReaderControl.focusTarget(returningTo: .sleepTimer, timerRuns: false)
        requestFocus(target.focusKind) { [weak timer] in timer?.isActive == true }
    }
}
