import Foundation

// MARK: - The Mac's words

/// The words of the Mac's Sleep Timer sheet that sit inline in its view,
/// `SleepTimerView`, held here for the phone's sheet, which is rebuilt for
/// the phone, since the Mac's redraws each second with a changing label (the
/// iPhone interface spec, "The Sleep Timer sheet"). Words the Mac's view
/// offers as statics are called there, not copied here.
/// `PhoneSleepTimerVocabularyTests` reads the Mac's source and requires each
/// word to be there as it is.
enum PhoneSleepTimerVocabulary {
    /// The sheet's title, read as its heading: the name of the button that
    /// opens it.
    static let title: String = PhoneReaderVocabulary.sleepTimer
    /// What Close does.
    static let closeHint = "Close the sleep timer and return to the book"
    /// The heading over the timer running.
    static let currentTimer = "Current Timer"
    /// The button that starts the running timer again from its whole length.
    static let resetTimer = "Reset Timer"
    /// What Reset Timer does.
    static let resetTimerHint = "Restart the timer with its original duration"
    /// The button that stops the running timer.
    static let cancelTimer = "Cancel Timer"
    /// What Cancel Timer does.
    static let cancelTimerHint = "Stop the timer and discard the remaining time"
    /// What VoiceOver says once Cancel Timer has stopped the timer.
    static let cancelled = "Sleep timer cancelled."
    /// The heading over the timers to set.
    static let newTimer = "New Timer"
    /// The note under New Timer while a timer runs.
    static let replacesCurrent = "Setting a new timer replaces the current one."
    /// The note under New Timer while none runs.
    static let pausePlaybackAfter = "Pause playback after:"
    /// The custom minutes field, as it shows.
    static let minutesField = "Minutes"
    /// What VoiceOver calls the custom minutes field.
    static let customMinutesLabel = "Custom timer minutes"
    /// The button that sets the custom timer, as it shows.
    static let set = "Set"
}

// MARK: - The sheet's timers

/// A timer the sheet offers, each a button of its own, for the focus it
/// lands on and the timer it sets.
enum PhoneSleepTimerChoice: Hashable, Sendable {
    /// A preset of so many minutes.
    case preset(minutes: Int)
    /// The custom timer's Set, for the minutes in its field.
    case custom
    /// The Mac's End of heading.
    case endOfHeading
    /// The Mac's End of book.
    case endOfBook
}

// MARK: - The sheet

/// What the phone's Sleep Timer sheet offers and decides (the iPhone
/// interface spec, "The Sleep Timer sheet"), in the Mac's words: the
/// presets, the custom timer's limits and words, where focus lands, what is
/// said once a timer is set, and the reader's "Off".
enum PhoneSleepTimerModel {
    /// The presets, the Mac's: 10, 15, 30, 45, and 60 minutes.
    static let presetMinutes = SleepTimerView.presetMinutes

    /// The fewest and most minutes the custom timer takes, the Mac's.
    static let customMinutesRange = 1...480

    /// The custom minutes the field starts at when the last timer used
    /// wasn't a custom one, the Mac's.
    static let defaultCustomMinutes = 30

    /// The custom field's hint on the phone, which has no Return key to
    /// name: the Mac's sentence, with its last clause made the phone's (the
    /// spec, "The Sleep Timer sheet" and "Words that say Mac").
    static let customMinutesHint =
        "Type the minutes, or change them \(SleepTimerView.customMinutesStep) at a time with "
            + "\(SleepTimerView.adjustMinutesLabel). Set sets the timer and starts playing."

    /// The reader's Sleep Timer value while no timer runs: the spec's new
    /// word "Off".
    static let offValue = "Off"

    /// The reader's Sleep Timer value: "Off", or the Mac's spoken status
    /// ("4:59 remaining", "stops at the end of this heading", "fading
    /// out"), as `SleepTimerService.spokenStatus` reads it.
    static func readerValue(isActive: Bool, spokenStatus: String) -> String {
        isActive && !spokenStatus.isEmpty ? spokenStatus : offValue
    }

    /// The note under New Timer: the Mac's, by whether a timer runs.
    static func newTimerNote(isActive: Bool) -> String {
        isActive ? PhoneSleepTimerVocabulary.replacesCurrent : PhoneSleepTimerVocabulary.pausePlaybackAfter
    }

    /// The minutes the custom timer takes from what was typed: the Mac's
    /// limits, 1 to 480, and nil for a field holding no whole number.
    static func customMinutes(typed text: String) -> Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return clampedCustomMinutes(minutes)
    }

    /// `minutes` held to the custom timer's limits, as the Mac holds them.
    static func clampedCustomMinutes(_ minutes: Int) -> Int {
        min(max(minutes, customMinutesRange.lowerBound), customMinutesRange.upperBound)
    }

    /// The choice VoiceOver's focus lands on as the sheet opens: the last
    /// timer used, so a nightly timer is one double-tap. A number of minutes
    /// no preset has is the custom timer's, its field holding them; with no
    /// timer used yet, the Mac's first preset.
    static func openingFocus(lastUsed: SleepTimerDuration?) -> PhoneSleepTimerChoice {
        switch lastUsed {
        case .minutes(let minutes)?:
            return presetMinutes.contains(minutes) ? .preset(minutes: minutes) : .custom
        case .endOfHeading?:
            return .endOfHeading
        case .endOfBook?:
            return .endOfBook
        case nil:
            return .preset(minutes: SleepTimerView.initialFocusPresetMinutes)
        }
    }

    /// The minutes the custom field starts at: the last timer's, when it was
    /// a custom one, so Set repeats it; else the Mac's 30.
    static func openingCustomMinutes(lastUsed: SleepTimerDuration?) -> Int {
        guard case .minutes(let minutes)? = lastUsed, !presetMinutes.contains(minutes) else {
            return defaultCustomMinutes
        }
        return clampedCustomMinutes(minutes)
    }

    /// The timer `choice` sets, the custom one for `customMinutes`.
    static func duration(of choice: PhoneSleepTimerChoice, customMinutes: Int) -> SleepTimerDuration {
        switch choice {
        case .preset(let minutes): return .minutes(minutes)
        case .custom: return .minutes(clampedCustomMinutes(customMinutes))
        case .endOfHeading: return .endOfHeading
        case .endOfBook: return .endOfBook
        }
    }

    /// What VoiceOver calls `choice`'s button, the Mac's: "Set timer for 15
    /// minutes and start playing", or "Stop at the end of this heading and
    /// start playing".
    static func label(of choice: PhoneSleepTimerChoice, customMinutes: Int) -> String {
        switch choice {
        case .preset(let minutes): return SleepTimerView.setTimerLabel(minutes: minutes)
        case .custom: return SleepTimerView.setTimerLabel(minutes: clampedCustomMinutes(customMinutes))
        case .endOfHeading: return SleepTimerView.endOfHeadingLabel
        case .endOfBook: return SleepTimerView.endOfBookLabel
        }
    }

    /// What VoiceOver says once a timer for `duration` is set, the Mac's:
    /// "Timer set for 15 minutes.", or "Sleep timer: stops at the end of
    /// this heading.". The phone says it once the sheet has closed, and then
    /// the book starts, so the words aren't lost under it.
    static func setAnnouncement(_ duration: SleepTimerDuration) -> String {
        SleepTimerView.announcement(forSetting: duration)
    }

    /// The longest the book waits for that sentence to be said before it
    /// starts anyway, in seconds: VoiceOver says when an announcement ends,
    /// but a notice that never comes mustn't leave the book silent.
    static let longestWaitBeforePlaying: TimeInterval = 4
}
