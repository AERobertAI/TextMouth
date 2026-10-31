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

/// Runs one legacy scenario, `block`, as an XCTest activity named `name`,
/// recording a failure, named for the scenario, for any error it throws.
///
/// Main-actor isolated, as `XCTContext.runActivity` is, so every scenario
/// runner (`run…Tests()`) and the test class that calls it are main-actor
/// isolated too (TODO Q06). XCTest already runs those synchronous test
/// methods on the main thread; isolation lets the compiler see it.
@MainActor
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

@MainActor
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

@MainActor
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

@MainActor
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

@MainActor
final class LegacyKeyboardShortcutScenarioTests: XCTestCase {
    func testLegacyKeyboardShortcutScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runKeyboardShortcutTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            37,
            "Every inventoried keyboard-shortcut and sound scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyDOCXParserScenarioTests: XCTestCase {
    func testLegacyDOCXParserScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDOCXParserTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            26,
            "Every inventoried DOCX fixture scenario should remain registered"
        )
    }
}

@MainActor
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

@MainActor
final class LegacyEPUBParserScenarioTests: XCTestCase {
    func testLegacyEPUBParserScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runEPUBParserTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            16,
            "Every inventoried EPUB parser scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyDAISYParserScenarioTests: XCTestCase {
    func testLegacyDAISYParserScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDAISYParserTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            37,
            "Every inventoried DAISY parser scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyDAISYEdgeCaseScenarioTests: XCTestCase {
    func testLegacyDAISYEdgeCaseScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDAISYEdgeCaseTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            16,
            "Every inventoried DAISY edge-case scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyDAISYAudioScenarioTests: XCTestCase {
    func testLegacyDAISYAudioScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runDAISYAudioTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            13,
            "Every inventoried DAISY audio scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyMenuVisibilityScenarioTests: XCTestCase {
    func testLegacyMenuVisibilityScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runMenuVisibilityTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            16,
            "Every inventoried menu-visibility scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyIntegrationScenarioTests: XCTestCase {
    func testLegacyIntegrationScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runIntegrationTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            34,
            "Every inventoried integration scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyBugRegressionScenarioTests: XCTestCase {
    func testLegacyBugRegressionScenarios() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runBugRegressionTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            13,
            "Every inventoried bug-regression scenario should remain registered"
        )
    }
}

@MainActor
final class LegacyFolderNavigationScenarioTests: XCTestCase {
    func testFolderNavigationScenariosUseProductionHistory() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runFolderNavigationHistoryTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            22,
            "Every folder-navigation scenario should use FolderNavigationHistory"
        )
    }
}

@MainActor
final class LegacyFolderSortSettingScenarioTests: XCTestCase {
    func testFolderSortSettingScenariosUseProductionLibrary() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runFolderSortSettingTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            29,
            "Every folder-sort scenario should use the production Library model"
        )
    }
}

@MainActor
final class LegacyManualOrderScenarioTests: XCTestCase {
    func testManualOrderScenariosUseProductionPolicy() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runManualOrderTests()
        XCTAssertEqual(
            LegacyScenarioRecorder.shared.count - initialCount,
            14,
            "Every manual-order scenario should use ManualBookOrder"
        )
    }
}

@MainActor
final class LegacyOrphanRecoveryScenarioTests: XCTestCase {
    func testOrphanAdoptionScenariosUseProductionRecovery() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runOrphanAdoptionTests()
        XCTAssertEqual(LegacyScenarioRecorder.shared.count - initialCount, 9)
    }

    func testMisplacedPackageScenariosUseProductionRecovery() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runRelocationTests()
        XCTAssertEqual(LegacyScenarioRecorder.shared.count - initialCount, 4)
    }

    func testEmptyDirectoryCleanupScenariosUseProductionRecovery() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runEmptyDirectoryCleanupTests()
        XCTAssertEqual(LegacyScenarioRecorder.shared.count - initialCount, 5)
    }

    func testRemovedLibraryBookCannotBeReadopted() {
        let initialCount = LegacyScenarioRecorder.shared.count
        runOrphanNonReAdoptionTests()
        XCTAssertEqual(LegacyScenarioRecorder.shared.count - initialCount, 1)
    }
}
