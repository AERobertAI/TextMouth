import Foundation
import XCTest
@testable import TextMouth

// Fixtures shared by the log tests (`LogWriteSafetyTests` and
// `LogLocationTests`), so each exists once, and the reader of the debug log
// that tests on both platforms ask (`debugLogLines(containing:)`).

extension LogWriter.Environment {
    /// An environment that writes every line into the folder `folder`
    /// names, as Storage settings' choice of this Mac's Logs folder does,
    /// that folder standing for this Mac's. It renames with `rename` and
    /// takes the files `isOnlyInCloud` names as only in the cloud: by
    /// default the real rename(2), and no file.
    static func writing(
        into folder: @escaping @Sendable () -> URL,
        rename: @escaping @Sendable (_ from: URL, _ to: URL) throws -> Void = { try SavedFile.renameReplacing($0, $1) },
        isOnlyInCloud: @escaping @Sendable (_ file: URL) -> Bool = { _ in false }
    ) -> Self {
        Self(
            location: { .machine },
            dataDirectory: folder,
            isUnavailable: { _ in false },
            thisMacsFolder: folder,
            rename: rename,
            isOnlyInCloud: isOnlyInCloud
        )
    }
}

/// `line`, a line of a log, without the time it begins with: the message
/// as it was written.
func logMessage(of line: String) -> String {
    line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
}

/// The messages of the log `file` in `folder`, oldest first, without their
/// times; none when the log isn't there.
func logMessages(of file: DiagnosticLog.File = .debug, in folder: URL) -> [String] {
    let log = folder.appendingPathComponent(file.rawValue, isDirectory: false)
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
    return text.components(separatedBy: "\n").filter { !$0.isEmpty }.map(logMessage(of:))
}

/// A value a test shares with the closures that a log writer of the test's
/// own reads on its queue, such as the folder lines go to, so the test can
/// change it between lines.
///
/// `@unchecked Sendable`: the one variable is read and changed only while
/// holding `lock`.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    /// Guards `stored`: the test changes it, the writer's queue reads it.
    private let lock = NSLock()
    /// The value, read and changed only under `lock`.
    private var stored: Value

    /// A box holding `value`.
    init(_ value: Value) {
        stored = value
    }

    /// The value now.
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension XCTestCase {
    /// The debug log's lines that contain `text`, waiting first for every
    /// queued log write. Lines go to the data directory's Logs folder, or to
    /// this Mac's while the data directory can't take them, so both debug
    /// logs are read, each line being in one of them only. The rotated
    /// generations are read too, in case one of the lines started a new file.
    /// It is here, beside the other log fixtures the iPhone's unit bundle
    /// shares, so that the tests both platforms run can read the log (FMT54).
    func debugLogLines(containing text: String) -> [String] {
        TextMouthPaths.flushLogs()
        let folders = [
            TextMouthPaths.root.appendingPathComponent(TextMouthPaths.logsFolderName, isDirectory: true),
            MachineLocalPaths.logs,
        ]
        return folders
            .flatMap { folder -> [URL] in
                let logFile = folder.appendingPathComponent(DiagnosticLog.File.debug.rawValue, isDirectory: false)
                return [logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension), logFile]
            }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(text) }
    }
}
