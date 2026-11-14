import SwiftUI

/// The sleep timer's status in the reader's status row and playback bar:
/// "4:59" with a moon, and "Sleep timer: 4:59 remaining" to VoiceOver, drawn
/// while the timer runs and nothing otherwise.
///
/// It observes the window's timer itself. The reader's views used to read the
/// timer without observing it, and the countdown moved only because the reader
/// published eight times a second as its place moved. The reader publishes
/// only when what its window shows changes now (`ReaderShownState`), about
/// once a second, and the countdown must move every second whether the book
/// plays or is paused. So this small view is the one that follows the timer:
/// a tick draws it and nothing else, where observing the timer in the reader's
/// views would draw the whole window each second (`WindowSleepTimerHolder`).
///
/// The layout is the caller's, so the status row and the playback bar keep the
/// look each has; this view only decides whether the timer is showing and
/// reads it afresh at each change.
struct SleepTimerStatusLabel<Content: View>: View {
    /// The window's sleep timer, observed so a tick, a start, and a stop
    /// draw this view.
    @ObservedObject var timer: SleepTimerService
    /// Draws the timer's status while it is active; reads what it shows from
    /// the timer it is given, every time this view draws.
    let content: (SleepTimerService) -> Content

    /// The status of `timer`, laid out by `content`.
    init(timer: SleepTimerService, @ViewBuilder content: @escaping (SleepTimerService) -> Content) {
        self.timer = timer
        self.content = content
    }

    var body: some View {
        let _ = ViewBodyCounter.record("SleepTimerStatusLabel")
        if timer.isActive {
            content(timer)
        }
    }
}
