import Foundation

/// What the iPhone's importing holds between the moments it acts (the
/// spec's "From other apps", the engineering review's F14): files another
/// app sent before the library had started, the time of the last hand-off to
/// the shared import, and the decisions that follow from them, which are when
/// the scratch copies may be swept and whether an opened file's book opens.
///
/// A value type with time passed in, so the Mac's tests decide every case.
struct PhoneImportHolding: Equatable {
    /// What happens to the books of files another app sent.
    enum Route: Equatable {
        /// Imported, and the book opens once it is in the library, with
        /// focus on Play, as the Mac's opened file does.
        case importAndOpen
        /// Imported and not opened: the listener's book goes on, and focus
        /// stays where it is.
        case importOnly
    }

    /// When the scratch copies may be swept.
    enum SweepDecision: Equatable {
        /// Now: nothing imports, copies, waits, or asks.
        case now
        /// Once this many more seconds have passed quietly: a hand-off was
        /// just made, and the shared import's queue may not have counted it
        /// yet.
        case after(TimeInterval)
        /// Not while something is under way; asked again when it ends.
        case notNow
    }

    /// How long nothing must have been handed to the shared import before the
    /// scratch copies are swept. The import queue counts an import on the
    /// main queue's next turn after it is queued (`SerialImportQueue`), so
    /// for a moment after a hand-off the library says nothing imports while
    /// a copy still waits to be read. A few seconds is far longer than that.
    static let quietPeriod: TimeInterval = 5

    /// How long a file must have been in `Documents/Inbox` before a sweep
    /// removes it, so that a file the system has just put there, for a call
    /// that hasn't reached the app yet, is never taken from under it.
    static let inboxGrace: TimeInterval = 60

    /// The files another app sent while the library couldn't take them yet,
    /// oldest first.
    private(set) var heldFiles: [URL] = []
    /// When the last copies were handed to the shared import; nil before any.
    private(set) var lastHandOff: Date?

    // MARK: Holding

    /// Holds `urls`, sent by another app, until the library has started.
    mutating func hold(_ urls: [URL]) {
        heldFiles.append(contentsOf: urls)
    }

    /// The files held, in the order they came, which are no longer held.
    mutating func takeHeldFiles() -> [URL] {
        let taken = heldFiles
        heldFiles = []
        return taken
    }

    // MARK: Routing

    /// What happens to the books of files another app sends while a book
    /// `isBookPlaying` or not: a playing book is never stopped by one.
    static func route(isBookPlaying: Bool) -> Route {
        isBookPlaying ? .importOnly : .importAndOpen
    }

    // MARK: Sweeping

    /// Notes that copies were handed to the shared import at `date`.
    mutating func noteHandOff(at date: Date) {
        lastHandOff = date
    }

    /// Whether the scratch copies and the Inbox may be swept at `date`: only
    /// when the library imports nothing, no question waits, nothing is being
    /// copied, nothing is held, and the last hand-off is `quietPeriod` old.
    func sweepDecision(isImporting: Bool, hasQuestion: Bool, isCopying: Bool, at date: Date) -> SweepDecision {
        guard !isImporting, !hasQuestion, !isCopying, heldFiles.isEmpty else { return .notNow }
        guard let lastHandOff else { return .now }
        let quiet = date.timeIntervalSince(lastHandOff)
        return quiet >= Self.quietPeriod ? .now : .after(Self.quietPeriod - quiet)
    }

    /// Whether a sweep at `date` removes an Inbox file put there at `added`:
    /// once it has been there for `inboxGrace`. A file whose time isn't
    /// known is removed, as the sweep's moment already means nothing waits
    /// for it.
    static func sweepsInboxFile(addedAt added: Date?, at date: Date) -> Bool {
        guard let added else { return true }
        return date.timeIntervalSince(added) >= inboxGrace
    }
}

/// The names of the imports under way, kept in a small file so that an
/// import TextMouth's closing stopped can be named at the next launch: "
/// Importing “Dune” was stopped when TextMouth closed. Add it again." (the
/// spec's "Progress"). It is written as a copy starts and as its copies are
/// handed over, and removed once nothing imports.
struct PhoneImportRecord: Codable, Equatable {
    /// One item being imported.
    struct Entry: Codable, Equatable {
        /// Its display name, as the sentence says it.
        let name: String
        /// The path of its scratch copy, once made: a book whose
        /// `sourceFilePath` is this path was imported before the close.
        var copyPath: String?
    }

    /// The record's file name, in its folder.
    static let fileName = "importing.json"

    /// The items, in the order they started.
    var entries: [Entry] = []

    /// The record's file in `folder`.
    static func file(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The record at `url`, or nil when there is none or it can't be read.
    static func load(from url: URL) -> PhoneImportRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneImportRecord.self, from: data)
    }

    /// Writes the record to `url` in one replacement, making its folder.
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The names of the items TextMouth's closing stopped: every entry whose
    /// copy isn't the source of a book the library holds, `importedPaths`
    /// being those books' `sourceFilePath`s. An archive or a folder is
    /// always named: adding it again passes over the books already in.
    func stoppedNames(importedPaths: Set<String>) -> [String] {
        entries.filter { entry in
            guard let copyPath = entry.copyPath else { return true }
            return !importedPaths.contains(copyPath)
        }
        .map(\.name)
    }
}
