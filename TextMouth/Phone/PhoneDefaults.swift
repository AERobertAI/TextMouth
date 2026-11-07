import Foundation

/// What the iPhone fixes and never shows, and the phone's two navigation units.
///
/// The Mac's defaults are wrong for the phone: with the unit control mode at
/// None, the reader ignores a book's own unit, so choosing one would seem to do
/// nothing; and moving to the Trash, the default, has no Trash a person can open
/// on a phone. So `apply(to:config:)` sets them at every launch, before any
/// reader exists. It runs every launch rather than once, so that a config.json
/// brought from a Mac cannot bring the Mac's values back.
@MainActor
enum PhoneDefaults {
    /// The preference that holds the unit a text book moves by when it has
    /// none of its own.
    nonisolated static let textNavigationUnitKey = "phoneTextNavigationUnit"
    /// The preference that holds the unit an audiobook moves by when it has
    /// none of its own.
    nonisolated static let audioNavigationUnitKey = "phoneAudioNavigationUnit"
    /// A text book's unit until the listener chooses one: a sentence, so the
    /// first move never lands mid-sentence.
    nonisolated static let textNavigationUnitDefault = SkipUnit.sentence
    /// An audiobook's unit until the listener chooses one: 15 seconds, since an
    /// audiobook's text gives sentences nothing to stop at.
    nonisolated static let audioNavigationUnitDefault = SkipUnit.seconds15

    /// Sets, at every launch: one navigation unit for both directions, since the
    /// reader has one Navigation unit control; deleting a book's files rather
    /// than moving them to a Trash; and keeping the original of an imported
    /// file, since the phone imports a copy. config.json is written only when
    /// something changed.
    static func apply(to settings: SettingsViewModel, config: ConfigService) {
        if settings.playbackNavigationUnitControlMode != .shared {
            settings.playbackNavigationUnitControlMode = .shared
        }
        var changed = config.config
        changed.moveToTrashInsteadOfDeleting = false
        changed.importDeleteBehavior = .keepOriginal
        guard changed != config.config else { return }
        config.config = changed
        config.saveToDisk()
    }

    // MARK: - The Navigation Units

    /// The unit a text book with none of its own moves by.
    static func textNavigationUnit(in preferences: UserDefaults) -> SkipUnit {
        storedUnit(textNavigationUnitKey, in: preferences) ?? textNavigationUnitDefault
    }

    /// The unit an audiobook with none of its own moves by.
    static func audioNavigationUnit(in preferences: UserDefaults) -> SkipUnit {
        storedUnit(audioNavigationUnitKey, in: preferences) ?? audioNavigationUnitDefault
    }

    /// Keeps `unit` as what text books with none of their own move by.
    static func setTextNavigationUnit(_ unit: SkipUnit, in preferences: UserDefaults) {
        preferences.set(unit.rawValue, forKey: textNavigationUnitKey)
    }

    /// Keeps `unit` as what audiobooks with none of their own move by.
    static func setAudioNavigationUnit(_ unit: SkipUnit, in preferences: UserDefaults) {
        preferences.set(unit.rawValue, forKey: audioNavigationUnitKey)
    }

    /// The unit a book moves by: its own, else the one for its kind; and a unit
    /// the book does not offer falls to its kind's, then to the kind's built-in
    /// default, so an audiobook never starts on Sentence.
    ///
    /// - Parameters:
    ///   - ownRawValue: The book's own unit as its row keeps it, or nil.
    ///   - isAudio: Whether the book is an audiobook.
    ///   - offered: The units the book offers, as its reader lists them.
    static func navigationUnit(
        ownRawValue: String?,
        isAudio: Bool,
        offered: [SkipUnit],
        in preferences: UserDefaults
    ) -> SkipUnit {
        let builtIn = isAudio ? audioNavigationUnitDefault : textNavigationUnitDefault
        let kind = isAudio ? audioNavigationUnit(in: preferences) : textNavigationUnit(in: preferences)
        let own = ownRawValue.flatMap(SkipUnit.init(rawValue:))
        for candidate in [own, kind, builtIn].compactMap({ $0 }) where offered.contains(candidate) {
            return candidate
        }
        return builtIn
    }

    /// The unit kept under `key`, or nil when none is, or what is kept names no
    /// unit.
    private static func storedUnit(_ key: String, in preferences: UserDefaults) -> SkipUnit? {
        preferences.string(forKey: key).flatMap(SkipUnit.init(rawValue:))
    }
}
