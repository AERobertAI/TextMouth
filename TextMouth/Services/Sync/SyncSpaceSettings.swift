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
    /// - Parameter announcing: False for a step VoiceOver took by adjusting the control, after which VoiceOver reads
    ///   the control's new value itself, so each step is said once, as the app's other steppers say theirs.
    func setRemoveAfterDays(_ days: Int?, announcing: Bool = true) {
        let clamped = SyncDeviceSettings.clampedDays(days)
        guard clamped != settings.removeAfterDays else { return }
        save(settings.changing(removeAfterDays: .some(clamped), at: now()))
        if announcing { announce(SyncWording.announceRemoveAfter(clamped)) }
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

// MARK: - Books a Person Freed (FR46)

/// The books a person freed with Remove Download on this device. Under "All books" the next sync would download
/// them again and undo what was asked, so each stays freed until it is opened again: its row says In Cloud, and
/// opening it downloads it. This device's own, kept in its preferences (`SyncPreferences.freedOnPurpose`, among the
/// machine-local keys), and forgotten once the book is opened after it was freed.
@MainActor
final class BooksFreedOnPurpose {
    /// The device's own.
    static let shared = BooksFreedOnPurpose()

    /// Where the books are kept.
    private let store: UserDefaults
    /// When each book was freed.
    private var freed: [UUID: Date]

    /// The books `store` holds; the app's own preferences by default.
    init(store: UserDefaults? = nil) {
        let store = store ?? TextMouthRuntime.current.preferences
        self.store = store
        freed = Dictionary(
            SyncPreferences.freedOnPurpose.read(from: store).compactMap { key, seconds in
                UUID(uuidString: key).map { ($0, Date(timeIntervalSince1970: seconds)) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Notes that the book `id` was freed at `date`.
    func note(_ id: UUID, at date: Date) {
        freed[id] = date
        save()
    }

    /// Whether `book` was freed by a person and not opened since: it is left in the cloud. A book opened after it
    /// was freed is forgotten, and downloads as any other.
    func isHeld(_ book: Book) -> Bool {
        guard let at = freed[book.id] else { return false }
        if let opened = book.lastOpened, opened > at {
            freed[book.id] = nil
            save()
            return false
        }
        return true
    }

    /// Keeps the books in the preferences.
    private func save() {
        SyncPreferences.freedOnPurpose.write(
            Dictionary(uniqueKeysWithValues: freed.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }), to: store
        )
    }
}

// MARK: - Books Being Freed Now (FR46)

/// The books whose downloads are going from this device now: from the library's last look, which said yes
/// (`FreeingCheck`), to the book's row saying In Cloud (`LibraryCloudCommands`). The library keeps one
/// (`LibraryViewModel.booksBeingFreed`), and nothing reads or writes such a book's files meanwhile: the audio editor's
/// opening and its render, Edit Text, an export, and a transcription each wait for the removal to end
/// (`waitUntilFreed(_:)`); a reader's load waits for the package move the library brackets the removal with
/// (`LibraryBookUpdates.packagesWillMove(_:)`); and a sync's removal of the book waits for a later sync
/// (`LibraryViewModel.isBookBusyForSync(_:)`).
///
/// Before the last look nothing waits. Whatever begins while the copy is checked is in use when the look is asked, and
/// the look refuses, leaving the book whole: a person who opens, plays, edits, or exports the book goes on at once, and
/// the removal is what gives way. Only the moment from the look to the row's change is waited for, in which a pointer
/// is written and a few files are removed.
@MainActor
final class BooksBeingFreed {
    /// The books being freed now.
    private(set) var bookIDs: Set<UUID> = []
    /// The callers waiting for a removal to end, all woken whenever one does, each then looking again.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the book `id` is being freed now.
    func contains(_ id: UUID) -> Bool {
        bookIDs.contains(id)
    }

    /// Notes that the files of the book `id` begin to go.
    func begin(_ id: UUID) {
        bookIDs.insert(id)
    }

    /// Notes that the removal of the book `id` is over, whatever came of it, and wakes the callers waiting. A book not
    /// being freed changes nothing.
    func end(_ id: UUID) {
        guard bookIDs.remove(id) != nil else { return }
        let woken = waiters
        waiters.removeAll()
        for waiter in woken {
            waiter.resume()
        }
    }

    /// Returns once none of `ids` is being freed: at once when none is. The wait is as long as the removals', each of
    /// which writes a pointer and removes a book's own files.
    func waitUntilFreed(_ ids: some Sequence<UUID>) async {
        let ids = Set(ids)
        while !bookIDs.isDisjoint(with: ids) {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
