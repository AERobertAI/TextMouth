import Foundation

// The repository's TestData folder, as every test that needs a fixture finds
// it, and the error the legacy scenario helpers throw. They lived in
// LegacyScenarioHarness.swift until November 16, 2026 (DR34), and moved here
// unchanged, so that the iPhone's unit bundle, which shares the format-sample
// helpers (FormatSampleFixtures.swift) with the braille tests, compiles them
// without the legacy scenarios.

enum TestError: LocalizedError {
    case assertionFailed(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let message): message
        case .fileNotFound(let path): "File not found: \(path)"
        }
    }
}

/// The URL of a file in the repository's `TestData` folder, returned whether or not the file exists.
/// This is the one place the fixture path is built (from this file's own location), so every
/// test finds its data the same way.
private func testFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("TestData", isDirectory: true)
        .appendingPathComponent(name)
}

/// Return the URL of a fixture in `TestData`, throwing `TestError.fileNotFound` when it is missing.
/// Use this for fixtures a test cannot run without.
func requireFile(_ name: String) throws -> URL {
    let url = testFileURL(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw TestError.fileNotFound(url.path)
    }
    return url
}

/// Return a fixture path without requiring that an optional fixture exists.
/// Some legacy scenarios intentionally skip large, separately downloaded books.
func testFilePath(_ name: String) -> String {
    testFileURL(name).path
}
