import Foundation

// MARK: - Reaching a Cloud Library's Files

/// How the background maintenance passes and the startup repair reach a
/// book's files, in a data directory that may be in a cloud folder (FR02).
///
/// There any of a book's files can be dataless: only its metadata is on
/// this Mac, and a read downloads it first, waiting on the network (Apple
/// TN3150, "Getting ready for dataless files"). Every "is this file
/// dataless" question these passes ask goes to `isDataless`, and their
/// reads go through `read(_:_:)`.
///
/// The app uses `live`. Only a sync service makes dataless files, so a
/// hosted test passes an access of its own instead: one that names the
/// items it pretends are dataless, and the reads it refuses with `EDEADLK`,
/// as the system refuses the read of a dataless file inside
/// `DatalessFiles.withoutDownloading`.
struct MaintenanceFileAccess: Sendable {
    /// Whether the item at a URL is dataless. Answering reads nothing.
    let isDataless: @Sendable (URL) -> Bool
    /// Whether a read of the item at a URL is refused before it starts,
    /// as the system refuses the read of a dataless file. The app refuses
    /// nothing here: its refusals come from the system itself.
    let refusesRead: @Sendable (URL) -> Bool

    /// An access answering with `isDataless`, and refusing the reads
    /// `refusesRead` names: by default none.
    init(
        isDataless: @escaping @Sendable (URL) -> Bool,
        refusesRead: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.isDataless = isDataless
        self.refusesRead = refusesRead
    }

    /// The access the app uses: `DatalessFiles.isDataless`, and only the
    /// system's own refusals.
    static let live = MaintenanceFileAccess(isDataless: { DatalessFiles.isDataless($0) })

    // MARK: Reading

    /// Runs `body`, which reads the item at `url` or what is inside it, and
    /// returns what it returns. A read this access refuses throws first,
    /// with the error the system gives a refused read of a dataless file
    /// (`DatalessFiles.isDownloadRefusal` recognizes it).
    func read<Value>(_ url: URL, _ body: () throws -> Value) throws -> Value {
        if refusesRead(url) {
            throw Self.refusal(of: url)
        }
        return try body()
    }

    /// The error a read of the dataless file at `url` meets when dataless
    /// files are left in the cloud: `EDEADLK`, naming the file.
    static func refusal(of url: URL) -> POSIXError {
        POSIXError(.EDEADLK, userInfo: [NSFilePathErrorKey: url.path])
    }

    /// The hasher maintenance fingerprints with: MD5, as
    /// `FingerprintHasher.md5` computes it, with every file read for its
    /// digest read through `read(_:_:)`, so a refused read reaches a digest
    /// as it reaches any other read.
    var hasher: FingerprintHasher {
        FingerprintHasher(
            digestOfFile: { url in
                try read(url) { try FingerprintHasher.md5.digestOfFile(url) }
            },
            digestOfData: FingerprintHasher.md5.digestOfData
        )
    }
}
