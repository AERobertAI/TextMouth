import Foundation

// MARK: - The Original Policy (FR04)

extension LibraryViewModel {
    /// Applies the original policy to every audiobook in the library
    /// (`AudioOriginalSweep`), at `now`, on a background queue as storage
    /// work, and hands what it did to `completion` there. Does nothing while
    /// the data directory can't be used. The library runs it at launch,
    /// after each recording is saved, after each edit is rendered, and after
    /// a book's own policy changes; tests call it with a clock of their own.
    /// Books open in a reader, or whose audio is being edited or rendered,
    /// keep their originals (`audioEditActivity`).
    func sweepAudioOriginalsInBackground(
        now: Date = Date(),
        completion: (@Sendable (AudioOriginalSweep.Result) -> Void)? = nil
    ) {
        guard dataDirectoryUnavailability == nil else { return }
        // Where each audiobook's package is, by folder and package name: its
        // full path is taken inside the storage work, under the data
        // directory current then, which a move may have changed meanwhile.
        let places = library.books
            .filter { $0.format.isAudio && !$0.tmbDirectoryName.isEmpty }
            .map(AudioBookPlace.init(book:))
        let global = AudioOriginalPolicy.global(in: TextMouthRuntime.current.preferences)
        let activity = audioEditActivity
        DispatchQueue.global(qos: .utility).async {
            let result = StorageBoundary.shared.perform(.audioEditing) { _ in
                AudioOriginalSweep.sweep(
                    packages: places.map(\.sweepPackage),
                    global: global,
                    now: now,
                    isInUse: activity.isInUse
                )
            }
            completion?(result)
        }
    }

    /// Gives the book `bookID` an original policy of its own, or, for nil,
    /// has it follow the global setting again, then applies the policy, so
    /// "don't keep" deletes the book's original at once when nothing needs
    /// it. A recording never edited keeps the policy beside its take in its
    /// origin record; any other book keeps it in its edit history.
    /// - Throws: `AudioEditError.bookNotInLibrary`, or the history's own
    ///   error (only in the cloud, from a newer version, or damaged).
    func setAudioOriginalPolicy(_ policy: AudioOriginalPolicy?, forBook bookID: UUID) async throws {
        guard let book = bookByID(bookID), book.format.isAudio, !book.tmbDirectoryName.isEmpty else {
            throw AudioEditError.bookNotInLibrary
        }
        let place = AudioBookPlace(book: book)
        try await OffMainWork.runThrowing {
            try StorageBoundary.shared.perform(.audioEditing) { _ in
                try AudioEditHistoryStore.update(package: place.package, bookFile: place.bookFile) { history in
                    history.policyOverride = policy
                }
            }
        }
        sweepAudioOriginalsInBackground()
    }
}

/// Where an audiobook's package is in the library: its folder and its
/// package's name, the two parts that do not change with the data
/// directory's location, and the book's file inside the package.
struct AudioBookPlace: Sendable {
    /// The book's identity.
    let bookID: UUID
    /// The library folder holding its package.
    let folderPath: String
    /// Its package's name.
    let tmbDirectoryName: String
    /// The book's file, by its path inside the package: its one file, or
    /// "audio", the folder of a book of several tracks.
    let bookFile: String

    /// Where `book`'s package is.
    init(book: Book) {
        bookID = book.id
        folderPath = book.folderPath
        tmbDirectoryName = book.tmbDirectoryName
        bookFile = book.fileInPackage
    }

    /// The package, under the data directory in use now. Call it inside the
    /// storage work, so a data-directory move cannot change it meanwhile.
    var package: URL {
        TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbDirectoryName)
    }

    /// The package as the original policy's sweep looks at it.
    var sweepPackage: AudioOriginalSweep.Package {
        AudioOriginalSweep.Package(bookID: bookID, url: package, bookFile: bookFile)
    }
}

extension Book {
    /// The book's file, or its folder of tracks, by its path inside its
    /// package: "Ferry.m4b", or "audio". Worked out from the paths as they
    /// are spelled, reading nothing, so it is safe on the main thread; a
    /// file path outside the package, as only a book from the earliest
    /// releases has, gives the file's own name.
    var fileInPackage: String {
        let packagePath = tmbDirectory.path
        guard filePath.hasPrefix(packagePath + "/") else {
            return bookFileURL.lastPathComponent
        }
        return String(filePath.dropFirst(packagePath.count + 1))
    }
}
