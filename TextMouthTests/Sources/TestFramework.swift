import Foundation

// MARK: - Test Framework

var totalTests = 0
var passedTests = 0
var failedTests = 0

func test(_ name: String, _ block: () throws -> Void) {
    totalTests += 1
    do {
        try block()
        passedTests += 1
        print("  PASS: \(name)")
    } catch {
        failedTests += 1
        print("  FAIL: \(name) -- \(error)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else {
        throw TestError.assertionFailed("Expected \(a) == \(b)\(msg.isEmpty ? "" : " (\(msg))")")
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "") throws {
    guard condition else {
        throw TestError.assertionFailed("Expected true\(msg.isEmpty ? "" : " (\(msg))")")
    }
}

func assertGreater(_ a: Int, _ b: Int, _ msg: String = "") throws {
    guard a > b else {
        throw TestError.assertionFailed("Expected \(a) > \(b)\(msg.isEmpty ? "" : " (\(msg))")")
    }
}

enum TestError: LocalizedError {
    case assertionFailed(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let msg): return msg
        case .fileNotFound(let path): return "File not found: \(path)"
        }
    }
}
