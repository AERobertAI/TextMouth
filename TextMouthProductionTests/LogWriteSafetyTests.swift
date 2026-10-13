import XCTest
@testable import TextMouth

/// Diagnostic logging must never crash the app, however the disk behaves, and
/// must never grow without bound (TODO Q07). Every test writes only inside a
/// disposable temporary directory, through a log writer of its own, or into
/// the isolated test data root.
final class LogWriteSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthLogWriteSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Each test's writers wait for their own lines; the app's writer may
        // still hold lines for the shared logs the last test wrote.
        TextMouthPaths.flushLogs()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The first line creates the file; later lines append in order, each
    /// timestamped and newline terminated.
    func testAppendCreatesTheFileThenAppendsLinesInOrder() throws {
        let writer = makeWriter(writingInto: directory)
        let log = directory.appendingPathComponent(DiagnosticLog.File.debug.rawValue)

        writer.append("first", to: .debug)
        writer.append("second", to: .debug)
        writer.flush()

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "two lines plus the trailing newline")
        XCTAssertTrue(lines[0].hasSuffix(": first"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix(": second"), String(lines[1]))
        XCTAssertEqual(lines[2], "")
    }

    /// A log that cannot be written (its folder cannot be made, or the file
    /// is read-only) is silently skipped, and the writer goes on writing
    /// once it can. The legacy FileHandle calls raised uncatchable
    /// exceptions here and crashed the app on a full disk.
    func testUnwritableDestinationsAreDroppedWithoutCrashing() throws {
        // A file where the logs' folder should be made.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("a file".utf8).write(to: blocker)
        let blocked = blocker.appendingPathComponent("Logs", isDirectory: true)
        let blockedWriter = makeWriter(writingInto: blocked)
        let readOnly = directory.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        try "locked\n".write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnly.path)
        }
        let writer = makeWriter(writingInto: directory)

        blockedWriter.append("dropped", to: .debug)
        writer.append("dropped", to: .debug)
        // A later write to a healthy file proves the queue survived the failures.
        writer.append("still logging", to: .sleepTimer)
        blockedWriter.flush()
        writer.flush()

        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "a file")
        XCTAssertEqual(try String(contentsOf: readOnly, encoding: .utf8), "locked\n")
        let healthy = directory.appendingPathComponent(DiagnosticLog.File.sleepTimer.rawValue)
        XCTAssertTrue(try String(contentsOf: healthy, encoding: .utf8).hasSuffix(": still logging\n"))
    }

    /// Once a log reaches the cap it is kept as exactly one `.previous`
    /// generation and a fresh file receives the new line. A second rotation
    /// replaces that generation rather than accumulating more files.
    func testOversizedLogRotatesIntoOnePreviousGeneration() throws {
        let writer = makeWriter(writingInto: directory)
        let log = directory.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        let previous = log.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        let filler = String(repeating: "x", count: Int(TextMouthPaths.maxLogFileSize))
        try filler.write(to: log, atomically: true, encoding: .utf8)

        writer.append("after rotation", to: .debug)
        writer.flush()

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), filler)
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix(": after rotation\n"), fresh)
        XCTAssertLessThan(fresh.utf8.count, 200)

        let secondFiller = String(repeating: "y", count: Int(TextMouthPaths.maxLogFileSize))
        try secondFiller.write(to: log, atomically: true, encoding: .utf8)
        writer.append("second rotation", to: .debug)
        writer.flush()

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), secondFiller)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix(": second rotation\n"))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(contents, ["textmouth_debug.log", "textmouth_debug.log.previous"])
    }

    /// A file just under the cap is appended to, not rotated, so rotation
    /// happens only when the cap is actually reached.
    func testLogBelowTheCapIsNotRotated() throws {
        let writer = makeWriter(writingInto: directory)
        let log = directory.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        let filler = String(repeating: "x", count: Int(TextMouthPaths.maxLogFileSize) - 1)
        try filler.write(to: log, atomically: true, encoding: .utf8)

        writer.append("appended", to: .debug)
        writer.flush()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: log.appendingPathExtension(TextMouthPaths.rotatedLogExtension).path
        ))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(filler))
        XCTAssertTrue(text.hasSuffix(": appended\n"))
    }

    /// The folder is resolved as each line is written: once it changes,
    /// the next line goes into the new folder, and the old one, removed
    /// meanwhile, is not made again.
    func testEachLineGoesIntoTheFolderInUseWhenItIsWritten() throws {
        let first = directory.appendingPathComponent("First", isDirectory: true)
        let second = directory.appendingPathComponent("Second", isDirectory: true)
        let folder = LockedValue(first)
        let writer = LogWriter(environment: .writing(into: { folder.value }))

        writer.append("into the first", to: .debug)
        writer.flush()
        try FileManager.default.removeItem(at: first)
        folder.value = second
        writer.append("into the second", to: .debug)
        writer.flush()

        let log = second.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix(": into the second\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "a line made the old folder again")
    }

    // MARK: - Rotation in a Synced Folder

    /// A rename refused once, as a File Provider folder can refuse one
    /// while the provider holds the file, is tried once more, and the full
    /// log is kept as the older generation as usual.
    func testARefusedRenameIsTriedOnceMore() throws {
        let attempts = LockedValue(0)
        let writer = makeWriter(writingInto: directory, rename: { from, to in
            attempts.value += 1
            if attempts.value == 1 {
                throw POSIXError(.EBUSY)
            }
            try SavedFile.renameReplacing(from, to)
        })
        let (log, previous, filler) = try makeFullLog()

        writer.append("after a refused rename", to: .debug)
        writer.flush()

        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), filler)
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix(": after a refused rename\n"), fresh)
        XCTAssertFalse(fresh.contains("LOG_ROTATION"), fresh)
    }

    /// A rename refused twice starts the log over in place, so it never
    /// grows past the cap: the older generation stays as it was, and the
    /// log begins with one line saying why its earlier lines are gone.
    func testARenameRefusedTwiceStartsTheLogOverInPlace() throws {
        let attempts = LockedValue(0)
        let writer = makeWriter(writingInto: directory, rename: { _, _ in
            attempts.value += 1
            throw POSIXError(.EPERM)
        })
        let (log, previous, _) = try makeFullLog()
        try "older generation\n".write(to: previous, atomically: true, encoding: .utf8)

        writer.append("after two refusals", to: .debug)
        writer.flush()

        XCTAssertEqual(attempts.value, 2, "a refused rename is tried exactly once more")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "older generation\n")
        let lines = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "the note, the line, and the end of the last line: \(lines)")
        XCTAssertTrue(lines[0].hasSuffix(
            ": LOG_ROTATION: textmouth_debug.log reached 2 MB but couldn't be renamed to textmouth_debug.log.previous "
                + "(Operation not permitted), so it was started over without its earlier lines"
        ), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(": after two refusals"), lines[1])
    }

    /// The real rename, refused because a folder holds the older
    /// generation's name, ends the same way: the log is started over, and
    /// the folder is left alone.
    func testALogThatCannotBeRenamedNeverGrowsPastTheCap() throws {
        let writer = makeWriter(writingInto: directory)
        let (log, previous, _) = try makeFullLog()
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: previous.appendingPathComponent("inside.txt"))

        writer.append("after the real refusals", to: .debug)
        writer.flush()

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertLessThan(text.utf8.count, 1_000)
        XCTAssertTrue(text.contains(": LOG_ROTATION: textmouth_debug.log reached 2 MB but couldn't be renamed"), text)
        XCTAssertTrue(text.hasSuffix(": after the real refusals\n"), text)
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("inside.txt"), encoding: .utf8), "kept")
    }

    /// A log whose content is only in the cloud is never opened to take a
    /// line, which would download it: however small, it is kept as the
    /// older generation, by a rename that needs no content, and a fresh file
    /// takes the line.
    func testALogOnlyInTheCloudIsKeptAsTheOlderGenerationWithoutDownloading() throws {
        let debugLog = DiagnosticLog.File.debug.rawValue
        let writer = makeWriter(writingInto: directory, isOnlyInCloud: { $0.lastPathComponent == debugLog })
        let log = directory.appendingPathComponent(debugLog)
        let previous = log.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        try "lines in the cloud\n".write(to: log, atomically: true, encoding: .utf8)

        writer.append("after the cloud", to: .debug)
        writer.flush()

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "lines in the cloud\n")
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix(": after the cloud\n"), fresh)
        XCTAssertFalse(fresh.contains("lines in the cloud"), fresh)
    }

    // MARK: - The Shared Rename

    /// `SavedFile.renameReplacing` puts the source's content in place of a
    /// file already at the destination, in one step, and leaves no source.
    func testRenameReplacingPutsTheSourceInPlaceOfTheDestination() throws {
        let source = directory.appendingPathComponent("source.partial")
        let destination = directory.appendingPathComponent("destination.txt")
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        try "new".write(to: source, atomically: true, encoding: .utf8)

        try SavedFile.renameReplacing(source, destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the source is gone")
    }

    /// A source that is missing throws the system's own error, `ENOENT`,
    /// and leaves the destination as it was.
    func testRenameReplacingThrowsENOENTForAMissingSource() throws {
        let destination = directory.appendingPathComponent("destination.txt")
        try "kept".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SavedFile.renameReplacing(directory.appendingPathComponent("missing.partial"), destination)
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOENT)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "kept")
    }

    // MARK: - Fixtures

    /// A log writer of the test's own that writes into `folder`, renaming
    /// with `rename` and taking the files `isOnlyInCloud` names as only in
    /// the cloud: by default the real rename(2), and no file.
    private func makeWriter(
        writingInto folder: URL,
        rename: @escaping @Sendable (_ from: URL, _ to: URL) throws -> Void = { try SavedFile.renameReplacing($0, $1) },
        isOnlyInCloud: @escaping @Sendable (_ file: URL) -> Bool = { _ in false }
    ) -> LogWriter {
        LogWriter(environment: .writing(into: { folder }, rename: rename, isOnlyInCloud: isOnlyInCloud))
    }

    /// The debug log in the test's directory, filled to the cap, the path of
    /// its older generation, and what fills it.
    private func makeFullLog() throws -> (log: URL, previous: URL, filler: String) {
        let log = directory.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        let filler = String(repeating: "x", count: Int(TextMouthPaths.maxLogFileSize))
        try filler.write(to: log, atomically: true, encoding: .utf8)
        return (log, log.appendingPathExtension(TextMouthPaths.rotatedLogExtension), filler)
    }

    /// The sleep timer's and speech's own logs keep their names and are
    /// written through the same writer as the debug log, so each rotates
    /// the same way: into exactly one `.previous` generation.
    func testDedicatedLogsRotateThroughTheSharedWriter() throws {
        XCTAssertEqual(DiagnosticLog.File.debug.url, TextMouthPaths.debugLogFile)
        XCTAssertEqual(DiagnosticLog.File.sleepTimer.url.lastPathComponent, "textmouth_timer.log")
        XCTAssertEqual(DiagnosticLog.File.speechTransitions.url.lastPathComponent, "textmouth_transition.log")
        try TextMouthPaths.ensureDirectoryStructure()

        for file in [DiagnosticLog.File.sleepTimer, .speechTransitions] {
            let log = file.url
            let previous = log.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
            defer {
                // Leave the sandbox's log small again for the tests after this one.
                try? FileManager.default.removeItem(at: log)
                try? FileManager.default.removeItem(at: previous)
            }
            TextMouthPaths.flushLogs()
            let filler = String(repeating: "z", count: Int(TextMouthPaths.maxLogFileSize))
            try filler.write(to: log, atomically: true, encoding: .utf8)
            let marker = "ROTATION_PROBE: \(UUID().uuidString)"

            DiagnosticLog.event(.playback, marker, in: file)
            TextMouthPaths.flushLogs()

            XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), filler, file.rawValue)
            XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix(": \(marker)\n"), file.rawValue)
        }
    }

    /// VoiceOver focus diagnostics go through the shared writer into the
    /// debug log, instead of a second private writer that could interleave
    /// with, or crash independently of, it. A sheet writes dozens of them,
    /// so they are trace: written, marked as focus lines, only while tracing
    /// is on.
    func testVoiceOverFocusLogWritesTraceLinesToTheSharedDebugLog() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = "focus-check-\(UUID().uuidString)"

        setAppTracing(false)
        voiceOverFocusLog("while off \(marker)")
        setAppTracing(true)
        voiceOverFocusLog("while on \(marker)")

        let lines = debugLogLines(containing: marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix(": TRACE focus: while on \(marker)") == true, "\(lines)")
    }
}
