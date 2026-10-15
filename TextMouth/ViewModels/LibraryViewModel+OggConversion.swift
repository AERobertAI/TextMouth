import Foundation

// MARK: - Why a Book Waits

/// Why a book's Ogg audio was not converted to AAC at this launch (B06): it
/// stays as it was and waits for a later launch, with one
/// `OGG_CONVERSION_WAITS` line in the debug log.
enum OggConversionWait: Equatable, Sendable {
    /// Its folder or its files are only in the cloud: nothing is downloaded.
    case inCloud
    /// The disk can't hold its converted copy plus the import's reserve:
    /// `needed` bytes must be free, and `free` are.
    case space(needed: Int64, free: Int64)
    /// A track could not be converted, or the result not committed, for
    /// `reason`, which names files, never paths.
    case failed(String)
    /// The book moved, or left the library, while it was converted.
    case bookChanged

    /// The reason the debug log gives.
    var logReason: String {
        switch self {
        case .inCloud:
            return "its files are only in the cloud"
        case let .space(needed, free):
            return "it needs \(needed) bytes free to convert, and \(free) are"
        case let .failed(reason):
            return "its conversion failed: \(reason)"
        case .bookChanged:
            return "the book moved or left the library while it was converted"
        }
    }
}

/// What converting one book's Ogg audio came to.
enum OggBookConversionResult: Equatable, Sendable {
    /// The book has no Ogg audio: nothing was done.
    case noOggAudio
    /// The book's `tracks` Ogg files were converted, and the book plays
    /// from the .m4a files now.
    case converted(tracks: Int)
    /// The book was left as it was, for a later launch.
    case waiting(OggConversionWait)
}

/// The words of the alert that says a book's audio waits for disk space.
enum OggConversionWording {
    /// The alert's title.
    static let notEnoughSpaceTitle = "Not Enough Space to Convert Audio"

    /// The alert's message for `books`, each a title and the bytes it needs
    /// free: "“Harbor Dramas” needs 4.2 GB free to convert its Ogg audio to
    /// AAC. Free some space, and TextMouth converts it at the next launch."
    static func notEnoughSpace(_ books: [(title: String, needed: Int64)]) -> String {
        let needs = books.map { "“\($0.title)” needs \(ImportProgressWording.size($0.needed)) free" }
        let subject = books.count == 1 ? "its Ogg audio" : "their Ogg audio"
        let object = books.count == 1 ? "it" : "them"
        return "\(needs.joined(separator: ", and ")) to convert \(subject) to AAC. "
            + "Free some space, and TextMouth converts \(object) at the next launch."
    }
}

// MARK: - Once for the Library

extension LibraryViewModel {
    /// The preference that records the one-time conversion of the library's
    /// Ogg audio (`convertOggAudioOnce`) as made on this Mac for the library
    /// this Mac expects (`DataDirectoryPreferences.expectedIdentity`), so
    /// each library has it once, as the hand-edit pass of FR18 is recorded:
    /// its version, `oggAudioConvertedVersion`, once made.
    nonisolated static func oggAudioConvertedKey(in preferences: UserDefaults) -> String {
        let base = "library.oggAudioConvertedVersion"
        guard let identity = DataDirectoryPreferences.expectedIdentity.read(from: preferences) else { return base }
        return base + "." + identity.uuidString
    }

    /// The version of the one-time conversion this TextMouth makes.
    nonisolated static let oggAudioConvertedVersion = 1

    /// What the one-time conversion did, counts alone.
    struct OggConversionOutcome: Equatable, Sendable {
        /// The books converted.
        var converted = 0
        /// The books left for a later launch.
        var waiting = 0
    }

    /// Converts the Ogg audio of every book of the library's own to AAC,
    /// once for each library on this Mac (B06): a folder of tracks, a
    /// single Ogg file, or a DAISY package's audio. The books convert one at
    /// a time, off the main thread, each committed on its own
    /// (`convertOggAudio(ofBook:access:)`), while the Library window's
    /// overlay shows how far the book under way has got. A book that waits,
    /// for the cloud or for disk space, leaves the pass to be made again at
    /// the next launch; it is recorded as made only once nothing waits. The
    /// books that wait for space are named in one alert.
    /// - Parameters:
    ///   - preferences: Where the pass is recorded as made.
    ///   - access: How the pass reaches the books' files (FR02).
    ///   - completion: Called on the main actor with what the pass did, or
    ///     with nil, at once, when it was made already.
    func convertOggAudioOnce(
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable (OggConversionOutcome?) -> Void)? = nil
    ) {
        let key = Self.oggAudioConvertedKey(in: preferences)
        guard preferences.integer(forKey: key) < Self.oggAudioConvertedVersion else {
            completion?(nil)
            return
        }
        let bookIDs = library.books.filter { $0.format.isAudio && !$0.tmbDirectoryName.isEmpty }.map(\.id)
        oggConversion.enqueue { [weak self] in
            guard let self else { return }
            var outcome = OggConversionOutcome()
            var waitingForSpace: [(title: String, needed: Int64)] = []
            for bookID in bookIDs {
                switch await self.convertOggAudio(ofBook: bookID, access: access) {
                case .noOggAudio:
                    break
                case .converted:
                    outcome.converted += 1
                case let .waiting(wait):
                    outcome.waiting += 1
                    if case let .space(needed, _) = wait, let title = self.bookByID(bookID)?.title {
                        waitingForSpace.append((title, needed))
                    }
                }
            }
            if !waitingForSpace.isEmpty {
                self.showAlert(title: OggConversionWording.notEnoughSpaceTitle, OggConversionWording.notEnoughSpace(waitingForSpace))
            }
            if outcome.waiting == 0 {
                preferences.set(Self.oggAudioConvertedVersion, forKey: key)
            }
            completion?(outcome)
        }
    }

    /// Converts the Ogg audio of the book `bookID` as soon as the
    /// conversions before it end, as its reader asks when it finds the book
    /// still in Ogg (B06): from now until then, the book counts as
    /// converting, so its reader refuses to play it. A book already
    /// converting or in line is left in its place.
    func requestOggConversion(ofBook bookID: UUID, access: MaintenanceFileAccess = .live) {
        guard !oggConversion.isConverting(bookID), !oggConversion.hasFailed(bookID) else { return }
        oggConversion.enqueue(bookID: bookID) { [weak self] in
            guard let self else { return }
            if case let .waiting(.space(needed, _)) = await self.convertOggAudio(ofBook: bookID, access: access),
               let title = self.bookByID(bookID)?.title {
                self.showAlert(title: OggConversionWording.notEnoughSpaceTitle, OggConversionWording.notEnoughSpace([(title, needed)]))
            }
        }
    }

    /// Shows the library alert titled `title`, saying `message`.
    private func showAlert(title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
        showError = true
    }

    // MARK: One Book

    /// Converts the Ogg audio of the book `bookID` to AAC and commits it,
    /// as one step for the book (B06). Call it only from a conversion in
    /// line (`OggConversionProgress.enqueue`), so one book converts at a
    /// time.
    ///
    /// Every Ogg file of the book is converted beside it, under a hidden
    /// name the reader never lists, and checked. Then, in one block on the
    /// manifest sessions' queue, so no look at a manifest comes between
    /// (FR18): each file takes its final name, the tracks are renamed in
    /// the book's manifest, and its record's content index names the .m4a
    /// files, the order and lengths of its tracks unchanged, so its
    /// positions, bookmarks, and skips stay exactly as they are. The library
    /// row and any open reader follow (`commitManifestEdit`). Only then are
    /// the Ogg files deleted. A single file's book takes the .m4a as its
    /// file, as a save in the audio editor does. A conversion stopped before
    /// the commit leaves the book as it was, and the files it left are
    /// removed when the book is converted again.
    ///
    /// Before converting, the disk must hold the book's converted copy plus
    /// the import's one-gigabyte reserve; a book that doesn't fit, and one
    /// whose files are only in the cloud, waits. Nothing is downloaded.
    /// One `OGG_CONVERTED` line in the debug log counts a book converted:
    /// its tracks, the minutes taken, and its bytes before and after.
    func convertOggAudio(
        ofBook bookID: UUID,
        access: MaintenanceFileAccess = .live
    ) async -> OggBookConversionResult {
        guard let book = bookByID(bookID), book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return .noOggAudio }
        let started = Date()
        let search = await OffMainWork.run { Self.oggFiles(of: book, access: access) }
        guard let search else { return wait(.inCloud, for: book) }
        let found = search.files
        guard !found.isEmpty else { return .noOggAudio }

        let bookURL = URL(fileURLWithPath: book.filePath)
        let isFolder = search.isFolder
        let container = isFolder ? bookURL : bookURL.deletingLastPathComponent()
        let needed = await OggAudioConverter.estimatedSize(of: found) + ArchiveLimits.standard.freeSpaceReserve
        if let free = ArchiveLimits.volumeFreeSpace(at: container), free < needed {
            return wait(.space(needed: needed, free: free), for: book)
        }

        oggConversion.begin(bookID: bookID, title: book.title, tracks: found.count)
        defer { oggConversion.end(bookID: bookID) }
        let progress = oggConversion
        let conversions: [OggAudioConverter.Conversion]
        do {
            await OffMainWork.run { OggAudioConverter.removeLeftovers(in: container) }
            conversions = try await OggAudioConverter.convertEach(found, naming: false) { done in
                Task { @MainActor in progress.reach(done) }
            }
        } catch {
            // A book that fails waits for the next launch: nothing tries it
            // again before (B09).
            oggConversion.markFailed(bookID)
            return wait(.failed(Self.loggable(error)), for: book)
        }

        let committed = isFolder
            ? await commitConvertedTracks(conversions, of: book, folder: bookURL)
            : await commitConvertedFile(conversions, of: book)
        if case let .waiting(wait) = committed {
            if case .failed = wait { oggConversion.markFailed(bookID) }
            return self.wait(wait, for: book)
        }
        let before = conversions.reduce(0) { $0 + $1.bytesBefore }
        let after = conversions.reduce(0) { $0 + $1.bytesAfter }
        DiagnosticLog.event(
            .storage,
            "OGG_CONVERTED: \(book.title): \(conversions.count) track(s) in "
                + String(format: "%.1f", Date().timeIntervalSince(started) / 60)
                + " minute(s), \(before) bytes before, \(after) bytes after"
        )
        return .converted(tracks: conversions.count)
    }

    /// Commits the converted tracks of `book`, a book of tracks in
    /// `folder`, as `convertOggAudio(ofBook:access:)` describes: named,
    /// renamed in the manifest, and in the record, on the manifest sessions'
    /// queue; then the row and the open readers; then the Ogg files deleted.
    private func commitConvertedTracks(
        _ conversions: [OggAudioConverter.Conversion],
        of book: Book,
        folder: URL
    ) async -> OggBookConversionResult {
        let sessions = BookManifestEditSessions.shared
        let result = await OffMainWork.run(on: sessions.queue) {
            Result { try Self.commitTracks(conversions, of: book, folder: folder) }
        }
        let edit: BookManifestEdit
        switch result {
        case let .success(committed?):
            edit = committed
        case .success(nil):
            return .waiting(.bookChanged)
        case let .failure(error):
            return .waiting(.failed(Self.loggable(error)))
        }
        commitManifestEdit(edit)
        await OffMainWork.run {
            for conversion in conversions {
                try? FileManager.default.removeItem(at: conversion.source)
            }
        }
        return .converted(tracks: conversions.count)
    }

    /// The commit's block on the manifest sessions' queue: `conversions`,
    /// under their hidden names beside `book`'s tracks in `folder`, take
    /// their final names, the manifest and the record's content index
    /// rename them, and the edit an open reader takes is returned. Should
    /// any step fail, the manifest's names are put back and the converted
    /// files removed, so the book is as it was.
    /// - Returns: The edit; nil when the record could not take it now (it
    ///   is only in the cloud, or the book moved meanwhile).
    nonisolated private static func commitTracks(
        _ conversions: [OggAudioConverter.Conversion],
        of book: Book,
        folder: URL
    ) throws -> BookManifestEdit? {
        // The index as the book plays it now, read before any file is
        // named, so it names the Ogg files.
        let current = try BookContentAnalysisService.load(book: book).index
        var named: [OggAudioConverter.Conversion] = []
        do {
            for conversion in conversions {
                named.append(try OggAudioConverter.givingFinalName(conversion))
            }
        } catch {
            OggAudioConverter.discard(named + conversions.dropFirst(named.count))
            throw error
        }
        let renames = Dictionary(
            named.map { (AudioBookParser.relativeName(of: $0.source, in: folder), AudioBookParser.relativeName(of: $0.converted, in: folder)) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            try OggAudioConverter.renameTracks(of: named, inManifestOf: folder, bookID: book.id)
            let index = current.renamingAudioFiles(renames)
            guard let committed = try LibraryPersistenceService.saveContentAnalysis(for: book, index: index, cacheFormatVersion: nil) else {
                try? OggAudioConverter.renameTracks(of: named.map(\.reversed), inManifestOf: folder, bookID: book.id)
                OggAudioConverter.discard(named)
                return nil
            }
            return BookManifestEdit(
                committed: committed,
                index: index,
                pauses: ChapterPauses.betweenTracks(of: index, inAudioFolder: folder),
                title: nil,
                author: nil
            )
        } catch {
            try? OggAudioConverter.renameTracks(of: named.map(\.reversed), inManifestOf: folder, bookID: book.id)
            OggAudioConverter.discard(named)
            throw error
        }
    }

    /// Commits the converted file of `book`, a book of one Ogg file: the
    /// file takes its final name and is read as the reader will, then the
    /// row and the record name it, as a save in the audio editor does, and
    /// the Ogg file is deleted. An open reader follows the row's new path.
    private func commitConvertedFile(_ conversions: [OggAudioConverter.Conversion], of book: Book) async -> OggBookConversionResult {
        guard let conversion = conversions.first else { return .noOggAudio }
        let analyzed: (named: OggAudioConverter.Conversion, index: BookContentIndex)
        do {
            analyzed = try await OffMainWork.runThrowing {
                let named = try OggAudioConverter.givingFinalName(conversion)
                do {
                    var renamed = book
                    renamed.filePath = named.converted.path
                    return (named, try BookContentAnalysisService.analyzeAudio(book: renamed, url: named.converted).index)
                } catch {
                    OggAudioConverter.discard([named])
                    throw error
                }
            }
        } catch {
            OggAudioConverter.discard([conversion])
            return .waiting(.failed(Self.loggable(error)))
        }
        // The book may have moved or left the library while it converted.
        guard let row = library.books.firstIndex(where: { $0.id == book.id }),
              library.books[row].filePath == book.filePath else {
            OggAudioConverter.discard([analyzed.named])
            return .waiting(.bookChanged)
        }
        library.books[row].filePath = analyzed.named.converted.path
        library.books[row].applyContentAnalysis(analyzed.index, cacheFormatVersion: nil)
        let updated = library.books[row]
        save()
        LibraryPersistenceService.saveBookInfo(for: updated, contentIndex: analyzed.index)
        await OffMainWork.run { try? FileManager.default.removeItem(at: conversion.source) }
        return .converted(tracks: 1)
    }

    /// Logs that `book` waits, for `wait`, and says so.
    private func wait(_ wait: OggConversionWait, for book: Book) -> OggBookConversionResult {
        DiagnosticLog.event(.storage, "OGG_CONVERSION_WAITS: \(book.title): \(wait.logReason)")
        return .waiting(wait)
    }

    /// The Ogg files a book plays, and whether it is a folder of tracks.
    struct OggFilesFound: Sendable {
        /// The Ogg files, in Finder's order; empty for a book without any.
        let files: [URL]
        /// Whether the book is a folder of tracks, rather than one file.
        let isFolder: Bool
    }

    /// The Ogg files `book` plays, found off the main thread by the reader's
    /// rules: its one file when that is Ogg, or the Ogg tracks of its folder,
    /// in Finder's order; none for a book without Ogg audio. Nil when its
    /// folder or any of those files is only in the cloud, so the book waits.
    nonisolated static func oggFiles(of book: Book, access: MaintenanceFileAccess) -> OggFilesFound? {
        let url = URL(fileURLWithPath: book.filePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return OggFilesFound(files: [], isFolder: false)
        }
        guard isDirectory.boolValue else {
            guard OggAudioConverter.isOgg(url) else { return OggFilesFound(files: [], isFolder: false) }
            return access.isDataless(url) ? nil : OggFilesFound(files: [url], isFolder: false)
        }
        guard !access.isDataless(url) else { return nil }
        let files = OggAudioConverter.oggFiles(in: url)
        return files.contains(where: access.isDataless) ? nil : OggFilesFound(files: files, isFolder: true)
    }

    /// `error` as the debug log may give it: a conversion's own words, which
    /// name files, never paths, or else only its domain and code.
    nonisolated static func loggable(_ error: Error) -> String {
        if let failure = error as? OggAudioConverter.Failure, let words = failure.errorDescription { return words }
        let described = error as NSError
        return "\(described.domain) \(described.code)"
    }
}

// MARK: - Renamed Files

extension OggAudioConverter.Conversion {
    /// This conversion the other way round, from its converted file back to
    /// its source, to put a manifest's names back.
    var reversed: OggAudioConverter.Conversion {
        OggAudioConverter.Conversion(
            source: converted,
            converted: source,
            duration: duration,
            secondsTaken: secondsTaken,
            bytesBefore: bytesAfter,
            bytesAfter: bytesBefore,
            bitRate: bitRate
        )
    }
}

extension BookContentIndex {
    /// This index with every audio file `names` maps renamed, each chapter's
    /// and each of its clips', paths relative to the book's audio folder
    /// (B06). Nothing else changes: a book whose tracks were converted
    /// keeps their order and lengths, so its chapters, headings, and the
    /// places saved in them stay as they are.
    func renamingAudioFiles(_ names: [String: String]) -> BookContentIndex {
        var renamed = self
        for chapter in renamed.chapters.indices {
            guard var audio = renamed.chapters[chapter].audio else { continue }
            if let path = audio.relativeFilePath, let new = names[path] {
                audio.relativeFilePath = new
            }
            audio.clips = audio.clips?.map { clip in
                var clip = clip
                if let path = clip.relativeFilePath, let new = names[path] {
                    clip.relativeFilePath = new
                }
                return clip
            }
            renamed.chapters[chapter].audio = audio
        }
        return renamed
    }
}
