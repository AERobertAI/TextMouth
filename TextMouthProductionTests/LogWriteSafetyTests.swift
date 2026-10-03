import XCTest
@testable import TextMouth

/// Diagnostic logging must never crash the app, however the disk behaves, and
/// must never grow without bound (TODO Q07). Every test writes only inside a
/// disposable temporary directory or the isolated test data root.
final class LogWriteSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthLogWriteSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every queued write targets this directory; wait so removal is complete.
        TextMouthPaths.flushLogs()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The first line creates the file; later lines append in order, each
    /// timestamped and newline terminated.
    func testAppendCreatesTheFileThenAppendsLinesInOrder() throws {
        let log = directory.appendingPathComponent("test.log")

        TextMouthPaths.appendLog(to: log, message: "first")
        TextMouthPaths.appendLog(to: log, message: "second")
        TextMouthPaths.flushLogs()

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "two lines plus the trailing newline")
        XCTAssertTrue(lines[0].hasSuffix(": first"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix(": second"), String(lines[1]))
        XCTAssertEqual(lines[2], "")
    }

    /// A destination that cannot be written (its directory is missing, or the
    /// file is read-only) is silently skipped. The legacy FileHandle calls
    /// raised uncatchable exceptions here and crashed the app on a full disk.
    func testUnwritableDestinationsAreDroppedWithoutCrashing() throws {
        let missingDirectory = directory.appendingPathComponent("missing/deeper/test.log")
        let readOnly = directory.appendingPathComponent("readonly.log")
        try "locked\n".write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnly.path)
        }

        TextMouthPaths.appendLog(to: missingDirectory, message: "dropped")
        TextMouthPaths.appendLog(to: readOnly, message: "dropped")
        // A later write to a healthy file proves the queue survived the failures.
        let healthy = directory.appendingPathComponent("healthy.log")
        TextMouthPaths.appendLog(to: healthy, message: "still logging")
        TextMouthPaths.flushLogs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
        XCTAssertEqual(try String(contentsOf: readOnly, encoding: .utf8), "locked\n")
        XCTAssertTrue(try String(contentsOf: healthy, encoding: .utf8).hasSuffix(": still logging\n"))
    }

    /// Once a log reaches the cap it is kept as exactly one `.previous`
    /// generation and a fresh file receives the new line. A second rotation
    /// replaces that generation rather than accumulating more files.
    func testOversizedLogRotatesIntoOnePreviousGeneration() throws {
        let log = directory.appendingPathComponent("big.log")
        let previous = log.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        let filler = String(repeating: "x", count: Int(TextMouthPaths.maxLogFileSize))
        try filler.write(to: log, atomically: true, encoding: .utf8)

        TextMouthPaths.appendLog(to: log, message: "after rotation")
        TextMouthPaths.flushLogs()

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), filler)
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix(": after rotation\n"), fresh)
        XCTAssertLessThan(fresh.utf8.count, 200)

        let secondFiller = String(repeating: "y", count: Int(TextMouthPaths.maxLogFileSize))
        try secondFiller.write(to: log, atomically: true, encoding: .utf8)
        TextMouthPaths.appendLog(to: log, message: "second rotation")
        TextMouthPaths.flushLogs()

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), secondFiller)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix(": second rotation\n"))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(contents, ["big.log", "big.log.previous"])
    }

    /// A file just under the cap is appended to, not rotated, so rotation
    /// happens only when the cap is actually reached.
    func testLogBelowTheCapIsNotRotated() throws {
        let log = directory.appendingPathComponent("small.log")
        let filler = String(repeating: "x", count: Int(TextMouthPaths.maxLogFileSize) - 1)
        try filler.write(to: log, atomically: true, encoding: .utf8)

        TextMouthPaths.appendLog(to: log, message: "appended")
        TextMouthPaths.flushLogs()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: log.appendingPathExtension(TextMouthPaths.rotatedLogExtension).path
        ))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(filler))
        XCTAssertTrue(text.hasSuffix(": appended\n"))
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
    /// debug log, marked with their prefix, instead of a second private
    /// writer that could interleave with, or crash independently of, it.
    func testVoiceOverFocusLogWritesToTheSharedDebugLog() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = "focus-check-\(UUID().uuidString)"

        voiceOverFocusLog(marker)
        TextMouthPaths.flushLogs()

        let text = try String(contentsOf: TextMouthPaths.debugLogFile, encoding: .utf8)
        XCTAssertTrue(text.contains(": \(voiceOverFocusLogPrefix): \(marker)\n"), "missing marker line")
    }
}
