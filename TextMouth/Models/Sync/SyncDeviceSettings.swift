import Foundation

// MARK: - A Device's Own Choice of Books to Keep (FR45, FR46)

/// Which books a device keeps downloaded while it syncs the library. A choice
/// of each device, never of the library: the Mac with a large disk keeps every
/// book, the iPhone keeps the books it is asked to open or keep.
enum BooksOnThisDevice: String, CaseIterable, Sendable {
    /// Every book of the library: after each sync the device downloads each book
    /// it lacks, and it never removes one.
    case allBooks
    /// Only the books a person keeps, lists, or opens: the device downloads those,
    /// and removes the download of a book left unopened for the days below.
    case openedOrKept

    /// The choice a device starts with: all books on the Mac, only the books
    /// opened or kept on the iPhone.
    static func defaultChoice(isPhone: Bool) -> BooksOnThisDevice {
        isPhone ? .openedOrKept : .allBooks
    }
}

/// How the choice and the days are stored and read. Both are this device's
/// alone (`SyncPreferences.keys` lists their keys among the machine-local ones,
/// which config.json never carries, so no future settings sync takes them to
/// another device).
struct SyncDeviceSettings: Equatable, Sendable {
    /// The most days a book may stay unopened before its download is removed.
    static let longestWait = 30
    /// The days the iPhone starts with.
    static let phoneDefaultDays = 7

    /// Which books this device keeps downloaded.
    var books: BooksOnThisDevice
    /// Remove the download of a book unopened for this many days (1 to 30), or
    /// nil for Off. Only read under `.openedOrKept`.
    var removeAfterDays: Int?
    /// When the removal of unopened books began to apply on this device: a book's
    /// days count from its last opening or this date, whichever is later, so
    /// turning the removal on never removes a book at once.
    var removalsBeganAt: Date?

    /// The days that removal waits, when it applies at all: this choice is
    /// "Books you open or keep" and the days are not Off.
    var activeDays: Int? {
        books == .openedOrKept ? removeAfterDays : nil
    }

    /// The settings a device starts with.
    static func defaults(isPhone: Bool) -> SyncDeviceSettings {
        SyncDeviceSettings(
            books: .defaultChoice(isPhone: isPhone),
            removeAfterDays: isPhone ? phoneDefaultDays : nil,
            removalsBeganAt: nil
        )
    }

    /// `days` held within 1 to 30; a nil or lower number is Off.
    static func clampedDays(_ days: Int?) -> Int? {
        guard let days, days >= 1 else { return nil }
        return min(days, longestWait)
    }

    // MARK: Reading and writing

    /// The settings `store` holds, the platform's defaults for any it does not.
    static func read(from store: UserDefaults, isPhone: Bool) -> SyncDeviceSettings {
        var settings = defaults(isPhone: isPhone)
        if let raw = SyncPreferences.booksOnThisDevice.read(from: store), let books = BooksOnThisDevice(rawValue: raw) {
            settings.books = books
        }
        // The days are stored as a number, 0 meaning Off, so Off is told from nothing stored.
        if let stored = SyncPreferences.removeAfterDays.read(from: store) {
            settings.removeAfterDays = clampedDays(stored)
        }
        settings.removalsBeganAt = SyncPreferences.removalsBeganAt.read(from: store)
        return settings
    }

    /// Saves every field to `store`.
    func write(to store: UserDefaults) {
        SyncPreferences.booksOnThisDevice.write(books.rawValue, to: store)
        SyncPreferences.removeAfterDays.write(removeAfterDays ?? 0, to: store)
        SyncPreferences.removalsBeganAt.write(removalsBeganAt, to: store)
    }

    /// These settings after a change: the new values, with the date the removal
    /// began set to `now` when the change turns it on (it was not applying, and now
    /// is), and kept while it stays on or off. Changing from "All books" to the
    /// other choice therefore removes nothing at once: the days count from `now`.
    func changing(books newBooks: BooksOnThisDevice? = nil, removeAfterDays newDays: Int?? = nil, at now: Date) -> SyncDeviceSettings {
        var changed = self
        if let newBooks { changed.books = newBooks }
        if let newDays { changed.removeAfterDays = Self.clampedDays(newDays) }
        if activeDays == nil, changed.activeDays != nil { changed.removalsBeganAt = now }
        return changed
    }

    /// These settings with the date the removal began filled in, `now`, when the
    /// removal applies and has no date yet (the iPhone's first sync with the
    /// default 7 days): the days then count from this first look.
    func beginningRemovals(at now: Date) -> SyncDeviceSettings {
        guard activeDays != nil, removalsBeganAt == nil else { return self }
        var begun = self
        begun.removalsBeganAt = now
        return begun
    }
}

// MARK: - When a Book's Download Is Due to Go

/// The rule of FR45, as a pure function of dates: a book's download is removed
/// once it has gone unopened for the settings' days, counted from the latest of
/// its last opening on any device, its last play here, the files' arrival here,
/// and the date the removal began.
///
/// The days are whole days of 24 hours between two instants, never calendar days,
/// so a change of time zone or a clock change of an hour moves nothing.
enum SyncSpacePolicy {
    /// The seconds in a day.
    static let secondsInDay: TimeInterval = 86_400

    /// The latest date a book was in use: of those that are known, and the date removals began.
    static func lastInUse(opened: Date?, played: Date?, arrived: Date?, removalsBeganAt: Date) -> Date {
        [opened, played, arrived, removalsBeganAt].compactMap { $0 }.max() ?? removalsBeganAt
    }

    /// Whether a book last in use at `lastInUse` has gone unopened for `days` days by `now`.
    static func isDue(lastInUse: Date, days: Int, now: Date) -> Bool {
        now.timeIntervalSince(lastInUse) >= Double(days) * secondsInDay
    }
}
