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

    /// Removes what audio editing left in this Mac's caches when TextMouth
    /// last ended with editors open, as a crash leaves it
    /// (`AudioEditCaches.removeStale`): off the main thread, never a folder
    /// an open editor or a save uses, with one AUDIO_EDIT_CACHES_SWEPT line
    /// in the debug log when anything was removed. The library runs it at
    /// launch; tests hand it a completion, which gets what it did there.
    func removeStaleAudioEditCachesInBackground(completion: (@Sendable (AudioEditCaches.Result) -> Void)? = nil) {
        let activity = audioEditActivity
        DispatchQueue.global(qos: .utility).async {
            let result = AudioEditCaches.removeStale(isBookInUse: activity.isBeingEdited)
            if result.removed > 0 {
                DiagnosticLog.event(
                    .storage,
                    "AUDIO_EDIT_CACHES_SWEPT: removed \(result.removed) folder(s) a crash left in this Mac's audio editing caches"
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

// MARK: - Saving Edited Audio (FR04)

/// What saving a book's edited audio did.
struct AudioEditSaveOutcome: Equatable, Sendable {
    /// The book as the library lists it now.
    let book: Book
    /// The audio file saved, by its path inside the package: another name
    /// when its format's extension changed.
    let audioFile: String
    /// How long the saved file lasts, in seconds.
    let duration: TimeInterval
    /// Whether anything was rendered: false when the file already held
    /// every applied edit.
    let rendered: Bool
}

extension LibraryViewModel {
    /// Renders the edits of the audio file `audioFile` (by its path inside
    /// the package; the book's own file when nil) of the book `bookID` into
    /// that file, replacing it, and publishes the book as its files are now
    /// (`AudioEditBookRender`): its file, its fingerprint, its duration, and
    /// its content index, chapters included, measured afresh. A transcript
    /// made of the old audio no longer matches its fingerprints, so the
    /// transcription engine treats it as stale; the reading text kept of the
    /// book is dropped. The render runs off the main thread as storage work,
    /// holding a use of the book so the original policy keeps its original,
    /// and the original policy is applied afterwards ("don't keep" deletes
    /// the original at once).
    ///
    /// A file written under a new name, as an MP3 book's becomes an .m4a,
    /// replaces the old one only once the book's record names it: the old
    /// file is deleted after the record is written, so a crash between them
    /// leaves the book playable.
    ///
    /// The book's bookmarks and saved reading position follow the sound
    /// along `timeRoute`, the way from the file as it is to the edited audio
    /// being saved (`AudioEditSession.savedFileRoute`), through the book's
    /// chapters as they lay over the file before the save and after it
    /// (`AudioEditPlaces`); without a route they stay where they are.
    /// - Throws: `AudioEditError.bookNotInLibrary`, `.bookIsOpen` for a book
    ///   open in a reader, or the render's errors.
    func saveAudioEdits(
        ofBook bookID: UUID,
        audioFile: String? = nil,
        timeRoute: AudioEditorTimeMap.Route? = nil,
        now: Date = Date(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioEditSaveOutcome {
        guard let book = bookByID(bookID), book.format.isAudio, !book.tmbDirectoryName.isEmpty else {
            throw AudioEditError.bookNotInLibrary
        }
        guard !openBookIDs.contains(bookID) else { throw AudioEditError.bookIsOpen }
        let place = AudioBookPlace(book: book)
        let file = audioFile ?? place.bookFile
        let global = AudioOriginalPolicy.global(in: TextMouthRuntime.current.preferences)
        let metadata = AudioRenderMetadata(title: book.title, author: book.author)
        let engine = audioFilterEngine()
        let makeProcessor = audioEditProcessorFactory(engine: engine)
        let activity = audioEditActivity
        // The chapters as they lay over the file before the save are read
        // only when a route will move places along them.
        let hasPlaces = !book.bookmarks.isEmpty || book.readingPosition != nil
        let readsLayout = hasPlaces && timeRoute.map { !$0.isEmpty } == true

        // The use begins before the render reads the history, so the
        // original policy keeps the original it renders from.
        activity.beginUse(of: bookID)
        defer { activity.endUse(of: bookID) }
        let saved = try await OffMainWork.runThrowing {
            try StorageBoundary.shared.perform(.audioEditing) { _ in
                try Self.renderAndAnalyze(
                    book: book,
                    place: place,
                    request: AudioEditBookRender.Request(
                        package: place.package,
                        bookFile: place.bookFile,
                        audioFile: file,
                        globalPolicy: global,
                        metadata: metadata,
                        scratch: try AudioEditScratch.folder(for: bookID),
                        makeProcessor: makeProcessor,
                        ffmpeg: engine.ffmpeg,
                        mayReplace: { !activity.isOpenInReader(bookID) }
                    ),
                    readsLayout: readsLayout,
                    now: now,
                    progress: progress
                )
            }
        }

        guard let analysis = saved.analysis,
              let row = library.books.firstIndex(where: { $0.id == bookID }) else {
            return AudioEditSaveOutcome(
                book: bookByID(bookID) ?? book,
                audioFile: saved.render.audioFile,
                duration: saved.render.duration,
                rendered: saved.render.rendered
            )
        }
        library.books[row].filePath = saved.bookFilePath
        if let hash = saved.hash {
            library.books[row].md5Hash = hash
        }
        library.books[row].applyContentAnalysis(analysis, cacheFormatVersion: nil)
        movePlaces(
            ofBookAt: row,
            along: timeRoute,
            from: saved.previousLayout,
            to: analysis,
            track: Self.track(file, savedAs: saved.render.audioFile, in: place),
            now: now
        )
        let updated = library.books[row]
        save()
        LibraryPersistenceService.saveBookInfo(for: updated, contentIndex: analysis)
        ReadingTextCache.shared.remove(bookID: bookID)
        AudioEditScratch.remove(for: bookID)
        DiagnosticLog.event(
            .storage,
            "AUDIO_EDITS_SAVED: \(updated.title): \(String(format: "%.3f", saved.render.duration)) seconds"
                + (saved.render.replacedFile == nil ? "" : ", written under a new name")
        )
        if let replaced = saved.render.replacedFile {
            await retireReplacedAudio(replaced, of: updated, place: place, savedAs: saved.render.audioFile)
        }
        sweepAudioOriginalsInBackground()
        return AudioEditSaveOutcome(
            book: updated,
            audioFile: saved.render.audioFile,
            duration: saved.render.duration,
            rendered: true
        )
    }

    /// Makes what renders the filters and gain changes of a book's edits on
    /// `engine`, or, when nil, on the one in force now: the installed ffmpeg
    /// when the setting allows and one is found, or TextMouth's own filters
    /// (`audioFilterEngine`). It is chosen once, so one session or save runs
    /// every filter on the same engine.
    func audioEditProcessorFactory(engine: AudioFilterEngine? = nil) -> AudioEditProcessorFactory {
        let engine = engine ?? audioFilterEngine()
        return { sources in AudioFilterProcessor(sources: sources, engine: engine) }
    }

    /// What rendering a book's edits and analyzing the result gave.
    private struct RenderedBook: Sendable {
        /// What the render did.
        let render: AudioEditBookRender.Result
        /// The book's content index, measured afresh; nil when nothing was
        /// rendered.
        let analysis: BookContentIndex?
        /// The book's content index as it was before the render, which says
        /// how its chapters lay over the file then; nil unless asked for, or
        /// when it couldn't be read.
        let previousLayout: BookContentIndex?
        /// The book's file, or folder of tracks, as a full path now.
        let bookFilePath: String
        /// The MD5 of a book of one file, now; nil for a book of several.
        let hash: String?
    }

    /// Renders `request` and, when anything was rendered, analyzes `book`'s
    /// audio afresh from its files: storage work's body, on a background
    /// thread, which waits for the asynchronous render. With `readsLayout`,
    /// the book's content index as it is before the render is read first,
    /// as the reader reads it (`BookContentAnalysisService.load`).
    nonisolated private static func renderAndAnalyze(
        book: Book,
        place: AudioBookPlace,
        request: AudioEditBookRender.Request,
        readsLayout: Bool,
        now: Date,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> RenderedBook {
        let previousLayout = readsLayout ? try? BookContentAnalysisService.load(book: book).index : nil
        let render = try AsyncBridge.waitForResult {
            try await AudioEditBookRender.run(request, now: now, progress: progress)
        }
        let isOneFile = request.audioFile == place.bookFile
        let bookFile = isOneFile ? render.audioFile : place.bookFile
        let bookURL = request.package.appendingPathComponent(bookFile)
        guard render.rendered else {
            return RenderedBook(render: render, analysis: nil, previousLayout: previousLayout, bookFilePath: bookURL.path, hash: nil)
        }
        if !isOneFile, let replaced = render.replacedFile {
            // A track of a book of several, renamed: its folder's manifest
            // follows it, so the book keeps its order and its sections.
            try AudioEditBookRender.renameTrack(
                replaced,
                to: render.audioFile,
                inManifestOf: request.package.appendingPathComponent(place.bookFile),
                folderInPackage: place.bookFile
            )
        }
        var analyzed = book
        analyzed.filePath = bookURL.path
        let analysis = try BookContentAnalysisService.analyzeAudio(book: analyzed, url: bookURL)
        return RenderedBook(
            render: render,
            analysis: analysis.index,
            previousLayout: previousLayout,
            bookFilePath: bookURL.path,
            hash: isOneFile ? try FileImportService.md5Hash(of: bookURL) : nil
        )
    }

    // MARK: The Book's Places

    /// Moves the bookmarks and the saved reading position of the book at
    /// `row` along `route`, through `previous`, its content index before the
    /// save, and `current`, its index now (`AudioEditPlaces`); `track` names
    /// the track saved in a book of several. Without a route, or without the
    /// index from before, they stay where they are, with a line in the debug
    /// log when there were any to move.
    private func movePlaces(
        ofBookAt row: Int,
        along route: AudioEditorTimeMap.Route?,
        from previous: BookContentIndex?,
        to current: BookContentIndex,
        track: AudioEditPlaces.Track?,
        now: Date
    ) {
        let book = library.books[row]
        guard !book.bookmarks.isEmpty || book.readingPosition != nil, route?.isEmpty != true else { return }
        guard let route, let previous else {
            DiagnosticLog.event(
                .storage,
                "AUDIO_EDITS_SAVED: \(book.title): the bookmarks and the reading position stay where they were, "
                    + (route == nil ? "as how the edits moved the sound isn't known" : "as the book's chapters couldn't be read before the save")
            )
            return
        }
        let moved = AudioEditPlaces.follow(
            route,
            bookmarks: book.bookmarks,
            position: book.readingPosition,
            track: track,
            from: previous,
            to: current,
            at: now
        )
        library.books[row].bookmarks = moved.bookmarks
        library.books[row].readingPosition = moved.position
    }

    /// The track saved as `savedAs`, from `file` (both paths inside the
    /// package), as a book of several tracks names it inside its folder of
    /// tracks; nil for a book of one file, which `file` is when it is the
    /// book's own.
    nonisolated static func track(_ file: String, savedAs: String, in place: AudioBookPlace) -> AudioEditPlaces.Track? {
        let folder = place.bookFile + "/"
        guard file != place.bookFile, file.hasPrefix(folder), savedAs.hasPrefix(folder) else { return nil }
        return AudioEditPlaces.Track(before: String(file.dropFirst(folder.count)), after: String(savedAs.dropFirst(folder.count)))
    }

    /// Deletes `replaced`, the path inside `book`'s package of the audio file
    /// the render wrote anew as `savedAs`, once the book's record names the
    /// new file: the record queued for the book is written at once, read
    /// back, and checked first. A record that doesn't name it keeps the old
    /// file, with a line in the debug log; a later save removes it.
    private func retireReplacedAudio(_ replaced: String, of book: Book, place: AudioBookPlace, savedAs: String) async {
        let bookID = book.id
        // The record names a book of one file by that file's name, and a
        // book of several by its folder's.
        let expected = ((place.bookFile == replaced ? savedAs : place.bookFile) as NSString).lastPathComponent
        await OffMainWork.run {
            StorageBoundary.shared.perform(.audioEditing) { _ in
                LibraryPersistenceService.writePendingBookInfoNow(bookID: bookID)
                let package = place.package
                let recorded = (try? StoredBookRecord.read(from: package))?.info.metadata.originalFileName
                guard recorded == expected,
                      let old = AudioEditPackage.url(of: replaced, in: package) else {
                    DiagnosticLog.event(
                        .storage,
                        "AUDIO_EDITS_SAVED: \(book.title): the replaced audio file stays until the book's record names its new file"
                    )
                    return
                }
                try? FileManager.default.removeItem(at: old)
            }
        }
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
