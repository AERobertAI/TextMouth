import XCTest
@testable import TextMouth

/// Moving the data directory, as Move Library Here and Reset to Default do,
/// runs off the main actor with its progress shown and a Cancel (FR02). It
/// is refused while a book is open, naming the books, and while books are
/// only in the cloud, which the copy would have to download. Cancel deletes
/// the partial copy and leaves the library where it was, with no setting
/// changed.
///
/// The copy is observed, and cancelled at a chosen item, through an observer
/// bound around the move (`DataDirectoryMigrator.$copyObserver`), which hears
/// every report after the move's own, on the copying thread; nothing here
/// waits on a clock.
@MainActor
final class DataDirectoryMoveTests: XCTestCase {

    // MARK: - Progress

    /// While the move copies, the library model shows its progress, which
    /// every Library window's sheet and Storage settings follow; VoiceOver
    /// hears where the library is going when the copy starts, and the
    /// progress is gone once the move is done.
    func testAMoveShowsItsProgressWhileItCopies() async throws {
        let world = try makeIntegrationWorld("Move Progress")
        let model = world.library
        _ = try world.importBook(from: try makeTextSource(named: "Ferry Timetable.txt"))
        _ = try world.importBook(from: try makeTextSource(named: "Breakwater Survey.txt"))
        let destination = try makeDataDirectoryMoveDestination("ProgressMove")
        let seen = PhasesSeen()
        let observer = DataDirectoryCopyObserver(
            report: { _ in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { seen.phases.append(model.dataDirectoryMove?.phase) }
                }
            },
            isCancelled: { false }
        )

        let (outcome, announcements) = await announcementsMade {
            await DataDirectoryMigrator.$copyObserver.withValue(observer) {
                await model.moveDataDirectoryReturningOutcome(to: destination)
            }
        }

        XCTAssertEqual(outcome, .success("Done. Data is now at \(destination.path)."))
        XCTAssertFalse(seen.phases.isEmpty, "the copy reported nothing")
        XCTAssertTrue(seen.phases.allSatisfy { $0 != nil }, "the progress was not shown while the move copied: \(seen.phases)")
        XCTAssertNil(model.dataDirectoryMove, "the progress stayed after the move")
        XCTAssertNil(DataDirectoryMoveProgress.running)
        // What the move waits for, should other storage work be under way,
        // is said first; then the copy's start, then only its quarters.
        let copying = announcements.drop { $0.hasPrefix("Waiting for") }
        XCTAssertEqual(copying.first, "Moving the library to \(destination.path).", "\(announcements)")
        let quarters = Set([25, 50, 75].map(DataDirectoryMoveWording.quarterAnnouncement(percent:)))
        XCTAssertTrue(copying.dropFirst().allSatisfy(quarters.contains), "\(announcements)")
    }

    // MARK: - Cancel

    /// Cancel while the move waits for other storage work stops it before
    /// anything is copied: the outcome says so, as no failure, and the data
    /// directory, its setting, and the library stay as they were.
    func testCancelWhileTheMoveWaitsCopiesNothing() async throws {
        let world = try makeIntegrationWorld("Move Cancel Waiting")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Pilot Ladder.txt"))
        let destination = try makeDataDirectoryMoveDestination("CancelWhileWaiting")
        let before = SettingsBefore()
        let work = await holdStorageWork(.importing)

        let (outcome, announcements) = await announcementsMade {
            await model.moveDataDirectoryReturningOutcome(to: destination) { waitingFor in
                guard waitingFor == .importing else { return }
                model.dataDirectoryMove?.cancel()
                work.release()
            }
        }

        XCTAssertEqual(outcome, .success("Move cancelled. The library is still at \(before.root.path)."))
        XCTAssertTrue(announcements.contains(DataDirectoryMoveWording.cancellingAnnouncement), "\(announcements)")
        XCTAssertFalse(announcements.contains { $0.hasPrefix("Moving the library to") }, "a copy started: \(announcements)")
        assertNothingMoved(model: model, book: book, destination: destination, before: before)
    }

    /// Cancel while the library is copied stops the copy at its next item:
    /// the partial copy is deleted, nothing is left at the new location, and
    /// the data directory, its setting, config.json, and the library stay
    /// as they were.
    func testCancelDuringTheCopyDeletesThePartialCopyAndKeepsEverything() async throws {
        let world = try makeIntegrationWorld("Move Cancel Copying")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Slack Water.txt"))
        _ = try world.importBook(from: try makeTextSource(named: "Leading Lights.txt"))
        let destination = try makeDataDirectoryMoveDestination("CancelWhileCopying")
        let before = SettingsBefore()
        let observer = DataDirectoryCopyObserver(
            report: { progress in
                // Cancel, as the sheet's button does, once one item is in.
                guard progress.copiedItems == 1 else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { model.dataDirectoryMove?.cancel() }
                }
            },
            isCancelled: { false }
        )

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(observer) {
            await model.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertEqual(outcome, .success("Move cancelled. The library is still at \(before.root.path)."))
        assertNothingMoved(model: model, book: book, destination: destination, before: before)
    }

    // MARK: - Refusals

    /// A move is refused while a book is open, naming the open books, before
    /// anything is held, shown, or copied.
    func testAMoveIsRefusedWhileBooksAreOpenNamingThem() async throws {
        let world = try makeIntegrationWorld("Move Open Books")
        let model = world.library
        let first = try world.importBook(from: try makeTextSource(named: "Lantern Rota.txt"))
        let second = try world.importBook(from: try makeTextSource(named: "Anchor Watch.txt"))
        let destination = try makeDataDirectoryMoveDestination("OpenBooksMove")
        let before = SettingsBefore()
        let shown = PhasesSeen()
        let subscription = model.$dataDirectoryMove.sink { move in
            if move != nil { shown.phases.append(move?.phase) }
        }
        defer { subscription.cancel() }

        model.openBookIDs = [first.id]
        let one = await model.moveDataDirectoryReturningOutcome(to: destination)
        model.openBookIDs = [first.id, second.id]
        let two = await model.moveDataDirectoryReturningOutcome(to: destination)

        XCTAssertEqual(
            one,
            .failure("Failed to move directory: The library can't move while a book is open. Close “\(first.title)” first.")
        )
        let titles = [first.title, second.title].sorted().map { "“\($0)”" }
        XCTAssertEqual(
            two,
            .failure("Failed to move directory: The library can't move while books are open. Close these first: \(titles[0]) and \(titles[1]).")
        )
        XCTAssertTrue(shown.phases.isEmpty, "a refused move showed its progress")
        assertNothingMoved(model: model, book: first, destination: destination, before: before)
    }

    /// A move is refused while books have files only in the cloud, which
    /// the copy would have to download, counting them; nothing is copied.
    func testAMoveIsRefusedWhileBooksAreOnlyInTheCloud() async throws {
        let world = try makeIntegrationWorld("Move Cloud Books")
        let model = world.library
        let first = try world.importBook(from: try makeTextSource(named: "Tidal Atlas.txt"))
        let second = try world.importBook(from: try makeTextSource(named: "Mooring Plan.txt"))
        let destination = try makeDataDirectoryMoveDestination("CloudBooksMove")
        let before = SettingsBefore()

        let one = await model.moveDataDirectoryReturningOutcome(to: destination, access: Self.inCloud([first]))
        let two = await model.moveDataDirectoryReturningOutcome(to: destination, access: Self.inCloud([first, second]))

        XCTAssertEqual(one, .failure(
            "Failed to move directory: 1 book isn't downloaded. Download it first: select it in the library, then choose Download Now."
        ))
        XCTAssertEqual(two, .failure(
            "Failed to move directory: 2 books aren't downloaded. Download them first: select them in the library, then choose Download Now."
        ))
        assertNothingMoved(model: model, book: first, destination: destination, before: before)
    }

    /// Reset to Default is refused the same way while books are only in the
    /// cloud, the commonest way out of a cloud folder.
    func testResetToDefaultIsRefusedWhileBooksAreOnlyInTheCloud() async throws {
        let world = try makeIntegrationWorld("Reset Cloud Books")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Harbour Dues.txt"))
        let elsewhere = try makeDataDirectoryMoveDestination("ResetFromCloud")
        let moved = await model.moveDataDirectoryReturningOutcome(to: elsewhere)
        XCTAssertTrue(moved.succeeded, moved.failureMessage ?? "")
        let inElsewhere = try XCTUnwrap(model.bookByID(book.id))

        let outcome = await model.rebuildToDefaultReturningOutcome(access: Self.inCloud([inElsewhere]))

        XCTAssertEqual(outcome, .failure(
            "Failed to rebuild to default: 1 book isn't downloaded. Download it first: select it in the library, then choose Download Now."
        ))
        XCTAssertEqual(TextMouthPaths.root.path, elsewhere.path, "the library left the folder it was in")
        XCTAssertNil(model.dataDirectoryMove)
    }

    // MARK: - The Library During the Copy

    /// Nothing should change the library while it is copied, but a change
    /// made anyway is kept: the book keeps it, at its place in the new data
    /// directory, where its file is.
    func testAChangeMadeWhileTheLibraryIsCopiedIsKept() async throws {
        let world = try makeIntegrationWorld("Move Change During Copy")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Buoy Inventory.txt"))
        let destination = try makeDataDirectoryMoveDestination("ChangeDuringCopy")
        let observer = DataDirectoryCopyObserver(
            report: { progress in
                guard progress.copiedItems == 1 else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        model.updateBook(id: book.id) { $0.title = "Buoy Inventory, Revised" }
                    }
                }
            },
            isCancelled: { false }
        )

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(observer) {
            await model.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        let kept = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(kept.title, "Buoy Inventory, Revised")
        XCTAssertTrue(kept.filePath.hasPrefix(destination.path + "/"), kept.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.filePath))
    }

    // MARK: - Quitting

    /// Asked to quit during a move, TextMouth presses Cancel and quits once
    /// the move has ended; with no move under way it quits as before.
    func testQuittingDuringAMoveStopsTheMoveFirst() {
        XCTAssertFalse(DataDirectoryMoveProgress.stopForQuit(then: { XCTFail("there was no move to stop") }))
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.begin()
        move.beginCopying()
        let quits = QuitRequests()

        var stopping = false
        let recorder = recordingAnnouncements {
            stopping = DataDirectoryMoveProgress.stopForQuit(then: { quits.count += 1 })
        }

        XCTAssertTrue(stopping)
        XCTAssertTrue(move.isCancelled)
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            [DataDirectoryMoveWording.quitAnnouncement, DataDirectoryMoveWording.cancellingAnnouncement]
        )
        XCTAssertEqual(quits.count, 0, "TextMouth quit before the move ended")
        move.end()
        XCTAssertTrue(waitUntil { quits.count == 1 }, "TextMouth did not quit once the move ended")
        XCTAssertNil(DataDirectoryMoveProgress.running)
    }

    /// Asked to quit while the library moves, the app delegate cancels this
    /// request and the move, and asks to quit again once the move has
    /// ended, so no partial copy is left behind.
    func testTheAppDelegateStopsAMoveBeforeQuitting() {
        let delegate = AppDelegate()
        let quits = QuitRequests()
        delegate.requestTermination = { quits.count += 1 }
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.begin()
        recordingAnnouncements { move.beginCopying() }

        var reply: NSApplication.TerminateReply?
        recordingAnnouncements {
            reply = delegate.applicationShouldTerminate(NSApplication.shared)
        }

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(move.isCancelled)
        XCTAssertEqual(quits.count, 0, "TextMouth asked to quit again before the move ended")
        move.end()
        XCTAssertTrue(waitUntil { quits.count == 1 }, "TextMouth did not ask to quit again once the move ended")
    }

    /// A move still waiting for other work, or getting ready, has written
    /// nothing, so it does not hold up quitting, and is not cancelled.
    func testAMoveThatHasNotStartedCopyingDoesNotHoldUpQuitting() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.begin()
        defer { move.end() }

        recordingAnnouncements {
            XCTAssertFalse(DataDirectoryMoveProgress.stopForQuit(then: { XCTFail("quitting waited for a move") }))
            move.wait(for: .importing)
            XCTAssertFalse(DataDirectoryMoveProgress.stopForQuit(then: { XCTFail("quitting waited for a move") }))
        }

        XCTAssertFalse(move.isCancelled)
    }

    /// A move whose copy is complete cannot be cancelled; quitting waits
    /// for it to finish.
    func testQuittingWhileAMoveFinishesLetsItFinish() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.begin()
        move.beginCopying()
        move.receive(DataDirectoryCopyProgress(copiedBytes: 10, totalBytes: 10, copiedItems: 2, totalItems: 2))
        let quits = QuitRequests()

        recordingAnnouncements {
            XCTAssertTrue(DataDirectoryMoveProgress.stopForQuit(then: { quits.count += 1 }))
        }

        XCTAssertFalse(move.isCancelled, "a finishing move was cancelled")
        move.end()
        XCTAssertTrue(waitUntil { quits.count == 1 })
    }

    // MARK: - Fixtures

    /// The data-directory settings as a test found them.
    @MainActor
    private struct SettingsBefore {
        let root = TextMouthPaths.root
        let customPath = DataDirectoryPreferences.customPath.read(from: TextMouthRuntime.current.preferences)
        let configPath = ConfigService.shared.config.dataDirectoryPath
    }

    /// Fails unless the move to `destination` left everything as `before`
    /// found it: the data directory, its setting, config.json's copy, `book`
    /// in the library at its old path, nothing at the new location or
    /// staged beside it, and no progress shown.
    private func assertNothingMoved(
        model: LibraryViewModel,
        book: Book,
        destination: URL,
        before: SettingsBefore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(TextMouthPaths.root, before.root, file: file, line: line)
        XCTAssertEqual(
            DataDirectoryPreferences.customPath.read(from: TextMouthRuntime.current.preferences),
            before.customPath,
            file: file,
            line: line
        )
        XCTAssertEqual(ConfigService.shared.config.dataDirectoryPath, before.configPath, file: file, line: line)
        XCTAssertEqual(model.bookByID(book.id)?.filePath, book.filePath, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "something was left at the new location", file: file, line: line)
        let staged = ((try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
        XCTAssertEqual(staged, [], "a partial copy was left", file: file, line: line)
        XCTAssertNil(model.dataDirectoryMove, file: file, line: line)
    }

    /// An access to books' files that says the files of `books` are only in
    /// the cloud.
    private static func inCloud(_ books: [Book]) -> MaintenanceFileAccess {
        let packages = Set(books.map { BookPackage($0).url.standardizedFileURL.path })
        return MaintenanceFileAccess(isDataless: { packages.contains($0.standardizedFileURL.path) })
    }

    /// A plain-text book file, `name`, in a scratch folder of the test's
    /// own. Its text begins with its name, so no two are copies of one book.
    private func makeTextSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("MoveSource").appendingPathComponent(name)
        try Data("\(name)\n\nThe ferry leaves the slip at first light.\n\nGulls follow it past the breakwater.\n".utf8)
            .write(to: file)
        return file
    }

    /// A piece of `work` under way on a background thread, as the storage
    /// boundary records it, until it is released or the test ends.
    private func holdStorageWork(_ work: StorageWork) async -> HeldStorageWork {
        let held = HeldStorageWork()
        let started = expectation(description: "the \(work) work started")
        DispatchQueue.global().async {
            StorageBoundary.shared.perform(work) { _ in
                started.fulfill()
                held.waitForRelease()
            }
        }
        await fulfillment(of: [started], timeout: 10)
        addTeardownBlock { held.release() }
        return held
    }

    /// Runs `body`, recording what VoiceOver is asked to announce instead of
    /// posting it, and returns what `body` returns with the messages.
    private func announcementsMade<Value>(_ body: () async -> Value) async -> (Value, [String]) {
        let messages = AnnouncedMessages()
        let previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in messages.all.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previous }
        let value = await body()
        return (value, messages.all)
    }
}

/// The phases of the move the copy saw, on the main actor.
@MainActor
private final class PhasesSeen {
    var phases: [DataDirectoryMoveProgress.Phase?] = []
}

/// How many times a test was asked to quit.
@MainActor
private final class QuitRequests {
    var count = 0
}

/// The messages announced during a test.
@MainActor
private final class AnnouncedMessages {
    var all: [String] = []
}

/// Storage work a test holds under way until it lets it go.
private final class HeldStorageWork: @unchecked Sendable {
    /// Opens once the work may finish.
    private let gate = DispatchSemaphore(value: 0)

    /// Blocks the work's thread until `release()`.
    func waitForRelease() {
        gate.wait()
    }

    /// Lets the work finish; a second release does no harm.
    func release() {
        gate.signal()
    }
}
