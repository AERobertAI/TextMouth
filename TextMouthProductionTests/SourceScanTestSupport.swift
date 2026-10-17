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
    /// it, in path order. Fails the calling test when there are fewer than
    /// `minimum`, so a folder that moved never lets a scan pass having
    /// checked nothing. `root` is the folder to scan, the app's unless a
    /// test gives its own, and may be reached through a symbolic link.
    static func all(
        in root: URL = folder,
        atLeast minimum: Int = 51,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [AppSourceFile] {
        // The enumerator names files by their resolved paths, so the folder
        // is resolved too: a checkout under /tmp, a symbolic link to
        // /private/tmp, would otherwise lose its folder from every path.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: resolvedRoot, includingPropertiesForKeys: nil),
            "the app's source folder, \(root.path), cannot be listed",
            file: file,
            line: line
        )
        var sources: [AppSourceFile] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            sources.append(AppSourceFile(
                name: url.lastPathComponent,
                path: relativePath(of: url, in: resolvedRoot),
                text: try String(contentsOf: url, encoding: .utf8)
            ))
        }
        XCTAssertGreaterThanOrEqual(sources.count, minimum, "Swift files found in \(root.path)", file: file, line: line)
        return sources.sorted { $0.path < $1.path }
    }

    /// `url`'s path below `root`, such as "Services/DiagnosticLog.swift",
    /// both resolved through symbolic links first so that one reached by a
    /// link and one reached by its target compare alike; the file's name
    /// alone for a file that is not below `root`.
    static func relativePath(of url: URL, in root: URL) -> String {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
