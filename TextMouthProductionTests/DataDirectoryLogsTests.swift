import XCTest
@testable import TextMouth

/// The app's diagnostic logs (the user's decision of October 3): in the data
/// directory's Logs folder by default, the sandbox's under tests; in this
/// Mac's ~/Library/Logs/TextMouth, inside the sandbox too, under the other
/// choice and while the data directory can't take lines, without ever
/// bringing back a data directory that is missing (FR02); and carried along
/// by a data-directory move, after which lines go into the moved logs.
@MainActor
final class DataDirectoryLogsTests: XCTestCase {

    /// Under the default choice the logs are in the data directory's Logs
    /// folder, which the data directory's folders include, and every log
    /// file is in it.
    func testTheLogsAreInTheDataDirectorysLogsFolderByDefault() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let logs = TextMouthPaths.root.appendingPathComponent("Logs", isDirectory: true)

        XCTAssertEqual(
            TextMouthPaths.logDestination(for: .dataDirectory),
            LogDestination(folder: logs, reason: .dataDirectory)
        )
        XCTAssertEqual(SettingsPolicy.logLocation.defaultValue, .dataDirectory)
        // The sandbox's preferences hold no other choice, so the app writes there.
        XCTAssertEqual(TextMouthPaths.logsDir.standardizedFileURL.path, logs.standardizedFileURL.path)
        for file in DiagnosticLog.File.allCases {
            XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL.path, logs.standardizedFileURL.path)
        }
    }

    /// This Mac's Logs folder, the other choice, is inside the sandbox and
    /// outside the data directory.
    func testThisMacsLogsFolderIsInsideTheSandbox() {
        let destination = TextMouthPaths.logDestination(for: .machine)
        let logs = destination.folder.standardizedFileURL.path

        XCTAssertEqual(destination.reason, .thisMac)
        XCTAssertEqual(logs, MachineLocalPaths.logs.standardizedFileURL.path)
        XCTAssertTrue(logs.hasSuffix("/Library/Logs/TextMouth"), logs)
        XCTAssertTrue(logs.hasPrefix(HostedTestSandbox.home.standardizedFileURL.path + "/"), logs)
        XCTAssertFalse(logs.hasPrefix(TextMouthPaths.root.standardizedFileURL.path + "/"), logs)
        XCTAssertEqual(MachineLocalPaths.logsName, "~/Library/Logs/TextMouth")
    }

    /// With the data directory missing, a line is written to this Mac's Logs
    /// folder, after one line saying why, and the data directory is not
    /// brought back by it.
    func testLinesAreWrittenWhileTheDataDirectoryIsMissing() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let root = try makeDataDirectoryMoveDestination("LoggingWhileAway")
        let marker = UUID().uuidString
        // A line in the data directory first, so the next one changes place.
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_TEST: written before the library goes away \(marker)")
        TextMouthPaths.flushLogs()
        StorageBoundary.shared.publish(root: root)

        DiagnosticLog.event(.storage, "DATA_DIRECTORY_TEST: written while the library is away \(marker)")
        TextMouthPaths.flushLogs()

        let messages = logMessages(in: MachineLocalPaths.logs)
        let index = try XCTUnwrap(messages.lastIndex { $0.contains("while the library is away \(marker)") })
        XCTAssertEqual(
            index > 0 ? messages[index - 1] : "",
            "LOG_LOCATION: writing the logs in this Mac's Logs folder, ~/Library/Logs/TextMouth, because the data directory "
                + "\(DataDirectoryPaths.shortName(of: root)) is missing; "
                + "they go back to the data directory's Logs folder once it can take them"
        )
        XCTAssertEqual(debugLogLines(containing: "while the library is away \(marker)").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "a log line recreated the data directory")
    }

    /// A data-directory move carries the Logs folder with the rest, and the
    /// next line goes into the moved debug log, under the new root.
    func testAMoveCarriesTheLogsAndTheNextLineGoesIntoTheMovedLog() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = UUID().uuidString
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_TEST: written before the move \(marker)")
        // Settled files only: no write may land in the data directory while
        // it is copied.
        LibraryPersistenceService.flushPendingSave()
        TextMouthPaths.flushLogs()
        let destination = try makeDataDirectoryMoveDestination("LogsMove")
        var library = Library()

        try TextMouthPaths.moveDataDirectory(to: destination, library: &library)
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_TEST: written after the move \(marker)")
        TextMouthPaths.flushLogs()

        let movedLogs = destination.appendingPathComponent("Logs", isDirectory: true)
        XCTAssertEqual(TextMouthPaths.logsDir.standardizedFileURL.path, movedLogs.standardizedFileURL.path)
        XCTAssertEqual(
            logMessages(in: movedLogs).filter { $0.contains(marker) },
            [
                "DATA_DIRECTORY_TEST: written before the move \(marker)",
                "DATA_DIRECTORY_TEST: written after the move \(marker)",
            ]
        )
    }
}
