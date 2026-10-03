import AppKit
import XCTest
@testable import TextMouth

/// The test bundle's principal class, named by NSPrincipalClass in its
/// Info.plist. XCTest makes one instance when it loads the bundle, before
/// any test runs, so it registers the observers that watch every test.
final class TextMouthTestBundle: NSObject {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(ReaderWindowLeakCheck.shared)
        XCTestObservationCenter.shared.addTestObserver(DataDirectoryLeakCheck.shared)
    }
}

/// Fails a test that leaves the data directory somewhere else (TODO S04).
///
/// A data-directory move a test publishes takes the data directory of the
/// whole test process with it, so every later test would read and write in
/// that test's scratch folder, which is removed when it ends. A test moves
/// it with `makeDataDirectoryMoveDestination(_:)`, which puts it back. When
/// a test starts this check notes the data directory, and once the test
/// method and its teardown blocks have run it puts back any other and fails
/// the test, naming where it was left.
///
/// `@unchecked Sendable`: it has no stored state of its own.
final class DataDirectoryLeakCheck: NSObject, XCTestObservation, @unchecked Sendable {
    /// The check the principal class registers.
    static let shared = DataDirectoryLeakCheck()

    func testCaseWillStart(_ testCase: XCTestCase) {
        let root = TextMouthPaths.root
        // Registered first, so it runs after every teardown block the test
        // itself adds.
        testCase.addTeardownBlock {
            let left = TextMouthPaths.root
            guard left.path != root.path else { return }
            restoreDataDirectory(root)
            XCTFail(
                "Left the data directory at \(left.path). Move it with makeDataDirectoryMoveDestination(_:), "
                    + "which puts it back when the test ends."
            )
        }
    }
}

/// Fails a test that leaves a reader window open (TODO Q01).
///
/// The hosted tests run inside the real app, whose Library window opens a
/// real reader window for any book a test asks it to open: on the
/// developer's screen, taking keyboard focus, and read out by VoiceOver.
/// Tests keep clear of that with inert models and notification centers of
/// their own; this check makes sure none slips through. When a test starts it
/// notes the reader windows already open, and once the test method and its
/// teardown blocks have run it closes any new one and fails the test,
/// naming the window.
///
/// The check runs before `tearDown()`, so a test that opens a reader window
/// on purpose must close it in the test itself or in a teardown block.
///
/// `@unchecked Sendable`: XCTest reports to observers on the main thread,
/// and the one stored property is set only there.
final class ReaderWindowLeakCheck: NSObject, XCTestObservation, @unchecked Sendable {
    /// The check the principal class registers.
    static let shared = ReaderWindowLeakCheck()

    /// Whether XCTest reported the start of the bundle to this check, which
    /// proves the principal class registered it.
    private(set) var sawBundleStart = false

    func testBundleWillStart(_ testBundle: Bundle) {
        sawBundleStart = true
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        // XCTest reports test cases on the main thread, where windows live.
        guard Thread.isMainThread else { return }
        let openAtStart = MainActor.assumeIsolated {
            Set(Self.readerWindows(among: Self.openWindows).map(ObjectIdentifier.init))
        }
        // Registered first, so it runs after every teardown block the test
        // itself adds.
        testCase.addTeardownBlock {
            let leaked = Self.closeNewReaderWindows(among: Self.openWindows, except: openAtStart)
            if !leaked.isEmpty {
                XCTFail(
                    "Left \(leaked.count) reader window(s) open: \(leaked.joined(separator: ", ")). "
                        + "Close a reader window in the test itself or in a teardown block."
                )
            }
        }
    }

    /// The app's windows that are on screen or minimized: the ones a user
    /// could find.
    @MainActor
    static var openWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }
    }

    /// The reader windows among `windows`, recognized exactly as the app's
    /// own menus recognize them (see `MenuVisibilityManager.detectWindowType`).
    @MainActor
    static func readerWindows(among windows: [NSWindow]) -> [NSWindow] {
        windows.filter { MenuVisibilityManager.detectWindowType(for: $0) == .reader }
    }

    /// Closes every reader window among `windows` that is not in `known`.
    /// - Returns: The closed windows' titles, quoted, for a failure message.
    @MainActor
    @discardableResult
    static func closeNewReaderWindows(among windows: [NSWindow], except known: Set<ObjectIdentifier>) -> [String] {
        let leaked = readerWindows(among: windows).filter { !known.contains(ObjectIdentifier($0)) }
        for window in leaked {
            window.close()
        }
        return leaked.map { "\"\($0.title)\"" }
    }
}
