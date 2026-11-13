import Foundation
import ZIPFoundation

// MARK: - Limits

/// How much one ZIP import may extract to disk (TODO I05). An archive is
/// inspected before anything is written, and refused when it exceeds any of
/// these; archives a batch finds inside it count toward the same totals.
///
/// - `audioArchiveExpansion`, 8 GB, for an import whose archives hold audio
///   or other archives (which may hold audio). The longest commercial
///   audiobooks run 50 to 60 hours: 2.9 to 3.5 GB as 128 kbps MP3, under
///   7 GB even at 256 kbps; a 12-hour book as CD-quality WAVE is about
///   7.6 GB. Every real single audiobook fits, with room to spare.
/// - `otherArchiveExpansion`, 2 GB, for archives of books without audio.
///   An EPUB is typically 1 to 5 MB, so a batch of 400 books is about
///   1.2 GB, and even books heavy with images fit by the dozen. A text
///   archive past 2 GB is a whole library export, better imported in parts.
/// - `maximumEntries`, 10,000 files, folders, and links. The largest DAISY
///   2.02 audio books hold a few thousand files (a SMIL file and an audio
///   file per section, and the text), and a 1,000-book library export holds
///   about 3,000 (a book, a cover, and metadata each); an archive of
///   hundreds of thousands of tiny entries, a common archive bomb, is
///   refused before it creates any.
/// - `maximumNestingDepth`, 1: a batch unpacks archives found inside the
///   archive, but not archives inside those, since an archive can hold
///   itself. This was already the batch's behavior; it is now explicit.
/// - `freeSpaceReserve`, 1 GB: what an import leaves free on the disk it
///   extracts to, for the system's swap and logs and for the library's own
///   writes (each book's text cache and record, and the library index).
///   On this project's development Mac, a 245 GB volume with about 13 GB
///   free, that still lets an 8 GB audiobook in while stopping an import
///   that would fill the disk.
struct ArchiveLimits: Sendable {
    /// The most an import of archives holding audio or other archives may
    /// extract, in bytes.
    var audioArchiveExpansion: Int64
    /// The most an import of archives of books without audio may extract,
    /// in bytes.
    var otherArchiveExpansion: Int64
    /// The most entries an import may extract.
    var maximumEntries: Int
    /// How many levels of archives inside the archive a batch unpacks.
    var maximumNestingDepth: Int
    /// The bytes an import leaves free on the disk it extracts to.
    var freeSpaceReserve: Int64
    /// The free bytes on the volume holding a location, or nil when the
    /// system cannot tell; tests supply their own figure.
    var freeSpace: @Sendable (URL) -> Int64?
    /// Whether copying the file at the first location to the second costs
    /// almost no space, because the volume clones the file (APFS shares its
    /// blocks until one side is changed). Imports that copy files whole
    /// (`FileImportService.requireRoom(forCopying:onVolumeOf:)`) count such
    /// a file as empty. A copy that is not known to be a clone counts in
    /// full, so tests that need a full copy supply `false`.
    var copyIsClone: @Sendable (URL, URL) -> Bool = { _, _ in false }

    /// The documented limits every import uses.
    static let standard = ArchiveLimits(
        audioArchiveExpansion: 8_000_000_000,
        otherArchiveExpansion: 2_000_000_000,
        maximumEntries: 10_000,
        maximumNestingDepth: 1,
        freeSpaceReserve: 1_000_000_000,
        freeSpace: { ArchiveLimits.volumeFreeSpace(at: $0) },
        copyIsClone: { ArchiveLimits.volumeClonesCopy(from: $0, to: $1) }
    )

    /// The limits imports use: `standard`, unless a test binds smaller ones
    /// with `ArchiveLimits.$current.withValue(_:operation:)`, which changes
    /// only the imports that operation runs on its own thread.
    @TaskLocal static var current = ArchiveLimits.standard

    /// The free space on the volume holding `location`, or on the volume of
    /// its nearest existing folder when it does not exist yet: the capacity
    /// the system reports for important use, which counts the purgeable
    /// space it frees on demand, as Apple recommends for work the user asked
    /// for; or the plain available capacity where that is not reported.
    /// Nil when the system reports neither.
    static func volumeFreeSpace(at location: URL) -> Int64? {
        var existing = location.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return nil }
            existing = parent
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? existing.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Whether `FileManager.copyItem` of the file at `source` into the
    /// folder at `destination` clones it: both are on one volume, and that
    /// volume supports cloning (APFS does; HFS+ and exFAT copy every byte).
    /// False when either volume cannot be told, or when the file is still in
    /// the cloud (a copy downloads it in full), so a doubtful copy counts
    /// in full.
    static func volumeClonesCopy(from source: URL, to destination: URL) -> Bool {
        guard !DatalessFiles.isDataless(source),
              ImportScratchSpace.areOnSameVolume(source, destination) else { return false }
        let values = try? destination.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        return values?.volumeSupportsFileCloning == true
    }
}

// MARK: - Inspection

/// What an archive declares about itself in its central directory, read
/// without extracting anything.
struct ArchiveInspection: Equatable, Sendable {
    /// How many entries (files, folders, and links) it holds.
    var entryCount: Int
    /// The total size its entries declare once extracted, in bytes.
    var declaredSize: Int64
    /// Whether it holds an audio file, or another archive, which may.
    var holdsAudioOrArchives: Bool

    /// An inspection with exactly these figures.
    init(entryCount: Int, declaredSize: Int64, holdsAudioOrArchives: Bool) {
        self.entryCount = entryCount
        self.declaredSize = declaredSize
        self.holdsAudioOrArchives = holdsAudioOrArchives
    }

    /// Inspects `archive`. Sizes past what 64 bits can count are counted as
    /// the most they can, which no limit allows.
    init(of archive: Archive) {
        var entryCount = 0
        var declaredSize: Int64 = 0
        var holdsAudioOrArchives = false
        for entry in archive {
            entryCount += 1
            declaredSize = Self.saturatingSum(declaredSize, Int64(clamping: entry.uncompressedSize))
            if !holdsAudioOrArchives, entry.type == .file {
                holdsAudioOrArchives = ArchiveEntryLimits.isAudio(entry.path)
                    || (entry.path as NSString).pathExtension.lowercased() == "zip"
            }
        }
        self.init(entryCount: entryCount, declaredSize: declaredSize, holdsAudioOrArchives: holdsAudioOrArchives)
    }

    /// `first` plus `second`, or the largest size when the sum overflows.
    static func saturatingSum(_ first: Int64, _ second: Int64) -> Int64 {
        let (sum, overflowed) = first.addingReportingOverflow(second)
        return overflowed ? .max : sum
    }
}

// MARK: - Refusals

/// Why an import's archives were refused or stopped (TODO I05). Each
/// description states the figures and the limit, in words VoiceOver reads
/// as numbers with their units; an import failure puts it after "Extracting
/// the archive failed: ".
enum ArchiveBudgetError: LocalizedError, Equatable {
    /// The archives' declared total, `declared` bytes, exceeds `limit`, the
    /// limit for archives that do or do not hold audio or other archives.
    /// `withNestedArchives` when the total counts archives found inside.
    case expandsPastLimit(declared: Int64, limit: Int64, holdsAudioOrArchives: Bool, withNestedArchives: Bool)
    /// The archives hold `count` entries, more than `limit`.
    case tooManyEntries(count: Int, limit: Int, withNestedArchives: Bool)
    /// The archive (or `nestedArchive`, found inside it) declares `needed`
    /// bytes, but the disk it extracts to has only `available` free, and
    /// `reserve` must stay free.
    case notEnoughSpace(nestedArchive: String?, needed: Int64, available: Int64, reserve: Int64)
    /// Extraction wrote more than `declared`, the total the archives
    /// declare, so it stopped: only a damaged or crafted archive does that.
    case extractedPastDeclaredSize(declared: Int64)

    var errorDescription: String? {
        let size = ArchiveFigures.size
        switch self {
        case let .expandsPastLimit(declared, limit, holdsAudioOrArchives, withNestedArchives):
            let kind = holdsAudioOrArchives ? "archives holding audio or other archives" : "archives without audio"
            return "\(Self.subject(withNestedArchives)) expands to \(size(declared)), "
                + "more than the \(size(limit)) TextMouth extracts from \(kind)."
        case let .tooManyEntries(count, limit, withNestedArchives):
            return "\(Self.subject(withNestedArchives)) holds \(ArchiveFigures.count(count)) files and folders, "
                + "more than the \(ArchiveFigures.count(limit)) TextMouth extracts in one import."
        case let .notEnoughSpace(nestedArchive, needed, available, reserve):
            let subject = nestedArchive.map { "The archive “\($0)” inside it" } ?? "The archive"
            return "\(subject) expands to \(size(needed)), but the disk holding the TextMouth library has only "
                + "\(size(available)) free, and TextMouth keeps \(size(reserve)) of it free. "
                + "Free up space, then import it again."
        case let .extractedPastDeclaredSize(declared):
            return "The archive holds more than the \(size(declared)) it declares, so extraction stopped. "
                + "Get a fresh copy of the archive, then import it again."
        }
    }

    /// What a sentence about the import's totals is about: the archive
    /// alone, or the archive with the archives found inside it.
    private static func subject(_ withNestedArchives: Bool) -> String {
        withNestedArchives ? "Together with the archives inside it, the archive" : "The archive"
    }
}

// MARK: - Budget

/// The running account of one import's archives against `ArchiveLimits`
/// (TODO I05). Each archive is admitted before anything of it is written;
/// what extraction writes is then charged against what the admitted
/// archives declared, so an archive whose sizes lie is stopped too. A batch
/// shares one budget among its archive and the archives found inside it.
///
/// Not thread-safe: an import uses its budget on its own thread.
final class ArchiveBudget {
    /// The limits this import is held to.
    let limits: ArchiveLimits
    /// The bytes the admitted archives declare: the most extraction may write.
    private(set) var declaredTotal: Int64 = 0
    /// The entries the admitted archives hold.
    private(set) var entryTotal = 0
    /// The bytes extraction has written so far.
    private(set) var extractedTotal: Int64 = 0
    /// Whether any admitted archive holds audio or other archives, which
    /// raises the expansion limit to the audio one.
    private(set) var holdsAudioOrArchives = false
    /// How many archives have been admitted.
    private(set) var admittedArchives = 0
    /// The first refusal raised while entries were read, kept for a caller
    /// whose reader sets read errors aside and carries on, as the DAISY audio
    /// converter does for each audio file it cannot copy.
    private(set) var violation: Error?

    /// A budget holding an import to `limits`: by default the current ones.
    init(limits: ArchiveLimits = .current) {
        self.limits = limits
    }

    /// Admits the archive `inspection` describes, to be extracted into
    /// `destination`, after checking, in this order, that the import's
    /// entries stay within the entry limit, that its declared total stays
    /// within the expansion limit (the audio one once any admitted archive
    /// holds audio or other archives), and that the disk holding
    /// `destination` keeps the reserve free once this archive is out.
    /// `nestedArchive` names an archive found inside the one imported.
    /// - Throws: `ArchiveBudgetError` naming the figures and the limit; the
    ///   budget is then unchanged.
    func admit(_ inspection: ArchiveInspection, extractingInto destination: URL, nestedArchive: String? = nil) throws {
        let withNestedArchives = admittedArchives > 0
        let entries = entryTotal.addingReportingOverflow(inspection.entryCount)
        let entryCount = entries.overflow ? Int.max : entries.partialValue
        guard entryCount <= limits.maximumEntries else {
            throw ArchiveBudgetError.tooManyEntries(
                count: entryCount, limit: limits.maximumEntries, withNestedArchives: withNestedArchives
            )
        }

        let holdsAudio = holdsAudioOrArchives || inspection.holdsAudioOrArchives
        let limit = holdsAudio ? limits.audioArchiveExpansion : limits.otherArchiveExpansion
        let declared = ArchiveInspection.saturatingSum(declaredTotal, inspection.declaredSize)
        guard declared <= limit else {
            throw ArchiveBudgetError.expandsPastLimit(
                declared: declared, limit: limit, holdsAudioOrArchives: holdsAudio, withNestedArchives: withNestedArchives
            )
        }

        // The disk is asked now, so space the import's earlier archives took
        // is already gone from the answer; only this archive is still to come.
        if let available = limits.freeSpace(destination),
           available - limits.freeSpaceReserve < inspection.declaredSize {
            throw ArchiveBudgetError.notEnoughSpace(
                nestedArchive: nestedArchive,
                needed: inspection.declaredSize,
                available: available,
                reserve: limits.freeSpaceReserve
            )
        }

        entryTotal = entryCount
        declaredTotal = declared
        holdsAudioOrArchives = holdsAudio
        admittedArchives += 1
    }

    /// Charges `bytes` just written to the import.
    /// - Throws: `ArchiveBudgetError.extractedPastDeclaredSize`, recorded as
    ///   the budget's violation, once the import has written more than its
    ///   admitted archives declare.
    func charge(_ bytes: Int64) throws {
        extractedTotal = ArchiveInspection.saturatingSum(extractedTotal, bytes)
        guard extractedTotal <= declaredTotal else {
            throw record(ArchiveBudgetError.extractedPastDeclaredSize(declared: declaredTotal))
        }
    }

    /// Keeps `error` as the budget's violation unless one is already kept,
    /// and returns it, for the caller to throw.
    @discardableResult
    func record(_ error: Error) -> Error {
        if violation == nil {
            violation = error
        }
        return error
    }
}
