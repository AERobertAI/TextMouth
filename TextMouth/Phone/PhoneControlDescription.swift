import Foundation

/// The traits a reader control has, as VoiceOver hears them. A plain set of
/// the phone's own, since UIKit's `UIAccessibilityTraits` doesn't exist on the
/// Mac, where these are tested; `PhoneControl`, on iOS, maps each one to
/// UIKit's trait of the same name.
struct PhoneControlTraits: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// Activating it does something: VoiceOver says "button".
    static let button = PhoneControlTraits(rawValue: 1 << 0)
    /// Swiping up or down on it adjusts it: VoiceOver says "adjustable".
    static let adjustable = PhoneControlTraits(rawValue: 1 << 1)
    /// Activating it starts audio the app plays, which VoiceOver shouldn't
    /// talk over (UIKit's `startsMediaSession`).
    static let startsMediaSession = PhoneControlTraits(rawValue: 1 << 2)
    /// Text that doesn't change by itself (UIKit's `staticText`).
    static let staticText = PhoneControlTraits(rawValue: 1 << 3)
}

/// A custom action a reader control offers on VoiceOver's Actions rotor.
enum PhoneControlAction: Equatable, Hashable, Sendable {
    /// Where Am I?'s full summary, the Mac's `ShortcutAction.whereAmIFull`.
    case whereAmIFullSummary
    /// The Mac's Copy Reading Position.
    case copyReadingPosition

    /// The action's name, as VoiceOver reads it: the Mac's command names.
    @MainActor
    var name: String {
        switch self {
        case .whereAmIFullSummary: return ReaderWhereAmIToolbarButton.fullSummaryActionName
        case .copyReadingPosition: return ShortcutAction.copyReadingPosition.title
        }
    }
}

/// Everything VoiceOver reads of one reader control at one moment: its
/// label, value, hint, traits, and actions (the spec, under "The reader").
///
/// `PhoneReaderControls` makes one for a control and a plain state, so every
/// word and trait is tested on the Mac. `PhoneControl`, on iOS, asks for a
/// fresh one each time VoiceOver asks for any part of it, and holds nothing.
struct PhoneControlDescription: Equatable {
    /// What the control is: "Play", "Navigation unit".
    let label: String
    /// What it holds now, or "" for nothing: "Sentence", "3 bookmarks".
    let value: String
    /// What activating or adjusting it does, or "" for no hint.
    let hint: String
    /// How VoiceOver treats it.
    let traits: PhoneControlTraits
    /// Its actions on the Actions rotor, in order; none for most controls,
    /// so VoiceOver doesn't say "Actions available" after them.
    let actions: [PhoneControlAction]

    /// A description, with no value, hint, or actions unless given.
    init(
        label: String,
        value: String = "",
        hint: String = "",
        traits: PhoneControlTraits,
        actions: [PhoneControlAction] = []
    ) {
        self.label = label
        self.value = value
        self.hint = hint
        self.traits = traits
        self.actions = actions
    }
}
