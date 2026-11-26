import Foundation

// MARK: - This Device's Choice of Books (FR45)

/// The two settings of a device that syncs, as the Sync section shows and changes
/// them: which books this device keeps downloaded (`BooksOnThisDevice`) and the
/// days a book may stay unopened before its download is removed. They live in this
/// device's own preferences (`SyncPreferences`, listed among the machine-local keys
/// that config.json never carries), so no settings sync a later version may bring
/// can take one device's choice to another.
///
/// Each change is said aloud, in words that state the new value and what follows from
/// it, so VoiceOver hears the state after every change; focus is not touched here.
@MainActor
final class SyncSpaceSettings: ObservableObject {
    /// The device's settings, as the app uses them.
    static let shared = SyncSpaceSettings()

    /// What the device's settings are now.
    @Published private(set) var settings: SyncDeviceSettings

    /// Where the settings are kept.
    private let store: UserDefaults
    /// The time now, which a removal that has just been turned on counts its days from.
    private let now: @MainActor () -> Date
    /// Says words aloud.
    private let announce: @MainActor (String) -> Void
    /// Whether this device is an iPhone, which decides the defaults.
    private let isPhone: Bool

    /// Settings read from `store`; the app's own by default, a sandbox's in a test.
    init(
        store: UserDefaults? = nil,
        isPhone: Bool = ThisDevice.isPhone,
        now: @escaping @MainActor () -> Date = { Date() },
        announce: @escaping @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        let store = store ?? TextMouthRuntime.current.preferences
        self.store = store
        self.isPhone = isPhone
        self.now = now
        self.announce = announce
        settings = SyncDeviceSettings.read(from: store, isPhone: isPhone)
    }

    // MARK: Changing

    /// Chooses which books this device keeps, and says what follows. Choosing what is chosen already
    /// changes and says nothing.
    func setBooks(_ books: BooksOnThisDevice) {
        guard books != settings.books else { return }
        save(settings.changing(books: books, at: now()))
        announce(books == .allBooks ? SyncWording.announceAllBooks : SyncWording.announceOpenedOrKept)
    }

    /// Sets the days a book may stay unopened (1 to 30), or Off for nil, and says the new value.
    func setRemoveAfterDays(_ days: Int?) {
        let clamped = SyncDeviceSettings.clampedDays(days)
        guard clamped != settings.removeAfterDays else { return }
        save(settings.changing(removeAfterDays: .some(clamped), at: now()))
        announce(SyncWording.announceRemoveAfter(clamped))
    }

    /// Notes the first time removal applies on this device without a person having chosen it (the iPhone's
    /// default), so its days count from now and nothing is removed at once. Says nothing, since nothing changed
    /// that a person did.
    func beginRemovalsIfNeeded() {
        let begun = settings.beginningRemovals(at: now())
        if begun != settings { save(begun) }
    }

    /// Keeps `new` as the settings, in memory and in the preferences.
    private func save(_ new: SyncDeviceSettings) {
        settings = new
        new.write(to: store)
    }
}
