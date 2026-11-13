import XCTest
@testable import TextMouth

// Shared fixtures for the integration tests (TODO Q04). Each of those tests
// enters a repaired workflow at its real boundary (a menu command's import,
// a library save, a notification the router hears, a running sleep timer,
// a reader's chapter end, a reader's load) and checks what the user would
// notice, rather than calling the helper the repair introduced.

// MARK: - A Library Folder of the Test's Own

/// A folder of one test's own inside the hosted tests' isolated library.
///
/// Work done in it leaves its traces where nothing else writes, so the
/// folder's complete listing, hidden names included, shows exactly what the
/// work left behind: a published package, or the hidden package an import
/// stages before publishing.
struct IntegrationLibraryFolder {
    /// The folder's path inside the library, as books and folders name it.
    let path: String

    /// The folder on disk.
    var url: URL {
        TextMouthPaths.libraryDir.appendingPathComponent(path, isDirectory: true)
    }

    /// Every name in the folder, hidden ones included, or none when the
    /// folder does not exist.
    func entries() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    /// Removes the folder and everything in it. Queued package writes are
    /// made first, so none can land in a package after it is gone, and
    /// permission is given back to every directory first, the folder's own
    /// before its contents are listed, since a test may have taken it away.
    func remove() {
        LibraryPersistenceService.flushPendingSave()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            // Each directory is listed only after it has been returned here,
            // so its permission is back before its own contents are read.
            for case let relative as String in enumerator {
                chmod(url.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// A new library folder of this test's own, named after `label`, that is
    /// removed with everything in it when the test ends. The folder is not
    /// created here: the work under test creates it as it would any folder.
    func makeIntegrationLibraryFolder(_ label: String) -> IntegrationLibraryFolder {
        let folder = IntegrationLibraryFolder(path: "\(label) \(UUID().uuidString.prefix(8))")
        addTeardownBlock { folder.remove() }
        return folder
    }
}

// MARK: - A World of Readers

/// The private surroundings of an integration test that opens real readers
/// on books in real packages.
///
/// Everything a reader reaches beyond its book is the test's own: an inert
/// library model (it starts no disk maintenance, observers, or background
/// analysis), settings in a sandboxed preferences store mirrored to a config
/// file of the test's own, an empty set of substitution rules, a private
/// notification center, so the running app's windows never hear what the
/// readers post, and a private autoplay request store. Packages live in a
/// library folder of the test's own. The shared library index and listening
/// statistics, which readers write as they save positions and sessions,
/// are put back when the test ends, after every reader is closed.
@MainActor
final class IntegrationWorld {
    /// The library folder holding the world's packages.
    let folder: IntegrationLibraryFolder
    /// The library model the readers save through.
    let library: LibraryViewModel
    /// The settings the readers follow.
    let settings: SettingsViewModel
    /// Where the readers post and listen.
    let notifications: NotificationCenter
    /// The requests a finished book leaves for the next book's reader.
    let autoplayRequests: ReaderAutoplayRequests
    /// Every reader opened in this world, closed when the test ends.
    private(set) var readers: [ReaderViewModel] = []

    fileprivate init(folder: IntegrationLibraryFolder, settings: SettingsViewModel, notifications: NotificationCenter) {
        self.folder = folder
        self.settings = settings
        self.notifications = notifications
        autoplayRequests = ReaderAutoplayRequests()
        library = LibraryViewModel(initializeServices: false)
        library.library = Library()
    }

    /// Opens a reader for `book`, which starts loading its content at once,
    /// as a reader window's model does.
    ///
    /// - Parameters:
    ///   - renderScheduler: Renders the reader's look-ahead; nil uses the
    ///     app's shared render queue.
    ///   - nowPlaying: The Now Playing coordinator the reader joins, which a
    ///     test sends the system's media commands through; nil uses the
    ///     app's shared one.
    ///   - loadQueue: The queue the reader's loads read its book's files
    ///     on, which a test can hold; nil uses a global queue, as the app
    ///     does.
    ///   - cloud: The cloud services the reader gets its book ready with,
    ///     whose storage a test can observe; nil uses the app's.
    ///   - sleepTimer: The sleep timer of the reader's window, which a test
    ///     gives the readers it puts in one window, as a window gives each
    ///     book it shows (`ReaderWindowContent`); nil gives the reader the
    ///     default (`ReaderViewModel.init(sleepTimer:)`).
    func openReader(
        for book: Book,
        renderScheduler: (any SpeechRenderScheduling)? = nil,
        nowPlaying: NowPlayingService? = nil,
        loadQueue: DispatchQueue? = nil,
        cloud: ReaderCloudServices? = nil,
        sleepTimer: SleepTimerService? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: autoplayRequests,
            notificationCenter: notifications,
            renderScheduler: renderScheduler,
            cloud: cloud,
            nowPlaying: nowPlaying,
            loadQueue: loadQueue,
            sleepTimer: sleepTimer
        )
        readers.append(reader)
        return reader
    }

    /// An audio book of silent WAV tracks, one per entry of `trackDurations`
    /// (seconds), named "01.wav", "02.wav", and so on, in a package of its
    /// own in the world's folder, indexed as an import indexes it and listed
    /// in the library. A reader playing it is never heard.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - savedPosition: Where the book was last read, if anywhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    ///   - manifest: The text of a manifest.json to put beside the tracks
    ///     before the book is indexed, exactly as given; nil for none.
    func makeSilentAudioBook(
        title: String,
        trackDurations: [TimeInterval],
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop,
        manifest: String? = nil
    ) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let tracks = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
            .appendingPathComponent("Tracks", isDirectory: true)
        for (number, duration) in trackDurations.enumerated() {
            let name = String(format: "%02d.wav", number + 1)
            try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent(name), duration: duration)
        }
        if let manifest {
            try Data(manifest.utf8).write(to: tracks.appendingPathComponent(AudioManifest.fileName))
        }
        let book = Book(
            title: title,
            format: .audio,
            filePath: tracks.path,
            md5Hash: UUID().uuidString,
            folderPath: folder.path,
            readingPosition: savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        return try indexAndList(book)
    }

    /// A segmented audiobook, as a DAISY book is read: silent WAV files
    /// named and timed by `files` (seconds), in an audio folder of a package
    /// of its own in the world's folder, with a manifest whose `sections`
    /// are the book's headings, each playing one or more clips of those
    /// files. It is indexed as an import indexes it and listed in the
    /// library, and its end-of-book behavior is `endOfBook`, Stop unless
    /// given. A reader playing it is never heard.
    func makeSegmentedAudioBook(
        title: String,
        files: [String: TimeInterval],
        sections: [AudioSegment],
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let audio = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
            .appendingPathComponent("audio", isDirectory: true)
        for (name, duration) in files {
            try AudioTestFixtures.writeSilence(to: audio.appendingPathComponent(name), duration: duration)
        }
        try JSONEncoder().encode(AudioManifest(title: title, segments: sections))
            .write(to: audio.appendingPathComponent("manifest.json"))
        let book = Book(
            title: title,
            format: .audio,
            filePath: audio.path,
            md5Hash: UUID().uuidString,
            folderPath: folder.path,
            readingPosition: savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        return try indexAndList(book)
    }

    /// An audiobook of one silent WAV file lasting `duration` seconds, in a
    /// package of its own in the world's folder, indexed and listed: one
    /// chapter, which plays the file whole (`AudioLayout.singleFile`). A
    /// reader playing it is never heard.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - savedPosition: Where the book was last read, if anywhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    func makeSilentAudioFileBook(
        title: String,
        duration: TimeInterval,
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        try makeOneFileAudioBook(
            title: title,
            fileName: "\(title).wav",
            savedPosition: savedPosition,
            endOfBook: endOfBook
        ) { file in
            try AudioTestFixtures.writeSilence(to: file, duration: duration)
        }
    }

    /// An audiobook of one file, named `fileName`, which `write` writes
    /// where it is given, in a package of its own in the world's folder,
    /// indexed and listed as `makeSilentAudioBook` lists a book of tracks.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - fileName: The audio file's name in the package.
    ///   - savedPosition: Where the book was last read, if anywhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    ///   - write: Writes the audio file at the URL given.
    func makeOneFileAudioBook(
        title: String,
        fileName: String,
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop,
        write: (URL) throws -> Void
    ) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let file = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
            .appendingPathComponent(fileName)
        try write(file)
        let book = Book(
            title: title,
            format: .audio,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: folder.path,
            readingPosition: savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        return try indexAndList(book)
    }

    /// Indexes `book` as an import indexes it, saves its record with the
    /// index in its package, and lists it in the library.
    private func indexAndList(_ book: Book) throws -> Book {
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        library.library.addBook(book)
        return book
    }

    /// Imports `source` into the world's folder as the library imports a
    /// chosen file, and lists the book.
    func importBook(from source: URL) throws -> Book {
        let book = try FileImportService.importFileWithReport(from: source, toFolder: folder.path).book
        library.library.addBook(book)
        return book
    }

    /// Closes every reader opened in the world.
    fileprivate func closeReaders() {
        for reader in readers {
            reader.close()
        }
    }
}

extension XCTestCase {
    /// A new world of readers for this test, named after `label`, taken
    /// apart when the test ends: every reader is closed, the shared
    /// listening statistics and library index are put back, and the
    /// world's folder, config file, and preferences are removed.
    @MainActor
    func makeIntegrationWorld(_ label: String) throws -> IntegrationWorld {
        // Tear-down blocks run last registered first, so these are
        // registered in the reverse of the order they must run in.
        let folder = makeIntegrationLibraryFolder(label)
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        addTeardownBlock {
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }

        let notifications = NotificationCenter()
        let configFile = try makeSandboxDirectory("\(label) Config").appendingPathComponent("config.json")
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: makeSandboxedPreferences(label),
            configService: ConfigService(fileURL: configFile)
        )
        let world = IntegrationWorld(folder: folder, settings: settings, notifications: notifications)
        addTeardownBlock { world.closeReaders() }
        return world
    }

    /// An audiobook of one file with chapter markers, an m4b, in a package
    /// of its own in `world`'s folder, indexed and listed as
    /// `IntegrationWorld.makeSilentAudioBook` lists a book of tracks:
    /// `markers` name and time its chapters, which `AudioBookParser` makes
    /// its headings (`AudioLayout.chaptersInOneFile`). A reader playing it
    /// is never heard.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also names its file.
    ///   - world: The world whose folder and library hold the book.
    ///   - duration: Seconds of silence in the file.
    ///   - markers: The file's chapter markers.
    ///   - savedPosition: Where the book was last read, if anywhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    @MainActor
    func makeChapteredAudioBook(
        title: String,
        in world: IntegrationWorld,
        duration: TimeInterval,
        markers: [AudioTestFixtures.ChapterMarker],
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        try world.makeOneFileAudioBook(
            title: title,
            fileName: "\(title).m4b",
            savedPosition: savedPosition,
            endOfBook: endOfBook
        ) { file in
            try writeChapteredAudio(to: file, duration: duration, markers: markers)
        }
    }

    /// Write `duration` seconds of silence to `url` as an m4b whose chapter
    /// markers are `markers` (`AudioTestFixtures.writeChapteredAAC`). The
    /// fixture is asynchronous: a task writes the file while this spins the
    /// main run loop, as the hosted helpers do, until it is written.
    @MainActor
    private func writeChapteredAudio(
        to url: URL,
        duration: TimeInterval,
        markers: [AudioTestFixtures.ChapterMarker]
    ) throws {
        let writing = FixtureWriting()
        Task { @MainActor in
            do {
                try await AudioTestFixtures.writeChapteredAAC(to: url, duration: duration, chapters: markers)
            } catch {
                writing.error = error
            }
            writing.isDone = true
        }
        XCTAssertTrue(eventually(within: 30) { writing.isDone }, "The m4b was not written in time")
        if let error = writing.error {
            throw error
        }
    }

    /// Waits until `reader` has finished loading its book, successfully or
    /// not, including what it does as loading ends, and fails the test when
    /// it never does.
    @MainActor
    func waitForReaderToLoad(
        _ reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 10) { !reader.isLoading },
            "\(reader.book.title) never finished loading",
            file: file,
            line: line
        )
    }

    /// Stops the app's one shared sleep timer now, and when the test ends
    /// stops it again and puts back the duration it last used and the
    /// preference that duration is kept in, so no timer a test sets
    /// outlives the test. Call it before making the world whose readers set
    /// a timer, so the readers are closed first.
    @MainActor
    func preserveSharedSleepTimer() {
        let timer = SleepTimerService.shared
        // Registered first, so it runs last: after the reset below, which
        // removes the preference.
        preservePreferences(["sleepTimer.lastUsedDuration"])
        let savedDuration = timer.lastUsedDuration
        timer.stop(reason: "integration test started")
        addTeardownBlock {
            timer._resetForTesting()
            // Starting and stopping a timer is the one way to set the
            // remembered duration; the stop clears everything else.
            if let savedDuration {
                timer.start(duration: savedDuration, ownerID: UUID(), onExpire: {})
                timer.stop(reason: "integration test ended")
            }
        }
    }
}

/// Whether a fixture a task writes is written, and what went wrong.
@MainActor
private final class FixtureWriting {
    var isDone = false
    var error: Error?
}

// MARK: - Loads Held by the Test

/// A queue for a reader's loads (`ReaderViewModel.loadQueue`) that holds
/// every read until the test lets them read, so the test chooses the moment
/// a load reads its book's files, such as the middle of a move of the
/// book's package (TODO P10). It is a serial queue whose first work waits
/// at a gate, so each load queued behind it waits too.
@MainActor
final class HeldLoads {
    /// The queue the reader's loads read on.
    let queue = DispatchQueue(label: "IntegrationTestSupport.HeldLoads", qos: .userInitiated)
    /// The gate the queue's first work waits at, opened by `letRead()`.
    private let gate = DispatchSemaphore(value: 0)
    /// Whether the gate is open.
    private var isOpen = false

    init() {
        queue.async { [gate] in
            // Held for longer than any test takes, but never for ever.
            _ = gate.wait(timeout: .now() + 120)
        }
    }

    /// Lets the loads read: those held, and every later one at once.
    func letRead() {
        guard !isOpen else { return }
        isOpen = true
        gate.signal()
    }

    /// Lets the loads read, and waits, the main run loop turning, until
    /// each load queued so far has read and its reader has taken what it
    /// read on the main queue. Fails the test when that takes too long.
    func letReadAndHandOver(file: StaticString = #filePath, line: UInt = #line) {
        letRead()
        let handedOver = LoadsHandedOver()
        // Queued after every load so far, so it runs once each has read,
        // and its block reaches the main queue after each of theirs.
        queue.async {
            DispatchQueue.main.async {
                handedOver.isDone = true
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !handedOver.isDone, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(handedOver.isDone, "The loads did not read and hand over in time", file: file, line: line)
    }

    /// Lets the loads read, and waits, the main thread blocked, until
    /// each load queued so far has read: what each read then waits on the
    /// main queue, for its reader to take once the main run loop turns.
    /// Fails the test when the reads take too long.
    func letReadBeforeHandingOver(file: StaticString = #filePath, line: UInt = #line) {
        letRead()
        let read = DispatchSemaphore(value: 0)
        // Queued after every load so far, so it runs once each has read.
        queue.async {
            read.signal()
        }
        XCTAssertEqual(read.wait(timeout: .now() + 30), .success, "The loads did not read in time", file: file, line: line)
    }
}

/// Whether the loads a test let read have handed over what they read.
@MainActor
private final class LoadsHandedOver {
    var isDone = false
}

extension XCTestCase {
    /// A queue of this test's own for a reader's loads, holding their reads
    /// until the test lets them read, and at the latest when the test ends.
    @MainActor
    func holdLoads() -> HeldLoads {
        let loads = HeldLoads()
        addTeardownBlock { loads.letRead() }
        return loads
    }
}

// MARK: - Package Moves Made by the Test

extension LibraryTransitionDisk {
    /// The disk operations of a library transition made through
    /// `commitLibraryTransition`, which runs them on the main actor: each
    /// package moves for real, and `afterFirstMove` runs once, after the
    /// first package has moved and before the library holds the books' new
    /// rows, as anything can run on the main thread then while a move made
    /// off it (`performLibraryTransition`) is under way. With
    /// `failingRecords`, no book's record can be written once its package
    /// has moved, so the transition is put back, each package moving back
    /// where it was, which runs `afterFirstMove` no second time.
    @MainActor
    static func movingPackages(
        failingRecords: Bool = false,
        afterFirstMove: @escaping @MainActor @Sendable () -> Void
    ) -> LibraryTransitionDisk {
        let moves = PackageMoveCount()
        return LibraryTransitionDisk(
            moveItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                MainActor.assumeIsolated {
                    moves.count += 1
                    if moves.count == 1 {
                        afterFirstMove()
                    }
                }
            },
            writeRecord: { book in
                if failingRecords {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try book.saveBookInfoThrowing()
            }
        )
    }
}

/// How many packages a test's transition has moved, the moves back of a
/// transition put back included.
@MainActor
private final class PackageMoveCount {
    var count = 0
}

// MARK: - Book Storage Observed by the Test

/// Book storage that answers as `storage` does, except that, once a test
/// asks, a package missing from disk is waiting for sync, as the app's
/// storage finds such a package (`BookCloudStorageService.state(of:in:)`)
/// whatever state `storage` would give: so a reader whose load checks its
/// book where the package has just moved away from finds it as it would
/// in the app (TODO P10). It also counts the reads of their books its
/// readers begin, as each load asks first where the library is
/// (`ReaderViewModel.loadContent()`), so a test can tell that nothing was
/// read at a given moment. Safe to call from any thread, as readers' loads
/// call in from their own queues.
final class ObservedBookStorage: BookCloudStorage, @unchecked Sendable {
    /// Where every answer comes from but the one above.
    private let storage: any BookCloudStorage
    /// Guards every stored property below.
    private let lock = NSLock()
    /// Whether a package missing from disk is waiting for sync.
    private var missingPackagesWaitForSync = false
    /// How many times a reader asked where the library is.
    private var locationsAsked = 0

    /// Storage answering as `storage` does: a local library's unless a test
    /// gives its own.
    init(_ storage: any BookCloudStorage = LocalBookStorage()) {
        self.storage = storage
    }

    /// From now on, a package missing from disk is waiting for sync.
    func answerWaitingForSyncForMissingPackages() {
        lock.withLock { missingPackagesWaitForSync = true }
    }

    /// How many reads of their books the readers asking this storage have
    /// begun so far.
    var readsBegun: Int {
        lock.withLock { locationsAsked }
    }

    /// Where `storage` says the library is, counted as a read begun.
    func libraryLocation() -> StorageLocation {
        lock.withLock { locationsAsked += 1 }
        return storage.libraryLocation()
    }

    /// Waiting for sync for a package missing from disk, once a test asked;
    /// otherwise what `storage` says.
    func state(of package: BookPackage) -> BookCloudState {
        let followsTheDisk = lock.withLock { missingPackagesWaitForSync }
        if followsTheDisk, !FileManager.default.fileExists(atPath: package.url.path) {
            return .waitingForSync
        }
        return storage.state(of: package)
    }

    /// `storage`'s size.
    func bytesToDownload(of package: BookPackage) -> Int64? {
        storage.bytesToDownload(of: package)
    }

    /// `storage`'s download.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        storage.download(package)
    }

    /// `storage`'s removal of a download.
    func removeDownload(of package: BookPackage) throws {
        try storage.removeDownload(of: package)
    }
}

// MARK: - Where Am I's End Sound, Passed by the Test

/// The work a reader's Where Am I announcement leaves for once its end
/// sound has played (the book it paused resuming, a play it held starting),
/// held for the test to run when it chooses
/// (`ReaderViewModel._afterWhereAmIEndSoundForTesting`), so that no test
/// waits out the sound, and a test can act in the moment before it passes.
@MainActor
final class WhereAmIEndSoundClock {
    /// The work held, oldest first.
    private var waiting: [@MainActor @Sendable () -> Void] = []

    /// Holds `reader`'s end-sound work from now on, in place of the main
    /// queue's delay.
    init(holdingFor reader: ReaderViewModel) {
        reader._afterWhereAmIEndSoundForTesting = { [self] work in
            waiting.append(work)
        }
    }

    /// Whether work waits for the end sound's moment to pass.
    var hasWorkWaiting: Bool {
        !waiting.isEmpty
    }

    /// Lets the end sound's moment pass: runs the work held, oldest first,
    /// as the main queue would once the delay is up.
    func passEndSound() {
        let due = waiting
        waiting.removeAll()
        for work in due {
            work()
        }
    }
}

// MARK: - Sound Effects Recorded, Never Heard

/// Sound effects that record each event they are asked to play, and play
/// nothing, for a reader whose sounds a test checks
/// (`ReaderViewModel.soundEffectService`).
final class RecordedSoundEffects: SoundEffectService {
    /// The events asked for, oldest first.
    var played: [SoundEvent] = []

    override func play(for event: SoundEvent) {
        played.append(event)
    }
}

// MARK: - Fixture EPUBs

/// One chapter of a fixture EPUB: an XHTML document in the reading order.
struct IntegrationEPUBChapter {
    /// The document's file name, beside the package document.
    let fileName: String
    /// The markup inside the document's body.
    let body: String
}

/// One entry of a fixture EPUB's table of contents.
struct IntegrationTOCEntry {
    /// What the entry says, which the reader lists as a heading.
    let label: String
    /// Where it leads: a chapter's file name, with a fragment when it leads
    /// to a place inside the chapter.
    let target: String
}

/// Writes small EPUB 3 books the way a publisher packages them: a package
/// document listing every chapter in reading order, and a navigation
/// document whose table of contents leads into them.
enum IntegrationEPUB {
    /// Writes the book `title`, holding `chapters` in reading order and a
    /// table of contents of `contents`, as an EPUB file at `url`.
    static func write(
        title: String,
        chapters: [IntegrationEPUBChapter],
        contents: [IntegrationTOCEntry],
        to url: URL
    ) throws {
        let manifest = chapters.enumerated().map { number, chapter in
            "<item id=\"c\(number + 1)\" href=\"\(chapter.fileName)\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined()
        let tableOfContents = contents.map { "<li><a href=\"\($0.target)\">\($0.label)</a></li>" }.joined()

        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title)</dc:title><dc:creator>Odalys Pretorius</dc:creator><dc:language>en</dc:language>
            </metadata>
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\(manifest)</manifest>
            <spine>\(spine)</spine>
            </package>
            """.utf8),
            "OEBPS/nav.xhtml": Data(page(
                title: "Contents",
                body: "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\(tableOfContents)</ol></nav>"
            ).utf8),
        ]
        for chapter in chapters {
            entries["OEBPS/\(chapter.fileName)"] = Data(page(title: title, body: chapter.body).utf8)
        }

        let archive = try makeTemporaryZip(prefix: "IntegrationEPUB", entries: entries)
        try FileManager.default.moveItem(at: archive, to: url)
    }

    /// An XHTML document titled `title` whose body is `body`.
    private static func page(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title)</title></head>
        <body>\(body)</body></html>
        """
    }
}
