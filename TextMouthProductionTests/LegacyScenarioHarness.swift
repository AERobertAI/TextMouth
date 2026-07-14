import Foundation
import XCTest
@testable import TextMouth

/// Compatibility layer for incrementally moving the old scenario-style tests
/// into the hosted XCTest target. Ported scenario files must import TextMouth
/// and call production APIs; copied app implementations are never included.
private final class LegacyScenarioRecorder: @unchecked Sendable {
    static let shared = LegacyScenarioRecorder()

    private let lock = NSLock()
    private var scenarioCount = 0

    func recordScenario() {
        lock.lock()
        scenarioCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scenarioCount
    }
}

func test(_ name: String, _ block: () throws -> Void) {
    LegacyScenarioRecorder.shared.recordScenario()
    XCTContext.runActivity(named: name) { _ in
        do {
            try block()
        } catch {
            XCTFail("\(name): \(error.localizedDescription)")
        }
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    guard actual == expected else {
        throw TestError.assertionFailed(
            "Expected \(actual) == \(expected)\(message.isEmpty ? "" : " (\(message))")"
        )
    }
}

func assertTrue(_ condition: Bool, _ message: String = "") throws {
    guard condition else {
        throw TestError.assertionFailed(
            "Expected true\(message.isEmpty ? "" : " (\(message))")"
        )
    }
}

func assertGreater(_ actual: Int, _ threshold: Int, _ message: String = "") throws {
    guard actual > threshold else {
        throw TestError.assertionFailed(
            "Expected \(actual) > \(threshold)\(message.isEmpty ? "" : " (\(message))")"
        )
    }
}

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

func requireFile(_ name: String) throws -> URL {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot.appendingPathComponent("TestData", isDirectory: true)
        .appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw TestError.fileNotFound(url.path)
    }
    return url
}

final class LegacyOffsetMapScenarioTests: XCTestCase {
    func testLegacyOffsetMapScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runOffsetMapTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            21,
            "Every inventoried OffsetMap scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyTextSubstitutionScenarioTests: XCTestCase {
    func testLegacyTextSubstitutionScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runTextSubstitutionTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            76,
            "Every inventoried text-substitution scenario should remain registered"
        )
    }
}

final class LegacyParserEdgeCaseScenarioTests: XCTestCase {
    func testLegacyParserEdgeCaseScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runParserEdgeCaseTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            13,
            "Every inventoried parser edge-case scenario should remain registered"
        )
    }
}

final class LegacyBookmarkToggleScenarioTests: XCTestCase {
    func testLegacyBookmarkToggleScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runBookmarkToggleTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            57,
            "Every inventoried bookmark and shortcut scenario should remain registered"
        )
    }
}

final class LegacyKeyboardShortcutScenarioTests: XCTestCase {
    func testLegacyKeyboardShortcutScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runKeyboardShortcutTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            36,
            "Every inventoried keyboard-shortcut and sound scenario should remain registered"
        )
    }
}

final class LegacyDOCXParserScenarioTests: XCTestCase {
    func testLegacyDOCXParserScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDOCXParserTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            24,
            "Every inventoried DOCX fixture scenario should remain registered"
        )
    }
}

final class LegacyDOCXEdgeCaseScenarioTests: XCTestCase {
    func testLegacyDOCXEdgeCaseScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDOCXEdgeCaseTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            20,
            "Every inventoried DOCX conversion edge case should remain registered"
        )
    }
}
