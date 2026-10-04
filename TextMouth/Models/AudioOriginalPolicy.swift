import Foundation

/// What happens to the original audio of a recording or of an edited
/// audiobook (the user's decisions of October 4): keep it, delete it and
/// edit in place, or delete it some days after the last edit.
///
/// An original is the audio as it was recorded or imported (`AudioOriginal`):
/// a recording's take, 16-bit PCM, kept in its package as `original-take.caf`
/// (`BookOrigin.originalTakeFileName`) from the moment it is saved as an
/// audiobook, and for an imported audiobook a copy of its file, kept from
/// just before edits are first written into it
/// (`AudioEditPackage.originalFile(forAudioFile:)`). While it is kept every
/// edit can be undone, and made again without a loss of quality; a
/// recording's costs about 345 MB an hour. The policy says how long it
/// stays: for good, not at all (edits then change the book's audio in
/// place), or for a number of days after the book's audio was last edited.
/// A global setting holds the policy for every book; a book's edit history
/// can hold one of its own, which wins (`AudioEditHistory.policyOverride`,
/// or, for a recording never edited, `BookOrigin.OriginalTake.policyOverride`).
/// The sweep that applies it is `AudioOriginalSweep`.
///
/// The global setting keeps the names it had when only recordings kept an
/// original (`recordingOriginalPolicy`, `recordingOriginalDays`), so the
/// preferences and config.json files already written keep their meaning.
enum AudioOriginalPolicy: Equatable, Sendable {
    /// Keep the original for good.
    case keep
    /// Keep no original: the book's audio is all there is, and edits change
    /// it in place.
    case delete
    /// Keep the original for this many days after the book's audio
    /// was last edited, then delete it.
    case deleteAfter(days: Double)

    /// The choice, as Settings and config.json name it, apart from the
    /// number of days.
    enum Choice: String, CaseIterable, Sendable {
        case keep
        case delete
        case deleteAfterDays
    }

    /// The global policy until the user picks another: keep the original
    /// for one day after saving.
    static let standard = AudioOriginalPolicy.deleteAfter(days: SettingsPolicy.recordingOriginalDays.defaultValue)

    /// The policy `choice` names, keeping the original `days` days when the
    /// choice is to delete it after some days.
    init(choice: Choice, days: Double) {
        switch choice {
        case .keep: self = .keep
        case .delete: self = .delete
        case .deleteAfterDays: self = .deleteAfter(days: days)
        }
    }

    /// The choice this policy is, apart from its number of days.
    var choice: Choice {
        switch self {
        case .keep: return .keep
        case .delete: return .delete
        case .deleteAfter: return .deleteAfterDays
        }
    }

    /// When an original whose book's audio was last edited at
    /// `lastEdited` is to be deleted: never for `keep`, at once for
    /// `delete`, and `days` days later for `deleteAfter`.
    func deletionDate(lastEdited: Date) -> Date? {
        switch self {
        case .keep:
            return nil
        case .delete:
            return lastEdited
        case .deleteAfter(let days):
            return lastEdited.addingTimeInterval(days * 24 * 60 * 60)
        }
    }

    /// Whether, at `now`, an original last edited at `lastEdited` is
    /// due to be deleted.
    func isDue(lastEdited: Date, now: Date) -> Bool {
        guard let deletion = deletionDate(lastEdited: lastEdited) else { return false }
        return now >= deletion
    }
}

// MARK: - The Global Setting

extension SettingsPolicy {
    /// What happens to the original audio of recordings and edited
    /// audiobooks (Storage settings, Audio Editing picker): deleted some days
    /// after the last edit until the user picks another choice.
    static let recordingOriginalPolicy = EnumSettingRule(
        key: "recordingOriginalPolicy",
        defaultValue: AudioOriginalPolicy.Choice.deleteAfterDays
    )
    /// How many days an original is kept when it is deleted after some days
    /// (Storage settings, Audio Editing stepper): 1 to 365, and 1 until the
    /// user picks another number.
    static let recordingOriginalDays = NumericSettingRule(
        key: "recordingOriginalDays",
        range: 1...365,
        defaultValue: 1
    )
}

extension AudioOriginalPolicy {
    /// The global choice in the preferences store, saved as its raw value
    /// and read through `SettingsPolicy.recordingOriginalPolicy`, so a
    /// missing or unsupported value reads as the default.
    static let choicePreference = StoredPreference<Choice>(
        key: SettingsPolicy.recordingOriginalPolicy.key,
        read: { store, key in SettingsPolicy.recordingOriginalPolicy.value(fromRaw: store.object(forKey: key) as? String) },
        write: { choice, store, key in store.set(choice.rawValue, forKey: key) }
    )

    /// The global number of days in the preferences store, read and written
    /// through `SettingsPolicy.recordingOriginalDays`, so it is always
    /// within 1 to 365.
    static let daysPreference = StoredPreference<Double>(
        key: SettingsPolicy.recordingOriginalDays.key,
        read: { store, _ in SettingsPolicy.recordingOriginalDays.storedValue(in: store) },
        write: { days, store, key in store.set(SettingsPolicy.recordingOriginalDays.validated(days), forKey: key) }
    )

    /// The store keys of the global policy.
    static var preferenceKeys: [String] {
        [choicePreference.key, daysPreference.key]
    }

    /// The global policy `store` holds.
    static func global(in store: UserDefaults) -> AudioOriginalPolicy {
        AudioOriginalPolicy(choice: choicePreference.read(from: store), days: daysPreference.read(from: store))
    }

    /// Saves `policy` as the global policy in `store`. Choosing keep or
    /// delete leaves the number of days as it was, for when the user
    /// chooses to delete after some days again.
    static func saveGlobal(_ policy: AudioOriginalPolicy, in store: UserDefaults) {
        choicePreference.write(policy.choice, to: store)
        if case .deleteAfter(let days) = policy {
            daysPreference.write(days, to: store)
        }
    }
}

// MARK: - A Book's Own Policy

/// A book's own policy is kept in its edit history (edits.json), or, for a
/// recording never edited, in its origin record (origin.json), as its choice
/// and, for a deletion after some days, the number of days:
/// `{"choice": "deleteAfterDays", "days": 3}`. A number of days the global
/// rule would not accept is brought within it as the record is read.
extension AudioOriginalPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case choice
        case days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let choice = try container.decode(Choice.self, forKey: .choice)
        let days = try container.decodeIfPresent(Double.self, forKey: .days) ?? SettingsPolicy.recordingOriginalDays.defaultValue
        self.init(choice: choice, days: SettingsPolicy.recordingOriginalDays.validated(days))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(choice, forKey: .choice)
        if case .deleteAfter(let days) = self {
            try container.encode(days, forKey: .days)
        }
    }
}

extension AudioOriginalPolicy.Choice: Codable {}
