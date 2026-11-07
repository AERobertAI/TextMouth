import Foundation

/// The phone's own settings, which the Mac doesn't have, as the spec's outside
/// reviews added them on November 7: what each kind of book moves by until it
/// has a unit of its own, and Follow in Braille.
///
/// They're kept in the app's preferences (`TextMouthRuntime.current.preferences`)
/// under the keys the phone's frame reads them by, `phoneTextNavigationUnit`,
/// `phoneAudioNavigationUnit`, and `phoneFollowInBraille`, a unit as its raw
/// value and the switch as a Boolean. Slice 1's `PhoneDefaults` is to hold the
/// same keys with accessors of its own; once it has landed, these should read
/// through it, so that one place says how each is kept.
enum PhoneSettingsDefaults {
    /// What a text book moves by until it has a unit of its own: Sentence,
    /// unless another is chosen.
    static let textNavigationUnit = navigationUnit(
        key: "phoneTextNavigationUnit",
        offered: PhoneSettingsModel.textNavigationUnits,
        defaultUnit: .sentence
    )

    /// What an audiobook moves by until it has a unit of its own: 15 seconds,
    /// unless another is chosen.
    static let audioNavigationUnit = navigationUnit(
        key: "phoneAudioNavigationUnit",
        offered: PhoneSettingsModel.audioNavigationUnits,
        defaultUnit: .seconds15
    )

    /// Whether Book content moves on with the speech while the book plays:
    /// off, unless turned on.
    static let followInBraille = StoredPreference<Bool>(
        key: "phoneFollowInBraille",
        read: { store, key in store.bool(forKey: key) },
        write: { isOn, store, key in store.set(isOn, forKey: key) }
    )

    /// A unit kept under `key` as its raw value. One that is missing, names no
    /// unit, or isn't `offered` reads as `defaultUnit`, as an audiobook's
    /// "Sentence" would, so a stored value from anywhere can only ever give a
    /// unit the row offers.
    private static func navigationUnit(
        key: String,
        offered: [SkipUnit],
        defaultUnit: SkipUnit
    ) -> StoredPreference<SkipUnit> {
        StoredPreference(
            key: key,
            read: { store, key in
                guard let unit = store.string(forKey: key).flatMap(SkipUnit.init(rawValue:)),
                      offered.contains(unit) else {
                    return defaultUnit
                }
                return unit
            },
            write: { unit, store, key in store.set(unit.rawValue, forKey: key) }
        )
    }
}
