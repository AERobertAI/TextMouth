import XCTest

// The app's own Swift sources, read for the tests that hold the code to a
// rule by scanning it: what log lines may say (LogContentPolicyTests) and
// what confines each unchecked concurrency escape
// (UncheckedConcurrencyPolicyTests).

/// One Swift file of the app, read from the repository these tests were
/// built from.
struct AppSourceFile {
    /// The file's name, such as "DiagnosticLog.swift".
    let name: String
    /// Its path inside the app's source folder, such as
    /// "Services/DiagnosticLog.swift".
    let path: String
    /// What it holds.
    let text: String

    /// The app's source folder: TextMouth, beside the folder this file is in.
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("TextMouth", isDirectory: true)

    /// Every Swift file in the app's source folder and the folders inside
    /// it, in path order. Fails the calling test when there are too few for
    /// the app, so a folder that moved never lets a scan pass having checked
    /// nothing.
    static func all(file: StaticString = #filePath, line: UInt = #line) throws -> [AppSourceFile] {
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil),
            "the app's source folder, \(folder.path), cannot be listed",
            file: file,
            line: line
        )
        let folderPrefix = folder.path + "/"
        var sources: [AppSourceFile] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            // The enumerator names each file below the folder as given, so
            // the folder's path is the start of every file's.
            let path = url.path.hasPrefix(folderPrefix) ? String(url.path.dropFirst(folderPrefix.count)) : url.lastPathComponent
            sources.append(AppSourceFile(name: url.lastPathComponent, path: path, text: try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(sources.count, 50, "Swift files found in \(folder.path)", file: file, line: line)
        return sources.sorted { $0.path < $1.path }
    }
}
