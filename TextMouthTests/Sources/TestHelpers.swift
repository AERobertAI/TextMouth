import Foundation

// MARK: - Test Data Path

let testDataDir: String = {
    // Try relative to CWD first, then script location
    let cwd = FileManager.default.currentDirectoryPath
    let candidates = [
        "\(cwd)/../TestData",
        "\(cwd)/TestData",
        "\(cwd)/../../TestData",
    ]
    for c in candidates {
        let resolved = (c as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: "\(resolved)/alice.epub") {
            return resolved
        }
    }
    // Absolute fallback
    return "/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TestData"
}()

func testFilePath(_ name: String) -> String {
    return "\(testDataDir)/\(name)"
}

func requireFile(_ name: String) throws -> URL {
    let path = testFilePath(name)
    guard FileManager.default.fileExists(atPath: path) else {
        throw TestError.fileNotFound(path)
    }
    return URL(fileURLWithPath: path)
}
