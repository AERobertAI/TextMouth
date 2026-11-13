#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

// MARK: - FR02: Opening a Book That Is in the Cloud

/// The cloud services a reader uses to get a book in a cloud library ready
/// to read and keep it playing (FR02). The app's readers use `app`; tests
/// pass fakes.
struct ReaderCloudServices {
    /// Where the library lives, each book's cloud state, and downloads.
    let storage: any BookCloudStorage
    /// Where the reader records what it learns, so the library list shows
    /// the same.
    let states: BookCloudStates
    /// Whether a file's content is only in the cloud.
    let isDataless: @Sendable (URL) -> Bool
    /// Where audiobooks' working copies are made.
    let workingCopies: ReaderWorkingCopies
    /// How often a download without a percentage is announced, in seconds.
    let quietAnnouncementInterval: TimeInterval

    /// The services `storage` and `states` give, with the app's dataless
    /// check, Working Copies folder, and 30-second announcements unless a
    /// test passes its own.
    init(
        storage: any BookCloudStorage,
        states: BookCloudStates,
        isDataless: @escaping @Sendable (URL) -> Bool = { DatalessFiles.isDataless($0) },
        workingCopies: ReaderWorkingCopies = .shared,
        quietAnnouncementInterval: TimeInterval = 30
    ) {
        self.storage = storage
        self.states = states
        self.isDataless = isDataless
        self.workingCopies = workingCopies
        self.quietAnnouncementInterval = quietAnnouncementInterval
    }

    /// The app's services: the installed book storage and the shared store
    /// the library list shows.
    @MainActor
    static var app: ReaderCloudServices {
        ReaderCloudServices(storage: CloudServices.bookStorage, states: .shared)
    }
}

/// What a reader window shows in place of its book while it gets the book
/// from the cloud (FR02).
enum ReaderCloudPhase: Equatable {
    /// The book, or the files of the chapter about to play, are downloading.
    case downloading(ReaderDownload)
    /// The opening download was cancelled: the book isn't ready, and can be
    /// downloaded again.
    case notDownloaded
    /// The book could not be got ready; it can be tried again.
    case failed(ReaderCloudFailure)
    /// The book's package has not arrived on this Mac; it can be tried again.
    case waitingForSync
}

/// One download a reader waits for, as its download view shows it.
struct ReaderDownload: Equatable {
    /// The sync service downloading it, when known.
    let provider: CloudProvider?
    /// The number, from one, of the chapter about to play whose file is only
    /// in the cloud; nil for the download that opens the book.
    let chapterNumber: Int?
    /// When the reader started waiting.
    let startedAt: Date
    /// The latest progress reported, or nil before the first report.
    var progress: BookDownloadProgress?
}

/// What a reader's download is for.
enum ReaderDownloadPurpose: Equatable, Sendable {
    /// Opening the book: loading follows.
    case opening
    /// Playing the chapter with this number, from one, whose file is only in
    /// the cloud: playback goes on once it is here.
    case chapter(Int)

    /// The chapter's number, for a chapter's download.
    var chapterNumber: Int? {
        if case .chapter(let number) = self { return number }
        return nil
    }
}

/// Why a reader could not get its book, or a chapter of it, from the cloud.
enum ReaderCloudFailure: Equatable {
    /// The download failed.
    case download(BookCloudError)
    /// A file was only in the cloud again after its download: the book
    /// cannot be read from this Mac now.
    case partNotOnThisMac
}

/// A reader's cloud work and what it knows (FR02), kept in one stored
/// property of the reader.
struct ReaderCloudSession {
    /// Where the library was when the reader opened its book; nil until the
    /// book has been checked.
    var location: StorageLocation?
    /// The download being waited for, if any.
    var downloadTask: Task<Void, Never>?
    /// What that download is for.
    var downloadPurpose: ReaderDownloadPurpose?
    /// Counts the downloads started, so a state found after one ended is not
    /// recorded over a later one's progress.
    var downloadGeneration = 0
    /// Speaks every so often while a download shows no percentage.
    var quietAnnouncementTask: Task<Void, Never>?
    /// The milestones of the download under way already announced.
    var announcements = ReaderDownloadAnnouncements()
    /// How many reads after a download were refused because a file was only
    /// in the cloud again; the second ends the opening.
    var refusedReads = 0
    /// The working copy an audiobook plays from, when it has one.
    var workingCopy: ReaderWorkingCopy?
    /// Whether the chapter about to play has just been downloaded, so a file
    /// still only in the cloud fails instead of downloading again.
    var chapterJustDownloaded = false
    /// Why the chapter about to play could not be got from the cloud, while
    /// the error alert says so.
    var chapterFailure: ReaderCloudFailure?
}

// MARK: - Announcements

/// Which of a download's milestones VoiceOver has heard: 25, 50, and 75
/// percent, each at most once. When progress jumps past several at once,
/// only the highest is announced.
struct ReaderDownloadAnnouncements: Equatable {
    /// The milestones, in percent.
    static let milestones = [25, 50, 75]

    /// The highest milestone announced so far, or 0 for none.
    private(set) var announcedPercent = 0

    /// The milestone `progress` has newly reached, which is now counted as
    /// announced; nil when it reached none.
    mutating func milestone(reachedBy progress: BookDownloadProgress) -> Int? {
        guard let reached = Self.milestones.last(where: { progress.percent >= $0 && $0 > announcedPercent }) else {
            return nil
        }
        announcedPercent = reached
        return reached
    }
}

// MARK: - Wording

/// Everything a reader shows and speaks about getting its book from the
/// cloud (FR02). Visible text and VoiceOver say the same things; where a
/// visible form abbreviates ("40%", "1:05"), the spoken form spells it out.
enum ReaderCloudWording {
    /// How often the download view's elapsed time steps, in seconds: often
    /// enough to show the wait going on, seldom enough that VoiceOver and a
    /// braille display are not kept busy.
    static let elapsedStep: TimeInterval = 5

    /// The download view's heading.
    static func heading(title: String) -> String {
        "Downloading \(title)"
    }

    /// What VoiceOver calls the download view's progress bar.
    static let progressLabel = "Download progress"

    /// The line below the heading: where the book comes from and, for a
    /// chapter, which one is waited for.
    static func source(provider: CloudProvider?, chapterNumber: Int?) -> String {
        let service = provider?.displayName ?? "the cloud service"
        guard let chapterNumber else { return "From \(service)" }
        return "Chapter \(chapterNumber), from \(service)"
    }

    /// The download's progress, from 0 to 1, or nil when it shows no
    /// percentage (see `showsNoPercentage(_:)`), for an indeterminate bar.
    static func fraction(of download: ReaderDownload) -> Double? {
        guard !showsNoPercentage(download.progress), let progress = download.progress else { return nil }
        return progress.fractionCompleted
    }

    /// Whether a download with `progress` shows no percentage: nothing has
    /// been reported yet, or a single file is all that is left and nothing
    /// counted so far, so a percentage would sit at 0 until the end. A sync
    /// service that reports a part of that file gives the download its
    /// percentage from 1 percent on.
    static func showsNoPercentage(_ progress: BookDownloadProgress?) -> Bool {
        guard let progress else { return true }
        return progress.totalFiles - progress.completedFiles == 1 && progress.percent == 0
    }

    /// The progress bar's value: "2 of 3 files, 40%" on screen and "2 of 3
    /// files, 40 percent" spoken. Without a percentage it is the size of the
    /// one file left, when known, and the time waited: "1 file left, 312 MB,
    /// 1:05 elapsed" ("1 minute, 5 seconds elapsed" spoken), or "Starting,
    /// 0:05 elapsed" before any report.
    static func progressValue(of download: ReaderDownload, elapsed: TimeInterval, spoken: Bool) -> String {
        let waited = "\(spoken ? TimeFormatting.spoken(elapsed) : TimeFormatting.format(elapsed)) elapsed"
        guard let progress = download.progress else {
            return "Starting, \(waited)"
        }
        if showsNoPercentage(progress) {
            var parts = ["1 file left"]
            let bytesLeft = progress.totalBytes - progress.completedBytes
            if progress.totalBytes > 0, bytesLeft > 0 {
                parts.append(ArchiveFigures.size(bytesLeft))
            }
            parts.append(waited)
            return parts.joined(separator: ", ")
        }
        let files = "\(progress.completedFiles) of "
            + CountWording.phrase(progress.totalFiles, singular: "file", plural: "files")
        return "\(files), \(progress.percent)\(spoken ? " percent" : "%")"
    }

    /// The time waited at `date` for a download started at `startedAt`, in
    /// whole `elapsedStep`s.
    static func elapsed(since startedAt: Date, at date: Date) -> TimeInterval {
        let seconds = max(0, date.timeIntervalSince(startedAt))
        return (seconds / elapsedStep).rounded(.down) * elapsedStep
    }

    /// Spoken as a download starts.
    static func downloadStarted(title: String, provider: CloudProvider?, chapterNumber: Int?) -> String {
        let service = provider?.displayName ?? "the cloud service"
        let downloading = "Downloading \(title) from \(service)."
        guard let chapterNumber else { return downloading }
        return "Chapter \(chapterNumber) isn't on this Mac. \(downloading)"
    }

    /// Spoken as a download reaches `percent`, one of the milestones.
    static func milestone(_ percent: Int) -> String {
        "\(percent) percent downloaded."
    }

    /// Spoken every so often while a download shows no percentage.
    static func stillDownloading(elapsed: TimeInterval) -> String {
        "Still downloading, \(TimeFormatting.spoken(elapsed)) elapsed."
    }

    /// Spoken when the opening download is done and the book loads.
    static let downloadedLoading = "Downloaded. Loading."

    /// Spoken when a chapter's download is done and playback goes on.
    static let downloaded = "Downloaded."

    /// Shown and spoken when the opening download is cancelled.
    static func notDownloaded(title: String) -> String {
        "\(title) isn't downloaded."
    }

    /// Spoken when a chapter's download is cancelled.
    static func chapterNotDownloaded(number: Int, title: String) -> String {
        "Chapter \(number) of \(title) isn't downloaded."
    }

    /// Shown and spoken when the book's package has not arrived yet.
    static func waitingForSync(title: String, provider: CloudProvider?) -> String {
        "\(title) hasn't arrived on this Mac yet. \(provider?.displayName ?? "The cloud service") may still be syncing it."
    }

    /// Shown and spoken when a file is only in the cloud again right after
    /// its download.
    static func partNotOnThisMac(title: String) -> String {
        "Part of \(title) isn't on this Mac."
    }

    /// What `failure` is shown and spoken as.
    static func message(for failure: ReaderCloudFailure, title: String, provider: CloudProvider?) -> String {
        switch failure {
        case .download(let error):
            return error.explanation(in: provider)
        case .partNotOnThisMac:
            return partNotOnThisMac(title: title)
        }
    }
}

// MARK: - The Reader

extension ReaderViewModel {

    /// The sync service holding the library, once the book has been
    /// checked and the library is in a cloud location.
    var cloudProvider: CloudProvider? {
        cloudSession.location?.provider
    }

    // MARK: Opening

    /// Goes on opening the book once `loadContent()` has found, off the main
    /// thread, that the library is in the cloud location `location` and the
    /// book's state, checked where the book was at `filePath`, is `state`
    /// (FR02). A book on this Mac loads; a book only partly here downloads
    /// first, even one the library list is already downloading (asking the
    /// sync service again is harmless, and the reader then waits for it
    /// too); a book that has not arrived says so.
    ///
    /// A book the check did not find on this Mac, or found not wholly here,
    /// may only be one whose package the library was moving as the check
    /// looked for it, or has moved since: the check finds no package where
    /// the book was (`.waitingForSync`), or cannot list one in the middle of
    /// its move (`.inCloud`). Its state then goes through the same check as
    /// a failed read (`loadAgainAfterMove(ofFilesReadAt:)`): the book loads
    /// again from where it is, once any move is over, and what this check
    /// found is neither recorded for the library list nor acted on. Before,
    /// the reader said the book had not arrived, or downloaded it, and only
    /// Try Again opened it (TODO P10).
    func continueOpening(in location: StorageLocation, found state: BookCloudState, at filePath: String) {
        guard !hasClosed else { return }
        cloudSession.location = location
        cloudServices.states.setLibraryLocation(location)
        if !Self.isWhollyOnThisMac(state), loadAgainAfterMove(ofFilesReadAt: filePath) {
            return
        }
        switch state {
        case .downloading:
            // That download records its own progress.
            break
        default:
            cloudServices.states.record(state, for: book.id)
        }
        switch state {
        case .local, .downloaded:
            loadDownloadedBook()
        case .inCloud, .downloadFailed, .downloading:
            startDownload(.opening)
        case .waitingForSync:
            stopOpening(
                at: .waitingForSync,
                announcing: ReaderCloudWording.waitingForSync(title: book.title, provider: location.provider)
            )
        }
    }

    /// Whether `state`, a book's cloud state as a check found it, says that
    /// every file of the book is on this Mac, so the book can be read now.
    private static func isWhollyOnThisMac(_ state: BookCloudState) -> Bool {
        switch state {
        case .local, .downloaded:
            return true
        case .inCloud, .downloading, .downloadFailed, .waitingForSync:
            return false
        }
    }

    /// Loads the book, which is on this Mac now, without ever letting a read
    /// wait on the network (FR02): every read runs with downloading switched
    /// off, after a check that none of the book's files is only in the cloud.
    /// An audiobook is first cloned into a working copy, which playback then
    /// reads. A read refused because a file was only in the cloud again goes
    /// back to the download step once; a second refusal ends the opening.
    /// A book whose package the library is moving is opened afresh once the
    /// move is over (`beginReadingForLoad()`, TODO P10).
    func loadDownloadedBook() {
        isLoading = true
        cloudPhase = nil
        guard beginReadingForLoad() else { return }
        let bookCopy = book
        let package = BookPackage(bookCopy)
        let isDataless = cloudServices.isDataless
        // Text books are read into memory when they open, so only an
        // audiobook goes on reading its files and needs a copy.
        let workingCopies = bookCopy.format.isAudio ? cloudServices.workingCopies : nil
        loadQueue.async { [weak self] in
            let read = ReaderViewModel.readDownloadedBook(
                bookCopy,
                package: package,
                workingCopies: workingCopies,
                isDataless: isDataless
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasClosed else {
                    // Nothing will play from a copy made for a reader that
                    // is gone.
                    if let copy = read.workingCopy?.copy {
                        try? copy.remove()
                    }
                    return
                }
                self.finishLoadingDownloadedBook(read, readFrom: bookCopy.filePath)
            }
        }
    }

    /// What loading a downloaded book read: the content or the error, and,
    /// for an audiobook, what became of its working copy.
    struct DownloadedBookRead {
        /// The content, or why it could not be read.
        let content: Result<LoadedContent, Error>
        /// The working copy made or skipped; nil for a text book, and when
        /// reading failed, which leaves no copy.
        let workingCopy: ReaderWorkingCopyResult?
    }

    /// Reads `book`, whose package is `package`, with downloading switched
    /// off on this thread: first a check that none of its files is only in
    /// the cloud, then, given `workingCopies`, its working copy, then the
    /// content, as `loadContent()` reads it. An audiobook's tags are read
    /// from its working copy when it has one. Runs on a background queue.
    nonisolated static func readDownloadedBook(
        _ book: Book,
        package: BookPackage,
        workingCopies: ReaderWorkingCopies?,
        isDataless: @Sendable (URL) -> Bool
    ) -> DownloadedBookRead {
        var workingCopy: ReaderWorkingCopyResult?
        let content = Result {
            try DatalessFiles.withoutDownloading {
                try LocalBookFiles.requireOnThisMac(package.url, isDataless: isDataless)
                workingCopy = workingCopies?.makeCopy(of: package, isDataless: isDataless)
                return try readContent(
                    of: book,
                    audioTagsFrom: workingCopy?.copy?.location(of: book.bookFileURL)
                )
            }
        }
        // A copy made for a read that then failed is of no use.
        if case .failure = content, let copy = workingCopy?.copy {
            try? copy.remove()
            workingCopy = nil
        }
        return DownloadedBookRead(content: content, workingCopy: workingCopy)
    }

    /// Shows the book once `loadDownloadedBook()` has read it, keeping its
    /// working copy, or handles why it could not be read: a refused read
    /// goes back to the download step once, and any other error is shown
    /// as for any book (`showLoadFailure(_:readFrom:)`).
    private func finishLoadingDownloadedBook(_ read: DownloadedBookRead, readFrom filePath: String) {
        switch read.content {
        case .success(let loaded):
            adoptWorkingCopy(read.workingCopy)
            cloudSession.refusedReads = 0
            showLoadedContent(loaded, readFrom: filePath)
        case .failure(let error) where DatalessFiles.isDownloadRefusal(error):
            cloudSession.refusedReads += 1
            DiagnosticLog.event(
                .storage,
                "READER_READ_REFUSED: \(book.title): a file was only in the cloud (refusal \(cloudSession.refusedReads))"
            )
            if cloudSession.refusedReads == 1 {
                startDownload(.opening)
            } else {
                recordStateFoundAfterDownload()
                stopOpening(
                    at: .failed(.partNotOnThisMac),
                    announcing: ReaderCloudWording.partNotOnThisMac(title: book.title)
                )
            }
        case .failure(let error):
            showLoadFailure(error, readFrom: filePath)
        }
    }

    /// Keeps the working copy `result` made, pointed at where the package is
    /// now (the library may have moved it while the book loaded), and logs
    /// what became of it.
    private func adoptWorkingCopy(_ result: ReaderWorkingCopyResult?) {
        switch result {
        case .made(var copy):
            copy.sourceMoved(to: BookPackage(book).url)
            cloudSession.workingCopy = copy
            DiagnosticLog.event(.storage, "WORKING_COPY_MADE: \(book.title)")
        case .skipped(let reason):
            DiagnosticLog.event(.storage, "WORKING_COPY_SKIPPED: \(book.title): \(reason)")
        case nil:
            break
        }
    }

    /// Ends the opening at `phase`, telling VoiceOver `message`. A book that
    /// is not ready cannot play for a finished book that continued to it, so
    /// its waiting request is dropped, as when a book fails to load.
    private func stopOpening(at phase: ReaderCloudPhase, announcing message: String) {
        cloudPhase = phase
        announceCloud(message)
        discardAutoplayRequest()
        // Said after the cloud message that gave the reason.
        releaseSleepTimerHeld(forBook: book.id, afterTheReason: true)
    }

    // MARK: Downloading

    /// Starts downloading the book for `purpose`, showing the download view
    /// in place of the book, and waits for it: its progress shows in the
    /// view and in the library list, VoiceOver hears its start, its
    /// milestones, and its end, and a download without a percentage is
    /// announced every so often.
    ///
    /// A finished book that continued to this one, from its folder or
    /// through the reading list, asked that it play once it has loaded; the
    /// download that opens the book can take longer than that request lasts
    /// on its own, so the request is held for as long as the opening takes,
    /// and claimed once the book has loaded, or dropped when the download
    /// fails or is cancelled (`ReaderAutoplayRequests.hold(for:)`).
    func startDownload(_ purpose: ReaderDownloadPurpose) {
        endDownloadWork(cancelling: true)
        if purpose == .opening {
            autoplayRequests.hold(for: book.id)
        }
        cloudSession.downloadGeneration += 1
        cloudSession.downloadPurpose = purpose
        cloudSession.announcements = ReaderDownloadAnnouncements()
        let provider = cloudProvider
        cloudPhase = .downloading(ReaderDownload(
            provider: provider,
            chapterNumber: purpose.chapterNumber,
            startedAt: Date(),
            progress: nil
        ))
        announceCloud(ReaderCloudWording.downloadStarted(
            title: book.title,
            provider: provider,
            chapterNumber: purpose.chapterNumber
        ))
        DiagnosticLog.event(.storage, "READER_DOWNLOAD_STARTED: \(book.title)\(Self.logSuffix(for: purpose))")

        let storage = cloudServices.storage
        let package = BookPackage(book)
        // Until this download ends, the library list's refreshes leave the
        // book's state to it (paired in `endDownloadWork(cancelling:)`).
        cloudServices.states.beginDownload(of: book.id)
        cloudSession.downloadTask = Task { @MainActor [weak self] in
            do {
                // Asking for the download reads file-system metadata, which
                // can wait on the network.
                let stream = await ReaderViewModel.offMain { storage.download(package) }
                // Cancelling this task ends the iteration, which tells the
                // storage to stop waiting. A stream iterated after that can
                // still hand over what it had, so each step checks first.
                for try await progress in stream {
                    guard !Task.isCancelled, let self else { break }
                    self.downloadDidProgress(progress)
                }
                guard !Task.isCancelled else { return }
                self?.downloadDidFinish(purpose)
            } catch {
                guard !Task.isCancelled else { return }
                self?.downloadDidFail(error, purpose: purpose)
            }
        }
        startQuietAnnouncements()
    }

    /// The download "Download" starts again after its opening download was
    /// cancelled.
    func downloadAgain() {
        guard cloudPhase == .notDownloaded else { return }
        startDownload(.opening)
    }

    /// Cancel: stops waiting for the download under way (the sync service may
    /// finish it anyway) and records the book's state as found afterwards.
    /// An opening download leaves "<title> isn't downloaded." with Download
    /// and Close; a chapter's leaves the reader stopped at that chapter.
    func cancelDownload() {
        guard case .downloading = cloudPhase, let purpose = cloudSession.downloadPurpose else { return }
        stopWaitingForDownload(purpose)
        switch purpose {
        case .opening:
            stopOpening(at: .notDownloaded, announcing: ReaderCloudWording.notDownloaded(title: book.title))
        case .chapter(let number):
            cloudPhase = nil
            stop()
            announceCloud(ReaderCloudWording.chapterNotDownloaded(number: number, title: book.title))
        }
    }

    /// Whether the reader waits for the files of the chapter about to play
    /// to download: it shows Playing, but nothing plays until they are here
    /// (`chapterFilesReadyToPlay()`); or, its files downloaded while a Where
    /// Am I announcement spoke, for the announcement to end
    /// (`isChapterHeldByWhereAmI`), which plays it.
    var isWaitingForChapterDownload: Bool {
        cloudSession.downloadPurpose?.chapterNumber != nil || isChapterHeldByWhereAmI
    }

    /// Stops waiting for the download of the chapter about to play, when one
    /// is under way, so the chapter does not start once the download ends:
    /// playback was paused, or the book's package is about to move. The
    /// sync service may finish the download anyway. The download view gives
    /// way to the book, VoiceOver hears nothing of it (a sleep timer may be
    /// pausing a listener who has fallen asleep), and the book's state is
    /// recorded as found afterwards. When the chapter next plays, its files
    /// are checked afresh, and downloaded again if they are still only in
    /// the cloud. A chapter whose files are here, waiting only for a Where
    /// Am I announcement to end (`isChapterHeldByWhereAmI`), is let go the
    /// same way: it does not start as the announcement ends.
    ///
    /// - Parameter reason: Why, for the log line.
    /// - Returns: Whether the reader waited for a chapter: its download
    ///   under way, or held for Where Am I.
    @discardableResult
    func stopWaitingForChapterDownload(because reason: String) -> Bool {
        if isChapterHeldByWhereAmI {
            isChapterHeldByWhereAmI = false
            DiagnosticLog.trace(.playback, "the chapter held for Where Am I's end does not play: \(reason)")
            return true
        }
        guard let purpose = cloudSession.downloadPurpose, purpose.chapterNumber != nil else { return false }
        stopWaitingForDownload(purpose, because: reason)
        cloudPhase = nil
        return true
    }

    /// Try Again: opens the book afresh, from the check of its state.
    func retryOpening() {
        guard let phase = cloudPhase else { return }
        switch phase {
        case .failed, .waitingForSync:
            cloudSession.refusedReads = 0
            cloudPhase = nil
            loadContent()
        case .downloading, .notDownloaded:
            break
        }
    }

    /// One step of the download under way: shown, recorded for the library
    /// list, and announced when it passes a milestone.
    private func downloadDidProgress(_ progress: BookDownloadProgress) {
        guard case .downloading(var download) = cloudPhase else { return }
        download.progress = progress
        cloudPhase = .downloading(download)
        cloudServices.states.record(.downloading(progress), for: book.id)
        if let milestone = cloudSession.announcements.milestone(reachedBy: progress) {
            announceCloud(ReaderCloudWording.milestone(milestone), priority: .medium)
        }
    }

    /// The download finished: every file of the book is on this Mac. The
    /// book loads, or the chapter waiting for it plays unless the reader was
    /// stopped meanwhile. While a Where Am I announcement speaks, or the end
    /// sound of one that ended by itself plays
    /// (`isWhereAmISpeakingOrSoundingItsEnd`), the chapter waits for it to
    /// end (`isChapterHeldByWhereAmI`), as a Play pressed during it waits,
    /// and plays then (`startPlayHeldByWhereAmI()`); it once started under
    /// the announcement (REV11), and under the end sound.
    private func downloadDidFinish(_ purpose: ReaderDownloadPurpose) {
        endDownloadWork(cancelling: false)
        cloudServices.states.record(.downloaded, for: book.id)
        DiagnosticLog.event(.storage, "READER_DOWNLOAD_FINISHED: \(book.title)\(Self.logSuffix(for: purpose))")
        switch purpose {
        case .opening:
            announceCloud(ReaderCloudWording.downloadedLoading)
            loadDownloadedBook()
        case .chapter:
            announceCloud(ReaderCloudWording.downloaded)
            cloudPhase = nil
            // A reader stopped while it waited stays stopped.
            guard isCurrentlyPlaying && !isCurrentlyPaused else { return }
            cloudSession.chapterJustDownloaded = true
            guard !isWhereAmISpeakingOrSoundingItsEnd else {
                isChapterHeldByWhereAmI = true
                DiagnosticLog.trace(.playback, "the chapter's files are here while Where Am I speaks or sounds its end; it plays after the announcement")
                return
            }
            playAudioChapter()
        }
    }

    /// The download failed with `error`, recorded for the library list. The
    /// opening shows why, with Try Again and Close; a chapter's download
    /// stops the reader at that chapter, with an alert offering Try Again.
    private func downloadDidFail(_ error: Error, purpose: ReaderDownloadPurpose) {
        endDownloadWork(cancelling: false)
        let cloudError = (error as? BookCloudError) ?? .provider(error.localizedDescription)
        let explanation = cloudError.explanation(in: cloudProvider)
        cloudServices.states.record(.downloadFailed(explanation), for: book.id)
        DiagnosticLog.event(
            .storage,
            "READER_DOWNLOAD_FAILED: \(book.title)\(Self.logSuffix(for: purpose)): \(Self.logReason(cloudError))"
        )
        switch purpose {
        case .opening:
            stopOpening(at: .failed(.download(cloudError)), announcing: explanation)
        case .chapter:
            cloudPhase = nil
            stopAtChapter(because: .download(cloudError), message: explanation)
        }
    }

    /// Ends the waiting for the download under way and its announcements,
    /// cancelling the task that waits when `cancelling`; a download ending
    /// on its own needs no cancel. The library list's refreshes record the
    /// book's state again once no download of it runs.
    private func endDownloadWork(cancelling: Bool) {
        if let task = cloudSession.downloadTask {
            if cancelling {
                task.cancel()
            }
            cloudServices.states.endDownload(of: book.id)
        }
        cloudSession.downloadTask = nil
        cloudSession.downloadPurpose = nil
        cloudSession.quietAnnouncementTask?.cancel()
        cloudSession.quietAnnouncementTask = nil
    }

    /// Stops waiting for the download under way for `purpose` (the sync
    /// service may finish it anyway), logs that it was cancelled, and why
    /// when `reason` says, and records the book's state as found afterwards.
    private func stopWaitingForDownload(_ purpose: ReaderDownloadPurpose, because reason: String? = nil) {
        endDownloadWork(cancelling: true)
        let why = reason.map { ": \($0)" } ?? ""
        DiagnosticLog.event(.storage, "READER_DOWNLOAD_CANCELLED: \(book.title)\(Self.logSuffix(for: purpose))\(why)")
        recordStateFoundAfterDownload()
    }

    /// Reads the book's state off the main thread after a download ended
    /// without finishing, and records it for the library list: one forced
    /// refresh of the book, whatever the list's last refresh found, so the
    /// download's last progress never stays shown. (The sync service may go
    /// on downloading; the list's later refreshes follow that.) The record
    /// is made even once the reader has closed, and skipped when a later
    /// download of this reader records its own progress.
    private func recordStateFoundAfterDownload() {
        let storage = cloudServices.storage
        let states = cloudServices.states
        let package = BookPackage(book)
        let generation = cloudSession.downloadGeneration
        Task { @MainActor [weak self] in
            let found = await ReaderViewModel.offMain { storage.state(of: package) }
            if let self, !self.hasClosed, self.cloudSession.downloadGeneration != generation {
                return
            }
            states.record(found, for: package.bookID)
        }
    }

    // MARK: Announcements

    /// Tells VoiceOver `message` at `priority`, keeping it as the reader's
    /// latest announcement, as `announceToVoiceOver(_:)` does.
    private func announceCloud(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        lastAnnouncement = message
        VoiceOverAnnouncer.announce(message, priority: priority)
    }

    /// Announces the download under way every `quietAnnouncementInterval`
    /// while it shows no percentage, until it ends.
    private func startQuietAnnouncements() {
        let interval = cloudServices.quietAnnouncementInterval
        cloudSession.quietAnnouncementTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.announceQuietDownload()
            }
        }
    }

    /// Says the download is still going, and for how long, when it shows no
    /// percentage; a download with one has its milestones instead.
    private func announceQuietDownload() {
        guard case .downloading(let download) = cloudPhase,
              ReaderCloudWording.showsNoPercentage(download.progress) else { return }
        let elapsed = Date().timeIntervalSince(download.startedAt)
        announceCloud(ReaderCloudWording.stillDownloading(elapsed: elapsed), priority: .medium)
    }

    // MARK: Chapters Without a Working Copy

    /// Whether the current chapter's files can be handed to the player: true
    /// unless one is only in the cloud (FR02, `chapterHasFileOnlyInCloud(_:)`).
    /// AVPlayer would wait on the network for such a file, so instead the
    /// book downloads, with the same view, as a short pause, and the chapter
    /// plays once it is here; the reader shows Playing meanwhile. Offline,
    /// the download fails at once and the reader stops at the chapter with
    /// the reason and Try Again. Before all that, nothing Ogg is handed to
    /// the player (`chapterAudioIsClearOfOgg()`, B06).
    func chapterFilesReadyToPlay() -> Bool {
        guard chapterAudioIsClearOfOgg() else { return false }
        guard checksChapterFiles else { return true }
        // A chapter download under way plays the cursor's chapter when it
        // is done.
        guard cloudSession.downloadTask == nil else { return false }

        let inCloud = chapterHasFileOnlyInCloud(currentChapterIndex)
        let justDownloaded = cloudSession.chapterJustDownloaded
        cloudSession.chapterJustDownloaded = false
        guard inCloud else { return true }

        let chapterNumber = currentChapterIndex + 1
        if justDownloaded {
            // Still only in the cloud right after its download: stop here
            // rather than download over and over.
            DiagnosticLog.event(
                .storage,
                "READER_READ_REFUSED: \(book.title): chapter \(chapterNumber) was only in the cloud after its download"
            )
            stopAtChapter(because: .partNotOnThisMac, message: ReaderCloudWording.partNotOnThisMac(title: book.title))
            return false
        }
        DiagnosticLog.trace(.playback, "chapter \(currentChapterIndex) has a file only in the cloud; downloading first")
        isCurrentlyPlaying = true
        isCurrentlyPaused = false
        startDownload(.chapter(chapterNumber))
        return false
    }

    /// Whether a file chapter `chapterIndex` plays from is only in the cloud,
    /// where the player would wait on the network for it (FR02): the current
    /// chapter's before it plays, and the next chapter's before it is named
    /// to follow (TODO PERF09). Only a book in a cloud library without a
    /// working copy can have one (`checksChapterFiles`): a copy is on this
    /// Mac by construction. Each file is looked at with one lstat(2) made
    /// with downloading switched off, so the check never waits on the
    /// network either.
    func chapterHasFileOnlyInCloud(_ chapterIndex: Int) -> Bool {
        guard checksChapterFiles else { return false }
        let isDataless = cloudServices.isDataless
        return chapterAudioSource(forChapterAt: chapterIndex).files.contains {
            LocalBookFiles.availability(of: $0, isDataless: isDataless) == .inCloud
        }
    }

    /// Whether each chapter's files are checked for being only in the cloud
    /// before the player is handed them: in a cloud library, for a book
    /// without a working copy.
    private var checksChapterFiles: Bool {
        cloudSession.location?.isCloud == true && cloudSession.workingCopy == nil
    }

    /// Stops the reader at the current chapter, whose files could not be got
    /// from the cloud, and shows why in the error alert, which offers Try
    /// Again (`retryAudioPlayback()`, which plays the chapter afresh).
    private func stopAtChapter(because failure: ReaderCloudFailure, message: String) {
        stop()
        cloudSession.chapterFailure = failure
        errorMessage = message
        announceCloud(message)
    }

    // MARK: Working Copy

    /// The file playback reads for the book's file at `url`: its working
    /// copy, when the reader has one, and otherwise `url` itself.
    func playbackURL(for url: URL) -> URL {
        cloudSession.workingCopy?.location(of: url) ?? url
    }

    /// Whether playback reads the book's working copy.
    var playsFromWorkingCopy: Bool {
        cloudSession.workingCopy != nil
    }

    /// Notes, after the library moved the book's files, that the working
    /// copy now came from where the package is. The copy itself did not
    /// move, so playback reading it goes on undisturbed.
    func workingCopyFollowsMovedPackage() {
        cloudSession.workingCopy?.sourceMoved(to: BookPackage(book).url)
    }

    // MARK: Closing

    /// Stops waiting for a download as the reader closes, recording the
    /// book's state as found afterwards, and lets go of the requests held
    /// while the book downloaded.
    func endCloudWorkForClose() {
        // A request to start this book, held while it downloaded, ages again
        // from when it was made, so one older than its lifetime lapses.
        autoplayRequests.release(for: book.id)
        guard let purpose = cloudSession.downloadPurpose else {
            endDownloadWork(cancelling: true)
            return
        }
        stopWaitingForDownload(purpose, because: "the reader closed")
    }

    /// Deletes the working copy, off the main thread, once nothing plays from
    /// it.
    func removeWorkingCopy() {
        guard let copy = cloudSession.workingCopy else { return }
        cloudSession.workingCopy = nil
        let title = book.title
        DispatchQueue.global(qos: .utility).async {
            do {
                try copy.remove()
                DiagnosticLog.event(.storage, "WORKING_COPY_REMOVED: \(title)")
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "WORKING_COPY_LEFT: \(title): \(ReaderWorkingCopies.describe(error)); the next session sweeps it away"
                )
            }
        }
    }

    // MARK: Helpers

    /// Runs `work` on a global queue and hands back its result: for
    /// file-system metadata, which can wait on the network in a cloud
    /// folder. Never on Swift concurrency's own threads, which must not be
    /// kept waiting.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// How a log line names a download's purpose: nothing for the opening,
    /// the chapter for a chapter's.
    private static func logSuffix(for purpose: ReaderDownloadPurpose) -> String {
        purpose.chapterNumber.map { " (chapter \($0))" } ?? ""
    }

    /// How a log line names why a download failed.
    private static func logReason(_ error: BookCloudError) -> String {
        switch error {
        case .offline:
            return "offline"
        case .stalled(let seconds):
            return "stalled for \(seconds) seconds"
        case .provider(let message), .removalFailed(let message):
            return "the sync service said: \(message)"
        case .notUploaded:
            return "changes not uploaded"
        case .bookIsOpen:
            return "the book is open"
        case .keptOnThisMac:
            return "the book is kept on this Mac"
        case .keptForReadingList:
            return "the book is kept on this Mac for the reading list"
        case .packageMissing:
            return "the package is not on this Mac"
        }
    }
}
