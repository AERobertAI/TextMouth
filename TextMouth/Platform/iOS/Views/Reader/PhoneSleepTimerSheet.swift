import Combine
import SwiftUI
import UIKit

/// The phone's Sleep Timer sheet (the iPhone interface spec, "The Sleep
/// Timer sheet"), rebuilt with the Mac's words: Close; the Current Timer,
/// while one runs, with its status, Reset Timer, and Cancel Timer; New Timer,
/// with the presets and a custom timer; and Stop At. Focus lands on the last
/// timer used.
///
/// The Mac's sheet redraws each second with a changing label, which the
/// spec's principle 3 forbids: here nothing focusable changes as the timer
/// counts. The status is read when VoiceOver asks for it, and the sheet hears
/// only whether a timer runs.
struct PhoneSleepTimerSheet: View {
    /// The reader the timer pauses, whose functions set and stop it.
    let reader: ReaderViewModel
    /// What the sheet leaves to say, and to start, once it has closed.
    let farewell: PhoneSheetFarewell

    /// Whether a timer runs, republished only when that changes.
    @State private var isActive: Bool
    /// What the custom field holds.
    @State private var customText: String
    /// Where VoiceOver's focus is asked to go.
    @AccessibilityFocusState private var focus: PhoneSleepTimerChoice?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`.
    init(reader: ReaderViewModel, farewell: PhoneSheetFarewell) {
        self.reader = reader
        self.farewell = farewell
        _isActive = State(initialValue: reader.sleepTimerService.isActive)
        let minutes = PhoneSleepTimerModel.openingCustomMinutes(lastUsed: reader.sleepTimerService.lastUsedDuration)
        _customText = State(initialValue: String(minutes))
    }

    /// The timer service, which every reader shares.
    private var service: SleepTimerService {
        reader.sleepTimerService
    }

    /// The custom timer's minutes: what the field holds, within the Mac's
    /// limits, or the Mac's 30 while it holds no number.
    private var customMinutes: Int {
        PhoneSleepTimerModel.customMinutes(typed: customText) ?? PhoneSleepTimerModel.defaultCustomMinutes
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if isActive {
                        currentTimer
                    }
                    newTimer
                    stopAt
                }
                .task {
                    let target = PhoneSleepTimerModel.openingFocus(lastUsed: service.lastUsedDuration)
                    PhoneListFocus.focus(target, proxy: proxy, state: $focus)
                }
            }
            .navigationTitle(PhoneSleepTimerVocabulary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneAppWording.close, hint: PhoneSleepTimerVocabulary.closeHint) {
                    dismiss()
                }
            }
            // Only whether a timer runs, never its seconds, and on the main
            // queue, as every observer of the phone's is.
            .onReceive(service.$isActive.removeDuplicates().receive(on: DispatchQueue.main)) { running in
                isActive = running
            }
        }
    }

    // MARK: The sections

    /// The timer running: its status, read when VoiceOver asks, then Reset
    /// Timer and Cancel Timer.
    private var currentTimer: some View {
        Section {
            ZStack(alignment: .leading) {
                // For sight: the time left, redrawn each second, hidden from
                // VoiceOver, which reads the element over it.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(service.formattedRemaining)
                        .font(.system(.title3, design: .monospaced))
                        .accessibilityHidden(true)
                }
                PhoneTimerStatus { [service] in service.spokenLabel }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            PhoneActionButton(title: PhoneSleepTimerVocabulary.resetTimer, action: reset)
                .accessibilityHint(PhoneSleepTimerVocabulary.resetTimerHint)
            PhoneActionButton(title: PhoneSleepTimerVocabulary.cancelTimer, role: .destructive, action: cancel)
                .accessibilityHint(PhoneSleepTimerVocabulary.cancelTimerHint)
        } header: {
            Text(PhoneSleepTimerVocabulary.currentTimer)
                .phoneSecondaryText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The note, the presets, and the custom timer.
    private var newTimer: some View {
        Section {
            Text(PhoneSleepTimerModel.newTimerNote(isActive: isActive))
            ForEach(PhoneSleepTimerModel.presetMinutes, id: \.self) { minutes in
                timerButton(.preset(minutes: minutes), title: SleepTimerDuration.minutes(minutes).displayName)
            }
            TextField(PhoneSleepTimerVocabulary.minutesField, text: $customText)
                .keyboardType(.numberPad)
                .accessibilityLabel(PhoneSleepTimerVocabulary.customMinutesLabel)
                .accessibilityHint(PhoneSleepTimerModel.customMinutesHint)
            Stepper(
                SleepTimerView.adjustMinutesLabel,
                value: Binding(get: { customMinutes }, set: { customText = String($0) }),
                in: PhoneSleepTimerModel.customMinutesRange,
                step: SleepTimerView.customMinutesStep
            )
            .accessibilityValue(CountWording.minutes(customMinutes))
            timerButton(.custom, title: PhoneSleepTimerVocabulary.set)
        } header: {
            Text(PhoneSleepTimerVocabulary.newTimer)
                .phoneSecondaryText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// End of heading and End of book, each with the Mac's label and hint.
    private var stopAt: some View {
        Section {
            timerButton(.endOfHeading, title: SleepTimerView.endOfHeadingTitle)
                .accessibilityHint(SleepTimerView.endOfHeadingHint)
            timerButton(.endOfBook, title: SleepTimerView.endOfBookTitle)
                .accessibilityHint(SleepTimerView.endOfBookHint(for: reader.effectiveEndOfBookBehavior))
        } header: {
            Text(SleepTimerView.stopAtHeading)
                .phoneSecondaryText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The button that sets `choice`, shown as `title`, read by the Mac's
    /// label.
    private func timerButton(_ choice: PhoneSleepTimerChoice, title: String) -> some View {
        PhoneActionButton(title: title) { set(choice) }
            .accessibilityLabel(PhoneSleepTimerModel.label(of: choice, customMinutes: customMinutes))
            .accessibilityFocused($focus, equals: choice)
            .id(choice)
    }

    // MARK: What the buttons do

    /// Whether the sheet closes once a timer is set or reset: the Mac's
    /// setting, Close sheet after setting timer.
    private var closesAfterSetting: Bool {
        reader.settingsViewModel.sleepTimerAutoClose
    }

    /// Sets the timer `choice` names, replacing any that runs, then says the
    /// Mac's "Timer set for 15 minutes." and only then starts the book, so
    /// the words aren't lost under it: once the sheet has closed, or at once
    /// when the Mac's setting keeps it open.
    private func set(_ choice: PhoneSleepTimerChoice) {
        let duration = PhoneSleepTimerModel.duration(of: choice, customMinutes: customMinutes)
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.startSleepTimer(duration: duration, startPlaybackIfNeeded: false)
        }
        let words = [PhoneSleepTimerModel.setAnnouncement(duration)] + said.map(\.message)
        let startBook: @MainActor () -> Void = { [reader] in reader.playUnlessUnderWay() }
        if closesAfterSetting {
            farewell.keep(words)
            farewell.keepStartingTheBook(startBook)
            dismiss()
        } else {
            PhoneSheetFarewell.say(words, thenRun: startBook)
        }
    }

    /// Starts the running timer again from its whole length, as the Mac's
    /// Reset Timer does, playing the book as it does, and says the Mac's
    /// "Timer reset: 15:00 remaining."
    private func reset() {
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.restartSleepTimer(startPlaybackIfNeeded: true)
        }
        let words = [SleepTimerView.resetAnnouncement(status: service.spokenStatus)] + said.map(\.message)
        if closesAfterSetting {
            farewell.keep(words)
            dismiss()
        } else {
            PhoneSheetFarewell.say(words, thenRun: nil)
        }
    }

    /// Stops the running timer, says the Mac's "Sleep timer cancelled.", and,
    /// since Cancel Timer goes with the Current Timer, puts focus on the last
    /// timer used, as on arrival.
    private func cancel() {
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.cancelSleepTimer()
        }
        isActive = false
        PhoneSheetFarewell.say([PhoneSleepTimerVocabulary.cancelled] + said.map(\.message), thenRun: nil)
        let target = PhoneSleepTimerModel.openingFocus(lastUsed: service.lastUsedDuration)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = target
        }
    }
}

/// The running timer's status as one element, its words asked for at the
/// moment VoiceOver reads it, so the element never changes under VoiceOver's
/// cursor as the timer counts (the spec, "computed when focused").
///
/// A UIKit view, since SwiftUI's label is a value set when the view draws,
/// while UIKit's `accessibilityLabel` is a property VoiceOver reads when it
/// needs it (Apple's UIAccessibility documentation).
private struct PhoneTimerStatus: UIViewRepresentable {
    /// The status, asked for each time VoiceOver reads it.
    let status: @MainActor () -> String

    /// Makes the element.
    func makeUIView(context: Context) -> StatusView {
        StatusView(status: status)
    }

    /// Gives the element the newest way to ask for the status.
    func updateUIView(_ view: StatusView, context: Context) {
        view.status = status
    }

    /// The element: static text whose label is asked for when read.
    final class StatusView: UIView {
        /// The status, asked for each time VoiceOver reads it.
        var status: @MainActor () -> String

        /// An element reading `status`.
        init(status: @escaping @MainActor () -> String) {
            self.status = status
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityTraits = .staticText
        }

        /// Never made from a storyboard.
        required init?(coder: NSCoder) {
            nil
        }

        /// The status as VoiceOver reads it now, as "Sleep timer: 4:59
        /// remaining".
        override var accessibilityLabel: String? {
            get { status() }
            set { _ = newValue }
        }
    }
}
