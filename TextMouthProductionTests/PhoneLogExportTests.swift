import Foundation
import os
import XCTest
@testable import TextMouth

/// Share Logs…'s file: the newest text of each log, in one plain text file,
/// capped, gathered off the main thread. Every test works in its own sandbox
/// through `PhoneLogExport.Environment`, so no real log is ever read: the
/// app's environment isn't gathered here.
final class PhoneLogExportTests: XCTestCase {

    // MARK: - The Cap

    /// The file's limits, which the spec and the brief give.
    func testTheFileIsNamedAndCappedAsTheBriefSays() {
        XCTAssertEqual(PhoneLogExport.byteLimit, 2 * 1024 * 1024)
        XCTAssertEqual(PhoneLogExport.fileName, "TextMouth Logs.txt")
    }

    /// A log larger than the cap gives its newest lines, and its oldest are
    /// left out, whole lines only.
    func testTheNewestLinesAreKeptAndTheOldestLeftOut() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write(numberedLines(1...500), named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("line 500 of the log\n"), "the newest line is there")
        XCTAssertFalse(text.contains("line 1 of the log"), "the oldest line is left out")
        // Every line of the log's section is whole.
        let lines = try XCTUnwrap(text.components(separatedBy: "=== Logs/textmouth_debug.log ===\n").last)
            .split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("line ") && line.hasSuffix(" of the log"), "a line in part: \(line)")
        }
    }

    /// The text kept comes to about the cap: under it, by no more than one
    /// line lost to a cut, and the headings add little.
    func testTheFileComesToAboutTheCap() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write(numberedLines(1...500), named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        let body = try XCTUnwrap(text.components(separatedBy: "=== Logs/textmouth_debug.log ===\n").last)
        XCTAssertLessThanOrEqual(body.utf8.count, 1000)
        XCTAssertGreaterThan(body.utf8.count, 1000 - 30)
    }

    /// At the app's own cap, a log larger than the whole file gives about
    /// 2 MB, and nothing more.
    func testTheAppsCapHoldsAtFullSize() async throws {
        let world = try makeWorld(byteLimit: PhoneLogExport.byteLimit)
        try write(numberedLines(1...200_000), named: "textmouth_debug.log", in: world.logs)

        let url = try await PhoneLogExport.gather(in: world.environment)

        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThanOrEqual(size, PhoneLogExport.byteLimit + 1024)
        XCTAssertGreaterThan(size, PhoneLogExport.byteLimit - 1024)
    }

    /// A log that fits is there whole.
    func testALogThatFitsIsThereWhole() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let log = numberedLines(1...3)
        try write(log, named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("=== Logs/textmouth_debug.log ===\n" + log))
    }

    // MARK: - The Shares

    /// What a small log doesn't need goes to the larger ones, equally.
    func testWhatASmallLogDoesntNeedGoesToTheLargeOnes() {
        XCTAssertEqual(PhoneLogExport.shares(of: 90, among: [10, 100, 100]), [10, 40, 40])
        XCTAssertEqual(PhoneLogExport.shares(of: 90, among: [100, 10, 100]), [40, 10, 40])
    }

    /// When everything fits, each log gets all it holds.
    func testWhenEverythingFitsEachLogGetsItAll() {
        XCTAssertEqual(PhoneLogExport.shares(of: 100, among: [10, 20, 30]), [10, 20, 30])
    }

    /// Logs with nothing take nothing, and an empty list is an empty answer.
    func testALogWithNothingTakesNothing() {
        XCTAssertEqual(PhoneLogExport.shares(of: 100, among: [0, 500, 0]), [0, 100, 0])
        XCTAssertEqual(PhoneLogExport.shares(of: 100, among: []), [])
    }

    /// The shares never come to more than the limit, however the sizes fall.
    func testTheSharesNeverPassTheLimit() {
        let sizes = [[7, 7, 7], [1, 1_000, 1_000_000], [0, 0, 0], [33, 34, 34], [1_000, 1_000, 1_000, 1_000, 1_000, 1_000]]
        for size in sizes {
            let shares = PhoneLogExport.shares(of: 100, among: size)
            XCTAssertLessThanOrEqual(shares.reduce(0, +), 100, "\(size)")
            XCTAssertTrue(zip(shares, size).allSatisfy { $0 <= $1 }, "\(size)")
        }
    }

    /// A busy debug log doesn't crowd out the sleep timer's.
    func testABusyLogDoesntCrowdOutASmallOne() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write(numberedLines(1...500), named: "textmouth_debug.log", in: world.logs)
        try write("the timer's only line\n", named: "textmouth_timer.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("=== Logs/textmouth_timer.log ===\nthe timer's only line\n"))
        XCTAssertTrue(text.contains("line 500 of the log\n"))
    }

    /// Two busy logs each get about half.
    func testTwoBusyLogsShareTheCap() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write(numberedLines(1...500), named: "textmouth_debug.log", in: world.logs)
        try write(numberedLines(1...500), named: "textmouth_transition.log", in: world.logs)

        let text = try await gatheredText(world)

        let parts = text.components(separatedBy: "=== Logs/textmouth_transition.log ===\n")
        XCTAssertEqual(parts.count, 2)
        let debug = try XCTUnwrap(parts[0].components(separatedBy: "=== Logs/textmouth_debug.log ===\n").last)
        XCTAssertGreaterThan(debug.utf8.count, 400)
        XCTAssertGreaterThan(parts[1].utf8.count, 400)
        XCTAssertLessThanOrEqual(debug.utf8.count + parts[1].utf8.count, 1100)
    }

    // MARK: - Generations and Folders

    /// A log's older generation reads first, each under its own heading, and
    /// the logs follow `DiagnosticLog.File`'s order.
    func testALogsGenerationsReadInTimeOrder() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("older\n", named: "textmouth_debug.log.previous", in: world.logs)
        try write("newer\n", named: "textmouth_debug.log", in: world.logs)
        try write("timer\n", named: "textmouth_timer.log", in: world.logs)
        try write("speech\n", named: "textmouth_transition.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertEqual(
            text,
            """
            HEADING

            === Logs/textmouth_debug.log.previous ===
            older

            === Logs/textmouth_debug.log ===
            newer

            === Logs/textmouth_timer.log ===
            timer

            === Logs/textmouth_transition.log ===
            speech

            """
        )
    }

    /// The newer generation is filled first, and the older one has only what
    /// it leaves.
    func testTheOlderGenerationHasOnlyWhatTheNewerLeaves() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let newer = numberedLines(501...510)
        try write(numberedLines(1...500), named: "textmouth_debug.log.previous", in: world.logs)
        try write(newer, named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("=== Logs/textmouth_debug.log ===\n" + newer), "the newer one is whole")
        XCTAssertTrue(text.contains("line 500 of the log\n"), "the older one's newest line is there")
        XCTAssertFalse(text.contains("line 1 of the log"), "the older one's oldest line is left out")
    }

    /// A newer generation that fills the share leaves the older one out.
    func testANewerGenerationThatFillsTheShareLeavesTheOlderOut() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("older\n", named: "textmouth_debug.log.previous", in: world.logs)
        try write(numberedLines(1...500), named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertFalse(text.contains("textmouth_debug.log.previous"))
    }

    /// Each folder's logs are gathered, the one in use first, named by their
    /// folder, so two logs of one name can be told apart.
    func testEveryFolderIsGathered() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let other = try makeSandboxDirectory("PhoneLogExport").appendingPathComponent("Fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try write("in use\n", named: "textmouth_debug.log", in: world.logs)
        try write("fell back\n", named: "textmouth_debug.log", in: other)
        var environment = world.environment
        environment.logFolders = { [world] in [world.logs, other] }

        let url = try await PhoneLogExport.gather(in: environment)
        let text = try String(contentsOf: url, encoding: .utf8)

        let inUse = try XCTUnwrap(text.range(of: "=== Logs/textmouth_debug.log ===\nin use\n"))
        let fellBack = try XCTUnwrap(text.range(of: "=== Fallback/textmouth_debug.log ===\nfell back\n"))
        XCTAssertLessThan(inUse.lowerBound, fellBack.lowerBound)
    }

    /// The one folder named twice is listed once, by the path it stands for.
    func testAFolderNamedTwiceIsListedOnce() {
        let logs = URL(fileURLWithPath: "/sandbox/Logs", isDirectory: true)
        let same = URL(fileURLWithPath: "/sandbox/other/../Logs", isDirectory: true)
        let other = URL(fileURLWithPath: "/sandbox/Fallback", isDirectory: true)

        XCTAssertEqual(PhoneLogExport.uniqueFolders([logs, other, same, logs]), [logs, other])
    }

    // MARK: - What Goes Wrong

    /// With no logs, as with a folder not there, the file holds its heading.
    func testWithNoLogsTheFileHoldsItsHeading() async throws {
        let world = try makeWorld(byteLimit: 1000)
        var environment = world.environment
        environment.logFolders = { [world] in [world.logs.appendingPathComponent("Missing", isDirectory: true)] }

        let url = try await PhoneLogExport.gather(in: environment)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "HEADING\n")
    }

    /// An empty log gets no heading of its own.
    func testAnEmptyLogIsLeftOut() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("", named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertEqual(text, "HEADING\n")
    }

    /// A log only in the cloud is left out, and its share goes to the others.
    func testALogOnlyInTheCloudIsLeftOut() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("in the cloud\n", named: "textmouth_debug.log", in: world.logs)
        try write(numberedLines(1...500), named: "textmouth_timer.log", in: world.logs)
        var environment = world.environment
        environment.isOnlyInCloud = { $0.lastPathComponent == "textmouth_debug.log" }

        let url = try await PhoneLogExport.gather(in: environment)
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(text.contains("in the cloud"))
        let timer = try XCTUnwrap(text.components(separatedBy: "=== Logs/textmouth_timer.log ===\n").last)
        XCTAssertGreaterThan(timer.utf8.count, 900, "the timer's log has the whole cap")
    }

    /// A folder standing where a log should be is passed over.
    func testAFolderNamedLikeALogIsPassedOver() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try FileManager.default.createDirectory(
            at: world.logs.appendingPathComponent("textmouth_debug.log", isDirectory: true),
            withIntermediateDirectories: true
        )

        let text = try await gatheredText(world)

        XCTAssertEqual(text, "HEADING\n")
    }

    /// Bytes that aren't UTF-8 don't stop the file being plain text.
    func testBytesThatArentUTF8StillMakeAPlainTextFile() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let log = Data("before ".utf8) + Data([0xFF, 0xFE]) + Data(" after\n".utf8)
        try log.write(to: world.logs.appendingPathComponent("textmouth_debug.log"))

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("before \u{FFFD}\u{FFFD} after\n"))
    }

    /// A cut can't fall inside a character, since it starts on a whole line.
    func testACutThroughAWideCharacterLeavesPlainText() async throws {
        let world = try makeWorld(byteLimit: 100)
        let wideLines = (1...100).map { "\($0) “Emma”\n" }.joined()
        try write(wideLines, named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertFalse(text.contains("\u{FFFD}"))
        XCTAssertTrue(text.contains("100 “Emma”\n"))
    }

    /// A last line with no end doesn't run into the next heading.
    func testALastLineWithNoEndDoesntRunIntoTheNext() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("no end", named: "textmouth_debug.log", in: world.logs)
        try write("timer\n", named: "textmouth_timer.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("no end\n\n=== Logs/textmouth_timer.log ===\n"))
    }

    /// One line longer than the share keeps its newest end rather than
    /// vanishing.
    func testALineLongerThanTheShareKeepsItsEnd() async throws {
        let world = try makeWorld(byteLimit: 100)
        try write(String(repeating: "a", count: 500) + "the end", named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertTrue(text.contains("the end\n"))
    }

    /// A file that can't be written throws, and the caller says so.
    func testAFileThatCantBeWrittenThrows() async throws {
        let world = try makeWorld(byteLimit: 1000)
        // A file where the scratch folder should go: no folder can be made.
        let blocker = world.scratch.appendingPathComponent("blocker")
        try write("in the way", named: "blocker", in: world.scratch)
        var environment = world.environment
        environment.scratchFolder = { blocker.appendingPathComponent("inside", isDirectory: true) }

        do {
            _ = try await PhoneLogExport.gather(in: environment)
            XCTFail("The gathering should have thrown")
        } catch {
            // Thrown as it should be.
        }
    }

    // MARK: - The File

    /// Gathering again replaces the file: there is one, and no copies.
    func testGatheringAgainReplacesTheFile() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("first\n", named: "textmouth_debug.log", in: world.logs)
        let first = try await PhoneLogExport.gather(in: world.environment)
        try write("second\n", named: "textmouth_debug.log", in: world.logs)

        let second = try await PhoneLogExport.gather(in: world.environment)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "TextMouth Logs.txt")
        let text = try String(contentsOf: second, encoding: .utf8)
        XCTAssertTrue(text.contains("second\n"))
        XCTAssertFalse(text.contains("first"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.scratch.path), ["TextMouth Logs.txt"])
    }

    /// The scratch folder is made when it's missing.
    func testTheScratchFolderIsMadeWhenMissing() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let deeper = world.scratch.appendingPathComponent("not/yet", isDirectory: true)
        var environment = world.environment
        environment.scratchFolder = { deeper }

        let url = try await PhoneLogExport.gather(in: environment)

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, deeper.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Nothing in the file says where the app's folders are: logs are named
    /// by their place, never by an absolute path.
    func testTheFileNamesNoAbsolutePath() async throws {
        let world = try makeWorld(byteLimit: 1000)
        try write("a line\n", named: "textmouth_debug.log", in: world.logs)

        let text = try await gatheredText(world)

        XCTAssertFalse(text.contains(world.logs.path))
    }

    /// The gathering writes out the lines queued so far first, off the main
    /// thread, so the file holds them.
    func testTheQueuedLinesAreWrittenFirstOffTheMainThread() async throws {
        let world = try makeWorld(byteLimit: 1000)
        let logs = world.logs
        let flushedOnTheMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        var environment = world.environment
        environment.flush = {
            flushedOnTheMainThread.withLock { $0 = Thread.isMainThread }
            try? Data("a line just queued\n".utf8).write(to: logs.appendingPathComponent("textmouth_debug.log"))
        }

        let url = try await PhoneLogExport.gather(in: environment)

        XCTAssertEqual(flushedOnTheMainThread.withLock { $0 }, false)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("a line just queued\n"))
    }

    /// The app's file goes in its temporary directory. Only the folder's name
    /// is asked for here, which reads no log.
    func testTheAppsFileGoesInTheTemporaryDirectory() {
        let folder = PhoneLogExport.Environment.app.scratchFolder()
        XCTAssertEqual(
            folder.deletingLastPathComponent().standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        )
    }

    // MARK: - The Share Sheet

    /// The share sheet is done when closed, or when its activity completes,
    /// not when a person backs out of an activity and it stays open.
    func testTheShareSheetIsDoneWhenClosedOrCompleted() {
        XCTAssertTrue(PhoneLogExport.shareSheetIsFinished(choseActivity: false, completed: false))
        XCTAssertTrue(PhoneLogExport.shareSheetIsFinished(choseActivity: true, completed: true))
        XCTAssertFalse(PhoneLogExport.shareSheetIsFinished(choseActivity: true, completed: false))
    }

    // MARK: - Support

    /// A sandbox for one test: a Logs folder, a scratch folder, and an
    /// environment over them that touches nothing else.
    private struct World: Sendable {
        let logs: URL
        let scratch: URL
        let environment: PhoneLogExport.Environment
    }

    /// A new, empty sandbox, whose file holds about `byteLimit` bytes of text.
    private func makeWorld(byteLimit: Int) throws -> World {
        let root = try makeSandboxDirectory("PhoneLogExport")
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return World(
            logs: logs,
            scratch: scratch,
            environment: PhoneLogExport.Environment(
                flush: {},
                logFolders: { () -> [URL] in [logs] },
                heading: { "HEADING" },
                scratchFolder: { scratch },
                isOnlyInCloud: { _ in false },
                byteLimit: byteLimit
            )
        )
    }

    /// `text` as the file called `name` in `folder`.
    private func write(_ text: String, named name: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name, isDirectory: false))
    }

    /// A log of the numbered lines in `range`, each ended.
    private func numberedLines(_ range: ClosedRange<Int>) -> String {
        range.map { "line \($0) of the log\n" }.joined()
    }

    /// The file a gathering in `world` writes, as text.
    private func gatheredText(_ world: World) async throws -> String {
        let url = try await PhoneLogExport.gather(in: world.environment)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
