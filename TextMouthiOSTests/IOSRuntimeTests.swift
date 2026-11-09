import XCTest
@testable import TextMouth

/// `TextMouthRuntime` as only the iPhone app compiles it. Its home is the
/// app's own container, never the home the user database names, which in the
/// simulator is the Mac user's, whose ~/.TextMouth is the Mac app's live
/// library. A process hosting tests, and the debug build launched by a UI test
/// that asks (`PhoneLaunchRequest`), run in a sandbox in the temporary folder.
/// These compare paths only: nothing here reads a library.
final class IOSRuntimeTests: XCTestCase {

    /// The temporary folder, as the runtime is given it.
    private let temporary = FileManager.default.temporaryDirectory

    /// This process hosts the tests, so its runtime is a sandbox in the
    /// temporary folder, and so is the library's default place: the tests
    /// never reach the app's own library in its container.
    func testThisHostingProcessRunsInASandbox() {
        let current = TextMouthRuntime.current
        XCTAssertTrue(current.isHostedTest)
        XCTAssertTrue(
            current.homeDirectory.standardizedFileURL.path.hasPrefix(temporary.standardizedFileURL.path),
            "\(current.homeDirectory.path) is outside \(temporary.path)"
        )
        XCTAssertTrue(TextMouthPaths.defaultRoot.path.hasPrefix(current.homeDirectory.path))
        XCTAssertNotNil(current.preferencesFile, "The hosted process's preferences are kept in its sandbox")
    }

    // The next two tests read `PhoneLaunchRequest`, which debug builds alone hold.
    #if DEBUG

    /// A UI test's launch that asks runs as a hosted test does: in a sandbox
    /// named for its process, with preferences of its own.
    func testAUITestsLaunchThatAsksRunsInASandbox() {
        let runtime = TextMouthRuntime.detect(
            environment: [PhoneLaunchRequest.sandboxVariable: "1"],
            processIdentifier: 777,
            temporaryDirectory: temporary
        )
        XCTAssertTrue(runtime.isHostedTest)
        XCTAssertEqual(runtime.homeDirectory.deletingLastPathComponent().standardizedFileURL, temporary.standardizedFileURL)
        XCTAssertTrue(runtime.homeDirectory.lastPathComponent.hasSuffix("777"), runtime.homeDirectory.lastPathComponent)
        XCTAssertNotNil(runtime.preferencesFile)
    }

    /// Without the request, or with any value but "1", the app's home is its
    /// container: on iOS `realHomeDirectory` is Apple's home for the app,
    /// whose path in the simulator and on a phone alike runs through the
    /// app's data container, never the Mac user's home.
    func testWithoutTheRequestTheHomeIsTheAppsContainer() {
        for environment in [[:], [PhoneLaunchRequest.sandboxVariable: "0"]] {
            let runtime = TextMouthRuntime.detect(environment: environment, processIdentifier: 778, temporaryDirectory: temporary)
            XCTAssertFalse(runtime.isHostedTest, "\(environment)")
            XCTAssertEqual(runtime.homeDirectory, TextMouthRuntime.realHomeDirectory)
            XCTAssertTrue(
                runtime.homeDirectory.path.contains("/Containers/Data/Application/"),
                "\(runtime.homeDirectory.path) is not an app's container"
            )
        }
    }

    #endif

    /// The library's default place in a container: Library/Application
    /// Support/.TextMouth, hidden from the Files app and backed up.
    func testTheLibraryLivesInApplicationSupport() {
        let home = URL(fileURLWithPath: "/Containers/Data/Application/0000", isDirectory: true)
        XCTAssertEqual(
            TextMouthPaths.defaultRoot(in: home).path,
            "/Containers/Data/Application/0000/Library/Application Support/.TextMouth"
        )
    }
}
