import XCTest
@testable import TextMouth

/// The diagnostic logs on this Mac (FR02): they live in ~/Library/Logs/
/// TextMouth, inside the hosted sandbox under tests, never in the data
/// directory, so logging works while the data directory is missing and the
/// logs never sync.
@MainActor
final class DataDirectoryLogsTests: XCTestCase {

    /// The logs folder is this Mac's, inside the sandbox and outside the
    /// data directory, and every log file is in it.
    func testTheLogsFolderIsThisMacsInsideTheSandbox() {
        let logs = TextMouthPaths.logsDir.standardizedFileURL.path

        XCTAssertEqual(logs, MachineLocalPaths.logs.standardizedFileURL.path)
        XCTAssertTrue(logs.hasSuffix("/Library/Logs/TextMouth"), logs)
        XCTAssertTrue(logs.hasPrefix(HostedTestSandbox.home.standardizedFileURL.path + "/"), logs)
        XCTAssertFalse(logs.hasPrefix(TextMouthPaths.root.standardizedFileURL.path + "/"), logs)
        for file in DiagnosticLog.File.allCases {
            XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL.path, logs)
        }
    }

    /// With the data directory missing, a line is still written to the
    /// debug log, and the data directory is not brought back by it.
    func testLinesAreWrittenWhileTheDataDirectoryIsMissing() throws {
        let root = try makeDataDirectoryMoveDestination("LoggingWhileAway")
        StorageBoundary.shared.publish(root: root)
        let marker = UUID().uuidString

        DiagnosticLog.event(.storage, "DATA_DIRECTORY_TEST: written while the library is away \(marker)")

        XCTAssertEqual(debugLogLines(containing: marker).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "a log line recreated the data directory")
    }
}
