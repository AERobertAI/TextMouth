import AVFoundation
import Foundation

// The decisions of the phone's Settings screen, in plain types the Mac's test
// host can run (the iPhone interface spec, under "Settings"): what the screen
// holds and in what order, what each control says, what each step does, and
// what is offered. `PhoneSettingsView`, on iOS, only reads them.

/// The Mac's words, which nearly every declaration below reads.
private typealias Words = PhoneSettingsVocabulary

// MARK: - Sections

/// The screen's sections, in the spec's order as its outside reviews left it
/// on November 7: Navigation, with the phone's units for each kind of book,
/// takes the place of the Mac's Skip Controls, and Reading, new, follows
/// Sleep Timer. The view draws them in this order, so a test of this list is
/// a test of the screen's.
enum PhoneSettingsSection: CaseIterable, Identifiable {
    case voice
    case navigation
    case rewindOnResume
    case punctuationPauses
    case endOfBook
    case sleepTimer
    case reading
    case times
    case pages
    case removalBehavior
    case statistics
    case about

    var id: Self { self }

    /// The section's heading, the Mac's name for the group where it has one.
    var title: String {
        switch self {
        case .voice: return Words.voice.rawValue
        case .navigation: return Words.navigation.rawValue
        case .rewindOnResume: return Words.rewindOnResume.rawValue
        case .punctuationPauses: return Words.punctuationPauses.rawValue
        case .endOfBook: return Words.endOfBook.rawValue
        case .sleepTimer: return Words.sleepTimer.rawValue
        case .times: return ReaderTimeWording.settingSection
        case .pages: return ReaderPageWording.settingSection
        case .reading: return PhoneSettingsWording.readingSection
        case .removalBehavior: return Words.removalBehavior.rawValue
        case .statistics: return PhoneSettingsWording.statisticsSection
        case .about: return PhoneSettingsWording.aboutSection
        }
    }
}

// MARK: - Rows That Open Something

/// A row that opens something over the screen, or pushes something on it, so
/// VoiceOver's focus must come back to it afterwards: "Sheets and menus don't
/// return focus by themselves" (the spec, under "Focus on arrival and
/// return").
enum PhoneSettingsRow: Hashable, Identifiable {
    case language
    case voice
    case textNavigationUnit
    case audioNavigationUnit
    case rewindTo
    case endOfBook
    case readingStatistics
    case shareLogs

    var id: Self { self }

    /// The words on the row, and the title of the sheet of choices it opens.
    var title: String {
        switch self {
        case .language: return Words.language.rawValue
        case .voice: return Words.voice.rawValue
        case .textNavigationUnit: return PhoneSettingsWording.textNavigationUnit
        case .audioNavigationUnit: return PhoneSettingsWording.audioNavigationUnit
        case .rewindTo: return Words.rewindTo.rawValue
        case .endOfBook: return Words.whenBookEnds.rawValue
        case .readingStatistics: return PhoneSettingsWording.readingStatistics
        case .shareLogs: return PhoneSettingsWording.shareLogs
        }
    }

    /// What VoiceOver calls the row: the Mac's label where it has one of its
    /// own, as "Select voice" for the row showing "Voice".
    var label: String {
        switch self {
        case .language: return Words.voiceLanguage.rawValue
        case .voice: return Words.selectVoice.rawValue
        case .rewindTo: return Words.rewindOnResumeUnit.rawValue
        case .endOfBook: return Words.endOfBookBehavior.rawValue
        case .textNavigationUnit, .audioNavigationUnit, .readingStatistics, .shareLogs: return title
        }
    }

    /// What the row does, when the spec gives a hint for it.
    var hint: String? {
        switch self {
        case .voice: return Words.selectVoiceHint.rawValue
        case .textNavigationUnit, .audioNavigationUnit: return PhoneSettingsWording.navigationUnitHint
        case .rewindTo: return Words.rewindToHint.rawValue
        case .endOfBook: return Words.endOfBookHint.rawValue
        case .shareLogs: return PhoneSettingsWording.shareLogsHint
        case .language, .readingStatistics: return nil
        }
    }
}

// MARK: - Sliders and Steppers

/// A setting changed in steps, by a slider or a stepper: what it says, and
/// what one step does.
///
/// The view makes each one a single adjustable element for VoiceOver, whose
/// flick up or down moves one step, so the step isn't left to the control: a
/// slider's flick commonly moves 10 percent otherwise (REPORTED, AppleVis, in
/// the spec's research).
struct PhoneSettingsAdjustment: Sendable {
    /// Which way a step goes.
    enum Direction: Sendable {
        case up
        case down
    }

    /// What VoiceOver calls the control, and the words shown beside its value.
    let label: String
    /// The Mac's caption: shown under the control, and said once, as its hint
    /// (the Mac's rule: "VoiceOver hears it once").
    let hint: String
    /// The values the control can reach: the Mac's, from `SettingsPolicy`.
    let range: ClosedRange<Double>
    /// The size of a step. The Mac spells its steps inline in its views, and
    /// `PhoneSettingsModelTests` pins these to them.
    let step: Double
    /// The value with its unit, as the control's value and on the screen.
    let words: @Sendable (Double) -> String

    /// The value one step from `value` in `direction`, on the control's grid
    /// of steps, and never outside its range. A value between two steps, as
    /// config.json can hold, moves to the nearer step in that direction, so
    /// no step is lost.
    func value(after value: Double, going direction: Direction) -> Double {
        // The count of steps is tidied before it is rounded, since a value
        // such as 1.1 isn't exactly a whole number of 0.1s from 0.5 in binary,
        // and rounding up a count of 6.000000000000001 would lose a step.
        let stepsFromTheBottom = Self.tidied((value - range.lowerBound) / step)
        let target = direction == .up
            ? stepsFromTheBottom.rounded(.down) + 1
            : stepsFromTheBottom.rounded(.up) - 1
        // The result is tidied too, so a step lands on 1.2, not on
        // 1.2000000000000002.
        let moved = Self.tidied(range.lowerBound + target * step)
        return min(max(moved, range.lowerBound), range.upperBound)
    }

    /// `value` to six decimal places, far finer than any step here.
    private static func tidied(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    /// "Default speed": 50 to 650 words per minute, in steps of 25.
    static let defaultSpeed = PhoneSettingsAdjustment(
        label: Words.defaultSpeed.rawValue,
        hint: Words.defaultSpeedCaption.rawValue,
        range: SettingsPolicy.wordsPerMinute.range,
        step: 25,
        words: { PhoneVoiceVocabulary.speedValue(wordsPerMinute: $0) }
    )

    /// "Default pitch": 0.5 to 2.0, in steps of a tenth, named as the Mac's
    /// reader and settings name it: "Normal (1.0x)", "1.5x".
    static let defaultPitch = PhoneSettingsAdjustment(
        label: Words.defaultPitch.rawValue,
        hint: Words.defaultPitchCaption.rawValue,
        range: SettingsPolicy.pitchMultiplier.range,
        step: 0.1,
        words: { SpeechService.pitchLabel($0) }
    )

    /// "Minimum pause threshold": 5 to 600 seconds, in steps of 5.
    static let minimumPause = PhoneSettingsAdjustment(
        label: Words.minimumPauseThreshold.rawValue,
        hint: Words.minimumPauseCaption.rawValue,
        range: SettingsPolicy.rewindSmartThreshold.range,
        step: 5,
        words: { CountWording.seconds(Int($0)) }
    )

    /// "Punctuation pause level": "Off", "Subtle", "Moderate", or "Heavy".
    static let punctuationPauseLevel = PhoneSettingsAdjustment(
        label: Words.punctuationPauseLevel.rawValue,
        hint: Words.punctuationPauseCaption.rawValue,
        range: SettingsPolicy.punctuationPauseLevel.range,
        step: 1,
        words: { level in
            let names: [PhoneSettingsVocabulary] = [.off, .subtle, .moderate, .heavy]
            // The setting's own accessor keeps the level in range; the bounds
            // here mean a level from anywhere names something rather than traps.
            return names[min(max(Int(level), 0), names.count - 1)].rawValue
        }
    )

    /// "Fade out duration": "Off", or 1 to 10 seconds, as the Mac counts them.
    static let fadeOutDuration = PhoneSettingsAdjustment(
        label: Words.fadeOutDuration.rawValue,
        hint: Words.fadeOutCaption.rawValue,
        range: SettingsPolicy.sleepFadeOutDuration.range,
        step: 1,
        words: { PlaybackSettingsView.fadeOutText($0) }
    )
}

// MARK: - Switches

/// A setting that is on or off: what its switch says.
struct PhoneSettingsSwitch: Sendable {
    /// The words shown beside the switch.
    let title: String
    /// What VoiceOver calls the switch: the title, unless the Mac has a label
    /// of its own, as "Smart rewind mode" for "Smart mode".
    let label: String
    /// What the switch does, when the spec gives a hint for it.
    let hint: String?
    /// Whether the hint also stands under the switch for the eye, hidden from
    /// VoiceOver, which hears it once, as the hint (the Mac's rule).
    let showsHintAsCaption: Bool

    /// A switch called `label` by VoiceOver, or `title` when `label` is nil.
    init(title: String, label: String? = nil, hint: String? = nil, showsHintAsCaption: Bool = false) {
        self.title = title
        self.label = label ?? title
        self.hint = hint
        self.showsHintAsCaption = showsHintAsCaption
    }

    /// Under Rewind on Resume.
    static let smartMode = PhoneSettingsSwitch(
        title: Words.smartMode.rawValue,
        label: Words.smartRewindMode.rawValue,
        hint: Words.smartModeHint.rawValue
    )

    /// Under Navigation.
    static let autoPlayAfterNavigation = PhoneSettingsSwitch(
        title: Words.autoPlayAfterNavigation.rawValue,
        hint: Words.autoPlayHint.rawValue,
        showsHintAsCaption: true
    )

    /// Under Sleep Timer.
    static let closeSleepTimerSheet = PhoneSettingsSwitch(
        title: Words.closeSleepTimerSheet.rawValue,
        hint: Words.closeSleepTimerSheetHint.rawValue
    )

    /// Under Times.
    static let includeSpeedWithTimes = PhoneSettingsSwitch(
        title: ReaderTimeWording.settingTitle,
        hint: ReaderTimeWording.settingHint,
        showsHintAsCaption: true
    )

    /// Under Pages.
    static let showPageInReader = PhoneSettingsSwitch(
        title: ReaderPageWording.showInReaderTitle,
        hint: ReaderPageWording.showInReaderHint,
        showsHintAsCaption: true
    )

    /// Under Pages.
    static let sayPageInWhereAmI = PhoneSettingsSwitch(
        title: ReaderPageWording.sayInWhereAmITitle,
        hint: ReaderPageWording.sayInWhereAmIHint,
        showsHintAsCaption: true
    )

    /// Under Reading: the phone's own, from the spec's outside reviews.
    static let followInBraille = PhoneSettingsSwitch(
        title: PhoneSettingsWording.followInBraille,
        hint: PhoneSettingsWording.followInBrailleHint,
        showsHintAsCaption: true
    )

    /// Under Removal Behavior. The Mac's hint for it isn't used: it offers
    /// keeping the files in the library folder, which a phone's removal
    /// doesn't (the spec, under "Removing a book"), and the spec gives none.
    static let confirmBeforeRemoving = PhoneSettingsSwitch(title: Words.confirmBeforeRemoving.rawValue)
}

// MARK: - Voices

/// What the Voice row offers, and what it says.
struct PhoneSettingsVoiceOffer {
    /// The voices to choose from, each by its identifier, in the order given.
    let choices: [PhoneChoice<String>]
    /// The row's value: the current voice, or the sentence for no voices.
    let rowValue: String
    /// Whether the row opens its sheet. It doesn't when there is nothing to
    /// choose: it stays in its place, dimmed, saying why, so nothing moves.
    let canOpen: Bool

    /// - Parameters:
    ///   - current: The voice chosen, or nil when it names no voice here.
    ///   - forLanguage: The voices of the language chosen.
    ///   - installed: Every voice, of any language.
    ///   - hasListed: Whether the voices have been listed yet. Before the
    ///     first list arrives, an empty list means nothing, so the row still
    ///     opens, and its sheet fills as the list arrives.
    init(
        current: PhoneVoiceOption?,
        forLanguage: [PhoneVoiceOption],
        installed: [PhoneVoiceOption],
        hasListed: Bool
    ) {
        let usableForLanguage = forLanguage.filter { !$0.isPersonalVoice }
        // A language with no voices of its own still offers the other
        // languages' voices. Saying none are installed would be false, and a
        // sheet with nothing in it would be a dead end.
        let offered = usableForLanguage.isEmpty ? installed.filter { !$0.isPersonalVoice } : usableForLanguage
        let hasNothingToOffer = hasListed && offered.isEmpty

        choices = offered.map { PhoneChoice(id: $0.identifier, label: $0.choiceLabel) }
        canOpen = !hasNothingToOffer
        rowValue = hasNothingToOffer ? PhoneVoiceWording.noVoices : current?.choiceLabel ?? ""
    }
}

// MARK: - The Screen's Other Decisions

/// The screen's decisions that belong to no one row.
enum PhoneSettingsModel {
    // MARK: Language

    /// A language's name, as the Language row and its choices say it: "All"
    /// for the empty code, otherwise the name in `locale`, or the code itself
    /// when the system has no name for it.
    static func languageName(_ code: String, locale: Locale = .current) -> String {
        code.isEmpty ? Words.allLanguages.rawValue : locale.localizedString(forLanguageCode: code) ?? code
    }

    /// The Language row's choices: "All", whose code is empty, then the
    /// languages offered, in the Mac's order.
    static func languageChoices(_ languages: [String], locale: Locale = .current) -> [PhoneChoice<String>] {
        ([""] + languages).map { PhoneChoice(id: $0, label: languageName($0, locale: locale)) }
    }

    /// Makes `code` the language chosen and offers its voices, as the Mac's
    /// Language picker does. The voice chosen stays, as on the Mac: a language
    /// only narrows what is offered.
    @MainActor
    static func chooseLanguage(_ code: String, in settings: SettingsViewModel) {
        settings.selectedLanguage = code
        settings.refreshVoices()
    }

    // MARK: Fixed Lists

    /// The units a text book can move by, in the Mac's order: every one.
    static let textNavigationUnits: [SkipUnit] = SkipUnit.allCases

    /// The units an audiobook can move by, in the Mac's order: every one but
    /// Sentence and Paragraph, since an audiobook has no text to stop at (the
    /// spec, under "Navigation unit").
    static let audioNavigationUnits: [SkipUnit] = SkipUnit.allCases.filter { $0 != .sentence && $0 != .paragraph }

    /// The unit the Navigation unit for text books row says and its sheet
    /// marks: the one kept in `preferences`, as a text book with none of its
    /// own takes it (`PhoneDefaults.navigationUnit`).
    @MainActor
    static func textNavigationUnit(in preferences: UserDefaults) -> SkipUnit {
        PhoneDefaults.navigationUnit(ownRawValue: nil, isAudio: false, offered: textNavigationUnits, in: preferences)
    }

    /// The unit the Navigation unit for audiobooks row says and its sheet
    /// marks: the one kept, as an audiobook with none of its own takes it, so
    /// a kept unit it can't move by, such as Sentence, says its default.
    @MainActor
    static func audioNavigationUnit(in preferences: UserDefaults) -> SkipUnit {
        PhoneDefaults.navigationUnit(ownRawValue: nil, isAudio: true, offered: audioNavigationUnits, in: preferences)
    }

    /// The Navigation unit for text books row's choices.
    static var textNavigationUnitChoices: [PhoneChoice<SkipUnit>] { choices(of: textNavigationUnits) }

    /// The Navigation unit for audiobooks row's choices.
    static var audioNavigationUnitChoices: [PhoneChoice<SkipUnit>] { choices(of: audioNavigationUnits) }

    /// The Rewind to row's choices, in the Mac's order.
    static var rewindChoices: [PhoneChoice<RewindUnit>] { choices(of: RewindUnit.allCases) }

    /// The When book ends row's choices, in the Mac's order.
    static var endOfBookChoices: [PhoneChoice<EndOfBookBehavior>] { choices(of: EndOfBookBehavior.allCases) }

    /// A choice for each of `cases`, named by its raw value, as the Mac's
    /// pickers name them.
    private static func choices<Choice>(of cases: [Choice]) -> [PhoneChoice<Choice>]
    where Choice: Hashable & RawRepresentable, Choice.RawValue == String {
        cases.map { PhoneChoice(id: $0, label: $0.rawValue) }
    }

    // MARK: What Applies Now

    /// Whether Smart mode does anything now: not while nothing is rewound.
    /// The Mac hides the switch then. On the phone it stays in place, dimmed,
    /// since controls don't appear or vanish (the spec's fifth principle).
    static func isSmartModeAvailable(rewindUnit: RewindUnit) -> Bool {
        rewindUnit != .none
    }

    /// Whether the minimum pause does anything now: only while Smart mode
    /// does and is on. Dimmed otherwise, for the same reason.
    static func isMinimumPauseAvailable(rewindUnit: RewindUnit, smartMode: Bool) -> Bool {
        isSmartModeAvailable(rewindUnit: rewindUnit) && smartMode
    }

    // MARK: Preview

    /// What Preview Voice speaks, as the Mac's does: its sentence, in the
    /// voice chosen, at the default speed and pitch. Making one plays nothing.
    @MainActor
    static func previewUtterance(voiceID: String, wordsPerMinute: Double, pitch: Double) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: Words.previewSentence.rawValue)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        utterance.rate = SpeechService.rateForWPM(wordsPerMinute)
        utterance.pitchMultiplier = Float(SpeechService.clampedPitch(pitch))
        return utterance
    }
}
