import Foundation

// SyncSpaceWording.swift: the words of saving space on a device that syncs
// (FR45 and FR46): Remove Download for a synced library, the setting "Books on
// this device", and the days a book may stay unopened. They sit beside
// `SyncWording`'s and follow its rules (R9): every state is words, pinned by
// tests, in every language.

extension SyncWording {
    // MARK: - Why a download stays

    /// What a person hears when the proof fell short (`SyncRemovalRefusal`): the book stays whole.
    /// - Parameters:
    ///   - refusal: Why the proof fell short.
    ///   - isPhone: Whether this device is an iPhone, for "this iPhone" and "this Mac".
    static func removalRefusal(_ refusal: SyncRemovalRefusal, isPhone: Bool) -> String {
        switch refusal {
        case .notBackedUp, .missingFromFolder, .notUploaded, .uploadFailed, .folderUnreachable:
            // Translators: Why Remove Download left a book's files on this device: its copy in iCloud Drive is not confirmed yet.
            return InterfaceText.line("sync.remove.notInDrive", "TextMouth hasn't confirmed that iCloud Drive holds every file of this book, so its download stays. Try again in a moment.")
        case .changedHere:
            // Translators: Why Remove Download left a book's files on this device: the book was changed here since it was copied to iCloud Drive.
            return InterfaceText.line("sync.remove.changedHere", "This book has changes that iCloud Drive doesn't hold yet, so its download stays.")
        case .doesNotMatch:
            // Translators: Why Remove Download left a book's files on this device: what iCloud Drive sent back is not the book.
            return InterfaceText.line("sync.remove.doesNotMatch", "The copy in iCloud Drive doesn't match this book, so its download stays.")
        case .offline:
            // Translators: Why Remove Download left a book's files on this device: it is offline. %@ is "this Mac" or "this iPhone".
            return InterfaceText.line("sync.remove.offline", "TextMouth can't check the copy in iCloud Drive while \(thisDevice(isPhone: isPhone)) is offline, so the download stays.")
        case .needsDownload, .needsRoom:
            // Translators: Why a book's files stay on this device for now: to free the book TextMouth first checks its copy in iCloud Drive, which means downloading it again, so it needs room for one more copy of the book and, on cellular data, Wi-Fi.
            return InterfaceText.line("sync.remove.needsDownload", "To free this book, TextMouth first checks its copy in iCloud Drive. That needs room for one more copy of the book, and Wi-Fi on cellular data. Its download stays for now.")
        case .busy:
            return removeBookInUse
        case .nothingToRemove:
            return nothingToRemove
        case .couldNotRemove:
            // Translators: Why Remove Download failed: a file could not be taken off the device.
            return InterfaceText.line("sync.remove.couldNotRemove", "TextMouth couldn't remove all of this book's files.")
        }
    }

    /// Remove Download refused: the book is kept on all devices.
    static var removeKeptOnAllDevices: String {
        // Translators: First sentence of why Remove Download was refused: the book is kept on all devices that sync. A sentence follows that names the command to choose.
        InterfaceText.line("sync.remove.keptOnAllDevices", "The book is kept on all devices, so its download can't be removed.")
    }

    /// Remove Download refused: the book is in use.
    static var removeBookInUse: String {
        // Translators: Why Remove Download was refused: the book is being played, exported, transcribed, or edited.
        InterfaceText.line("sync.remove.inUse", "The book is in use, so its download can't be removed.")
    }

    /// Said when Library > Remove Download finds nothing to remove among the selected books.
    static var nothingToRemove: String {
        // Translators: Said aloud when the Library menu's Remove Download finds that none of the selected books has a download on this device to remove.
        InterfaceText.line("sync.remove.nothing", "None of the selected books has a download to remove.")
    }

    /// The hint of Remove Download in Book Information.
    static var removeDownloadHint: String {
        // Translators: VoiceOver hint of the Remove Download button in Book Information: it frees this book's space on this device.
        InterfaceText.line("sync.remove.hint", "Frees this book's space on this device. The book stays in iCloud Drive.")
    }

    // MARK: - Said after a sync

    /// Said once after a sync removed the downloads of books left unopened.
    static func announceRemovedUnopened(books: Int, days: Int) -> String {
        // Translators: Said aloud once after a sync removed downloads of books not opened for some days. %1$@ is a count of books, such as "3 books"; %2$@ is a count of days, such as "7 days". Every book stays in iCloud Drive.
        InterfaceText.line("sync.announce.removedUnopened", "Removed downloads of \(CountWording.books(books)) not opened in \(daysPhrase(days)). All stay in iCloud Drive.")
    }

    /// A count of days, such as "7 days".
    static func daysPhrase(_ days: Int) -> String {
        // Translators: A number of days, as the setting that removes unopened books' downloads says it. %lld is the number of days.
        InterfaceText.line("common.countDays", "\(number: days) days")
    }

    /// Books left on this device for now, in the status's details.
    static func removalsWaiting(books: Int, device: String) -> String {
        // Translators: A line of the sync status: books stay on this device because their copies in iCloud Drive are not confirmed yet. %1$@ is "this Mac" or "this iPhone"; %2$@ is a count of books, such as "3 books".
        InterfaceText.line("sync.status.removalsWaiting", "Staying on \(device) for now, until iCloud Drive's copies are confirmed: \(CountWording.books(books)).")
    }

    /// Downloads stopped for want of room, in the status's details.
    static func shortOfRoom(books: Int, device: String) -> String {
        // Translators: A line of the sync status: this device has no room for books it would download. %1$@ is a count of books, such as "3 books"; %2$@ is "this Mac" or "this iPhone".
        InterfaceText.line("sync.status.shortOfRoom", "There isn't room on \(device) to download \(CountWording.books(books)). The books already here stay.")
    }

    // MARK: - The settings

    /// The label of the setting that says which books this device keeps.
    static var booksOnDeviceLabel: String {
        // Translators: Label of the Sync setting that chooses which books this device keeps downloaded. The two choices follow it.
        InterfaceText.line("sync.booksOnDevice.label", "Books on this device")
    }

    /// The choice that keeps every book.
    static var booksOnDeviceAll: String {
        // Translators: Choice of the Books on this device setting: this device downloads every book.
        InterfaceText.line("sync.booksOnDevice.all", "All books")
    }

    /// The choice that keeps the books a person opens or keeps.
    static var booksOnDeviceOpenedOrKept: String {
        // Translators: Choice of the Books on this device setting: this device downloads only the books the person opens or keeps.
        InterfaceText.line("sync.booksOnDevice.openedOrKept", "Books you open or keep")
    }

    /// The hint of the Books on this device setting.
    static var booksOnDeviceHint: String {
        // Translators: VoiceOver hint of the Books on this device setting.
        InterfaceText.line("sync.booksOnDevice.hint", "Chooses whether this device downloads every book, or only the books you open or keep.")
    }

    /// Said after the choice became All books.
    static var announceAllBooks: String {
        // Translators: Said aloud after the person chose All books for this device. Books this device lacks download after the next sync.
        InterfaceText.line("sync.booksOnDevice.announce.all", "All books. Books missing here download after the next sync.")
    }

    /// Said after the choice became Books you open or keep.
    static var announceOpenedOrKept: String {
        // Translators: Said aloud after the person chose Books you open or keep for this device. No download is removed at once.
        InterfaceText.line("sync.booksOnDevice.announce.openedOrKept", "Books you open or keep. Nothing is removed now.")
    }

    /// The label of the days a book may stay unopened.
    static var removeAfterLabel: String {
        // Translators: Label of the setting that removes a book's download from this device after the book has been unopened for some days. Off, or 1 to 30 days, follows it.
        InterfaceText.line("sync.removeAfter.label", "Remove unopened downloads after")
    }

    /// The hint of that setting.
    static var removeAfterHint: String {
        // Translators: VoiceOver hint of the setting that removes the downloads of books left unopened for some days.
        InterfaceText.line("sync.removeAfter.hint", "Removes a book's download from this device once you haven't opened it for this long. The book stays in iCloud Drive.")
    }

    /// The days as the setting shows and speaks them: "Off" or "7 days".
    static func removeAfterValue(_ days: Int?) -> String {
        guard let days else {
            // Translators: A setting that is turned off.
            return InterfaceText.line("common.off", "Off")
        }
        return daysPhrase(days)
    }

    /// Said after the days changed.
    static func announceRemoveAfter(_ days: Int?) -> String {
        guard let days else {
            // Translators: Said aloud after the person turned off removing the downloads of unopened books.
            return InterfaceText.line("sync.removeAfter.announce.off", "Not removing the downloads of unopened books.")
        }
        // Translators: Said aloud after the person set the days after which the downloads of unopened books are removed. %@ is a count of days, such as "7 days".
        return InterfaceText.line("sync.removeAfter.announce.days", "Removing downloads of books unopened for \(daysPhrase(days)).")
    }

    // MARK: - After a removal, and while it is checked

    /// Said after Remove Download under "All books", which downloads every book: a book a person freed stays freed until
    /// it is opened again.
    static var removedDownloadsAgainOnOpening: String {
        // Translators: Said after Remove Download when this device keeps every book: the book is not downloaded again until the person opens it.
        InterfaceText.line("sync.remove.reopensToDownload", "Opening a book downloads it again.")
    }

    /// Said when checking a book's copy takes a while.
    static var checkingTheCopy: String {
        // Translators: Said aloud when Remove Download is still checking the copy of the book in iCloud Drive after a few seconds.
        InterfaceText.line("sync.remove.checking", "Checking the copy in iCloud Drive.")
    }

    // MARK: - Stop Syncing

    /// The question before syncing stops, with the books whose files are only in iCloud Drive counted: they will not open
    /// without the TextMouth Sync folder.
    static func stopQuestion(isPhone: Bool, onlyInCloud: Int) -> String {
        let question = stopQuestion(isPhone: isPhone)
        guard onlyInCloud > 0 else { return question }
        // Translators: Added to the question before syncing stops, when some books' files are only in iCloud Drive. %@ is a count of books, such as "12 books".
        let note = InterfaceText.line("sync.stopQuestion.onlyInCloud", "\(CountWording.books(onlyInCloud)): only in iCloud Drive. Keep the TextMouth Sync folder to open them.")
        return SentenceWording.joined([question, note])
    }
}
