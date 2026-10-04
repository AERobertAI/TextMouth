import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Opening the audio editor (FR04): Edit Audio… in a library row's commands
/// and the reader's Book menu; a book of several tracks asks which, by
/// chapter name; a book open in a reader is closed there first, with a
/// sentence; an edit history that can't be read is started over only when
/// the user says so; and the window, titled by the book and the track,
/// starts VoiceOver on its time display. No test opens a real window or
/// plays a sound.
@MainActor
final class AudioEditorOpeningTests: XCTestCase {

    // MARK: - Words

    /// The window names the book, and the track of a book of several.
    func testTheWindowIsTitledByTheBookAndTheTrack() {
        XCTAssertEqual(AudioEditorWording.windowTitle(book: "Ferry Log", track: nil), "Edit Audio: Ferry Log")
        XCTAssertEqual(AudioEditorWording.windowTitle(book: "Ferry Log", track: "Second Crossing"), "Edit Audio: Ferry Log, Second Crossing")
        XCTAssertEqual(AudioEditorWording.editAudioCommand, "Edit Audio…")
    }

    /// Times show as clocks, to the tenth when there is one, and VoiceOver
    /// speaks them in words.
    func testTimesShowAsClocksAndAreSpokenInWords() {
        XCTAssertEqual(AudioEditorWording.clock(0), "0:00")
        XCTAssertEqual(AudioEditorWording.clock(724.3), "12:04.3")
        XCTAssertEqual(AudioEditorWording.clock(724.04), "12:04")
        XCTAssertEqual(AudioEditorWording.clock(3_723.5), "1:02:03.5")
        XCTAssertEqual(AudioEditorWording.clock(59.96), "1:00")
        XCTAssertEqual(AudioEditorWording.clock(.nan), "--:--")
        XCTAssertEqual(AudioEditorWording.clock(-1), "--:--")
        XCTAssertEqual(AudioEditorWording.positionText(724.3, of: 2_880), "12:04.3 of 48:00")
        XCTAssertEqual(AudioEditorWording.positionValue(724.3, of: 2_880), "12 minutes, 4.3 seconds of 48 minutes")
        XCTAssertEqual(
            AudioEditorWording.status(["1 second of 2 seconds", AudioEditorWording.inChapter(number: 3, title: "Tide Tables")]),
            "1 second of 2 seconds; in chapter 3: Tide Tables"
        )
    }

    // MARK: - Tracks

    /// A book kept in one file has no track to choose.
    func testABookOfOneFileHasNoTrackToChoose() throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        XCTAssertEqual(try AudioEditorTracks.of(fixture.book), .oneFile)
    }

    /// A folder of tracks lists them in the order the book plays them, by
    /// their chapter names from the manifest, or else by their files' names,
    /// each with its path inside the package.
    func testAFolderOfTracksListsThemInTheBooksOrderByChapterName() throws {
        let fixture = try trackBook(manifest: AudioManifest(
            title: "Ferry Log",
            chapters: ["b.wav": "Second Crossing"],
            order: ["b.wav", "a.wav"]
        ))

        XCTAssertEqual(try AudioEditorTracks.of(fixture.book), .tracks([
            AudioEditorTrack(path: "audio/b.wav", title: "Second Crossing"),
            AudioEditorTrack(path: "audio/a.wav", title: "a"),
        ]))
    }

    /// A folder whose manifest plays sections that are stretches of its
    /// tracks can't be edited yet: an edit would move them.
    func testAFolderOfSectionsCannotBeEdited() throws {
        let segment = AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 0.25)
        let fixture = try trackBook(manifest: AudioManifest(title: "Ferry Log", segments: [segment]))

        XCTAssertEqual(try AudioEditorTracks.of(fixture.book), .sections)
    }

    // MARK: - Opening

    /// Only an audiobook kept in a package of its own can be edited; any
    /// other book is refused with a sentence, and nothing opens.
    func testOnlyAnAudiobookInAPackageCanBeEdited() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        let textBook = Book(title: "Lock Keeper", format: .markdown, filePath: "/nonexistent/lock.md", md5Hash: "lock",
                            tmbDirectoryName: "lock.tmb")
        let script = LauncherScript()

        let outcome = await AudioEditorLauncher.open(textBook, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .refused(AudioEditorWording.notAnAudiobook))
        XCTAssertEqual(script.announced, [AudioEditorWording.notAnAudiobook])
        XCTAssertTrue(script.presented.isEmpty)
        XCTAssertTrue(AudioEditorLauncher.canEdit(fixture.book))
        XCTAssertFalse(AudioEditorLauncher.canEdit(textBook))
    }

    /// A book whose editor is open comes forward, with a sentence, and no
    /// second editor opens.
    func testAnOpenEditorComesForwardInsteadOfASecond() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        let script = LauncherScript()
        script.windows.open.insert(fixture.book.id)

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .broughtForward)
        XCTAssertEqual(script.windows.broughtForward, [fixture.book.id])
        XCTAssertEqual(script.announced, ["The audio editor for Harbour Survey is already open."])
        XCTAssertTrue(script.presented.isEmpty)
    }

    /// A book of one file opens at once on its own file, through a real
    /// edit session, and nothing is asked.
    func testABookOfOneFileOpensAtOnce() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        let script = LauncherScript()

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .opened(track: nil))
        XCTAssertEqual(script.questions, [])
        let session = try XCTUnwrap(script.presented.first?.session)
        XCTAssertEqual(session.audioFile, "Harbour Survey.wav")
        XCTAssertEqual(session.duration, 1, accuracy: 0.000_1)
        XCTAssertFalse(script.windows.opening.contains(fixture.book.id), "the book stayed marked as opening")
        session.close()
    }

    /// A book of several tracks asks which, listing them by chapter name,
    /// and opens the one chosen; cancelling the question opens nothing.
    func testABookOfSeveralTracksAsksWhichAndOpensTheOneChosen() async throws {
        let fixture = try trackBook(manifest: AudioManifest(chapters: ["a.wav": "First Crossing", "b.wav": "Second Crossing"]))
        let script = LauncherScript()
        script.choose = { $0.last }

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .opened(track: "Second Crossing"))
        XCTAssertEqual(script.questions, ["First Crossing|Second Crossing"])
        let session = try XCTUnwrap(script.presented.first?.session)
        XCTAssertEqual(session.audioFile, "audio/b.wav")
        session.close()

        let cancelling = LauncherScript()
        cancelling.choose = { _ in nil }
        let cancelled = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: cancelling.windows, services: cancelling.services)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(cancelling.presented.isEmpty)
    }

    /// A book open in a reader is closed there first, with a sentence
    /// saying why, then the editor opens.
    func testABookOpenInAReaderIsClosedFirstWithASentence() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        fixture.library.openBookIDs = [fixture.book.id]
        let script = LauncherScript()
        script.closesReaders = { fixture.library.openBookIDs.remove($0) }

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .opened(track: nil))
        XCTAssertEqual(script.closedReaders, [fixture.book.id])
        XCTAssertEqual(script.announced, ["Closing the reader of Harbour Survey, since editing changes its audio."])
        script.presented.first?.session.close()
    }

    /// A reader that does not close is said, and nothing opens.
    func testAReaderThatStaysOpenIsSaidAndNothingOpens() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        fixture.library.openBookIDs = [fixture.book.id]
        let script = LauncherScript()
        script.readerCloseTimeout = 0.2

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        let sentence = "Harbour Survey is still open in a reader. Close the reader, then choose Edit Audio again."
        XCTAssertEqual(outcome, .refused(sentence))
        XCTAssertEqual(script.announced.last, sentence)
        XCTAssertTrue(script.presented.isEmpty)
    }

    /// An edit history that can't be read is started over only when the
    /// user says so; declining opens nothing.
    func testAnUnreadableHistoryIsStartedOverOnlyWhenTheUserSaysSo() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        let script = LauncherScript()
        script.historyIsUnusable = true
        script.startsOver = true

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .opened(track: nil))
        XCTAssertEqual(script.sessionsAskedFor, [false, true])
        XCTAssertEqual(script.questions, ["start over"])
        script.presented.first?.session.close()

        let declining = LauncherScript()
        declining.historyIsUnusable = true
        declining.startsOver = false
        let declined = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: declining.windows, services: declining.services)
        XCTAssertEqual(declined, .cancelled)
        XCTAssertEqual(declining.sessionsAskedFor, [false])
        XCTAssertTrue(declining.presented.isEmpty)
    }

    /// Audio that can't be opened is shown in an alert with the engine's
    /// own sentence, and nothing opens.
    func testAudioThatCantBeOpenedIsShownWithItsReason() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        try FileManager.default.removeItem(at: fixture.book.bookFileURL)
        let script = LauncherScript()

        let outcome = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        let sentence = "The audio of Harbour Survey couldn't be opened for editing. "
            + "The audio file “Harbour Survey.wav” that the edits need is missing from the book."
        XCTAssertEqual(outcome, .refused(sentence))
        XCTAssertEqual(script.failures, [sentence])
        XCTAssertTrue(script.presented.isEmpty)
        XCTAssertEqual(AudioEditorLauncher.describe(AudioEditError.missingAudio("Harbour Survey.wav")), "missingAudio")
    }

    // MARK: - The Window

    /// The model plays the edited audio through its player, loaded at the
    /// cursor, and makes no sound in a test; its status names the chapter
    /// the cursor is in; closing lets go of the player and the session.
    func testTheModelLoadsItsPreviewAndSaysWhereItIs() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 2, for: self)
        let harness = try await EditorHarness.open(fixture, for: self)

        await harness.model.loadPreview()

        XCTAssertEqual(harness.player.loadedFrames, [16_000])
        XCTAssertEqual(harness.player.loadedAt, [0])
        XCTAssertEqual(harness.model.positionText, "0:00 of 0:02")
        XCTAssertEqual(harness.model.positionValue, "0 seconds of 2 seconds")
        XCTAssertEqual(harness.model.statusSentence, "0 seconds of 2 seconds")
        try await harness.model.session.perform(.setChapter(at: 0, title: "Tide Tables"))
        XCTAssertEqual(harness.model.statusSentence, "0 seconds of 2 seconds; in chapter 1: Tide Tables")

        harness.model.windowClosed()
        XCTAssertTrue(harness.player.isClosed)
    }

    /// VoiceOver starts on the time display: the window makes exactly one
    /// focus request, and, where SwiftUI exposes its elements, the one
    /// element carrying the identifier that request looks for is the time
    /// display.
    func testVoiceOverStartsOnTheTimeDisplay() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        let harness = try await EditorHarness.open(fixture, for: self)
        defer { harness.model.windowClosed() }

        withHostedView(AudioEditorView(model: harness.model), size: NSSize(width: 760, height: 640), until: {
            !self.descendants(of: $0, as: VoiceOverFocusTriggerView.self).isEmpty
        }) { hosting in
            XCTAssertEqual(descendants(of: hosting, as: VoiceOverFocusTriggerView.self).count, 1)
            let targets = elements(identified: voiceOverFocusID, in: hosting)
            if !targets.isEmpty {
                XCTAssertEqual(targets.map { $0.accessibilityLabel() ?? "" }, [AudioEditorWording.positionLabel])
            }
        }
    }

    // MARK: - Menus

    /// The reader's Book menu offers Edit Audio…, after Delete Transcript….
    func testTheBookMenuOffersEditAudio() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let book = try XCTUnwrap(menu.items.first { $0.title == "Book" }?.submenu)
        let titles = book.items.map(\.title)
        let delete = try XCTUnwrap(titles.firstIndex(of: TranscriptionWording.deleteCommandTitle))
        let edit = try XCTUnwrap(titles.firstIndex(of: AudioEditorWording.editAudioCommand))
        XCTAssertGreaterThan(edit, delete)
    }

    /// An editor window shows neither the Library's nor a reader's menus.
    func testTheEditorWindowShowsNoContextMenus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(AudioEditorWindowController.windowIdentifier)
        window.title = AudioEditorWording.windowTitle(book: "Ferry Log", track: nil)

        XCTAssertNil(MenuVisibilityManager.detectWindowType(for: window))
    }

    // MARK: - Helpers

    /// A book of two 0.25-second tracks, "a.wav" and "b.wav", in an
    /// "audio" folder with `manifest`.
    private func trackBook(manifest: AudioManifest) throws -> AudioEditorTestBook {
        try AudioEditorTestBook.make(named: "audio", for: self) { folder in
            for name in ["a.wav", "b.wav"] {
                try AudioTestFixtures.writeIdentityRamp(
                    to: folder.appendingPathComponent(name),
                    frames: Int(AudioEditorTestBook.rate / 4),
                    sampleRate: AudioEditorTestBook.rate
                )
            }
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }
    }

    /// Every accessibility element below `root` whose identifier is
    /// `identifier`.
    private func elements(identified identifier: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityIdentifier() == identifier ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap { elements(identified: identifier, in: $0) }
    }
}

// MARK: - The Launcher's Stand-Ins

/// The editor's windows, without any: which books are open or opening, and
/// which were brought forward.
@MainActor
final class FakeEditorWindows: AudioEditorWindowing {
    var open: Set<UUID> = []
    private(set) var opening: Set<UUID> = []
    private(set) var broughtForward: [UUID] = []

    func isOpen(_ bookID: UUID) -> Bool { open.contains(bookID) }
    func window(for bookID: UUID) -> NSWindow? { nil }
    func bringForward(_ bookID: UUID) { broughtForward.append(bookID) }

    func beginOpening(_ bookID: UUID) -> Bool {
        guard !open.contains(bookID), !opening.contains(bookID) else { return false }
        opening.insert(bookID)
        return true
    }

    func endOpening(_ bookID: UUID) { opening.remove(bookID) }
}

/// What a test has the launcher meet: answers to its questions, readers
/// that close or not, an edit history that can be read or not, and logs of
/// everything it said and opened.
@MainActor
final class LauncherScript {
    /// The editor's windows.
    let windows = FakeEditorWindows()
    /// Picks the track to edit; the first by default.
    var choose: ([AudioEditorTrack]) -> AudioEditorTrack? = { $0.first }
    /// What closing a reader does; nothing by default.
    var closesReaders: (UUID) -> Void = { _ in }
    /// Whether the first session opened finds the history unusable.
    var historyIsUnusable = false
    /// The answer to "start over?".
    var startsOver = false
    /// How long a reader is given to close.
    var readerCloseTimeout: TimeInterval = 3

    /// The questions asked: a track question as its tracks' titles joined by
    /// "|", or "start over".
    private(set) var questions: [String] = []
    /// The readers asked to close.
    private(set) var closedReaders: [UUID] = []
    /// `startingOver` for each session asked for.
    private(set) var sessionsAskedFor: [Bool] = []
    /// What was announced.
    private(set) var announced: [String] = []
    /// What was shown in an alert.
    private(set) var failures: [String] = []
    /// The editors presented: the book, the track, and the session.
    private(set) var presented: [(book: Book, track: AudioEditorTrack?, session: AudioEditSession)] = []

    /// The services to hand the launcher.
    var services: AudioEditorLauncher.Services {
        AudioEditorLauncher.Services(
            readTracks: { try AudioEditorTracks.of($0) },
            chooseTrack: { [unowned self] _, tracks, _ in
                questions.append(tracks.map(\.title).joined(separator: "|"))
                return choose(tracks)
            },
            confirmStartOver: { [unowned self] _, _ in
                questions.append("start over")
                return startsOver
            },
            closeReader: { [unowned self] bookID in
                closedReaders.append(bookID)
                closesReaders(bookID)
            },
            openSession: { [unowned self] bookID, audioFile, library, startingOver in
                sessionsAskedFor.append(startingOver)
                if historyIsUnusable, !startingOver {
                    throw AudioEditError.historyUnusable("a test said so")
                }
                return try await AudioEditSession.open(bookID: bookID, audioFile: audioFile, in: library, startingOver: startingOver)
            },
            present: { [unowned self] book, track, session in
                presented.append((book, track, session))
            },
            announce: { [unowned self] sentence, _ in announced.append(sentence) },
            showFailure: { [unowned self] message, _ in failures.append(message) },
            readerCloseTimeout: readerCloseTimeout
        )
    }
}

// MARK: - An Open Editor

/// An editor model over a real edit session of a test book, playing
/// through a player that makes no sound, with its announcements caught.
@MainActor
struct EditorHarness {
    let model: AudioEditorModel
    let player: FakeAudioEditorPlayer
    let announcements: EditorAnnouncements
    let store: UserDefaults
    let fixture: AudioEditorTestBook

    /// Opens `fixture`'s book, or its `track`, in a model of its own, with
    /// `test`'s own sandboxed preferences store.
    static func open(_ fixture: AudioEditorTestBook, for test: XCTestCase, track: AudioEditorTrack? = nil) async throws -> EditorHarness {
        let session = try await AudioEditSession.open(bookID: fixture.book.id, audioFile: track?.path, in: fixture.library)
        let player = FakeAudioEditorPlayer()
        let announcements = EditorAnnouncements()
        let store = test.makeSandboxedPreferences("audio-editor")
        let model = AudioEditorModel(
            bookID: fixture.book.id,
            bookTitle: fixture.book.title,
            trackTitle: track?.title,
            session: session,
            player: player,
            store: store,
            announce: announcements.announce
        )
        return EditorHarness(model: model, player: player, announcements: announcements, store: store, fixture: fixture)
    }
}
