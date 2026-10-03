import XCTest
@testable import TextMouth

/// The app's listener for the progress the system publishes for a file
/// (FR02, `PublishedFileProgress`), heard through progress this process
/// publishes itself, as a sync service publishes its downloads, so no cloud
/// drive is needed. The system hands each publication to its listeners on
/// the main thread a moment later, so each test waits, up to a limit, for
/// what it expects to hear.
final class PublishedFileProgressTests: XCTestCase {

    /// A listener hears the fraction already done when progress is
    /// published for its file, then each later one, through to the whole.
    func testAListenerHearsEachFractionPublishedForItsFile() async throws {
        let file = try makeFile("Harbor Charts.m4b")
        let heard = HeardFractions()
        let listening = PublishedFileProgress.listen(to: file) { heard.append($0) }
        defer { listening.stop() }

        let download = Self.publishDownload(of: file, totalUnitCount: 4)
        defer { download.unpublish() }
        try await waitFor("the publication") { heard.all.contains(0) }
        download.completedUnitCount = 1
        try await waitFor("a quarter") { heard.all.last == 0.25 }
        download.completedUnitCount = 4
        try await waitFor("the whole") { heard.all.last == 1 }

        XCTAssertEqual(heard.changes, [0, 0.25, 1])
    }

    /// A listener hears only its own file, and nothing once it stops: a
    /// listener on another file hears that file's progress, and one on the
    /// same file that goes on listening hears what the stopped one would
    /// have.
    func testAListenerHearsOnlyItsFileAndNothingOnceStopped() async throws {
        let file = try makeFile("Breakwater Survey.m4b")
        let otherFile = try makeFile("Ferry Timetable.m4b")
        let stopped = HeardFractions()
        let goingOn = HeardFractions()
        let other = HeardFractions()
        let stopping = PublishedFileProgress.listen(to: file) { stopped.append($0) }
        let listening = PublishedFileProgress.listen(to: file) { goingOn.append($0) }
        let otherListening = PublishedFileProgress.listen(to: otherFile) { other.append($0) }
        defer {
            listening.stop()
            otherListening.stop()
        }

        let otherDownload = Self.publishDownload(of: otherFile, totalUnitCount: 2)
        defer { otherDownload.unpublish() }
        otherDownload.completedUnitCount = 1
        let download = Self.publishDownload(of: file, totalUnitCount: 8)
        defer { download.unpublish() }
        download.completedUnitCount = 3
        try await waitFor("each file's fraction") {
            other.all.contains(0.5) && stopped.all.contains(0.375) && goingOn.all.contains(0.375)
        }
        stopping.stop()
        stopping.stop()
        download.completedUnitCount = 8
        try await waitFor("the whole, by the listener going on") { goingOn.all.last == 1 }

        XCTAssertFalse(stopped.all.contains(0.5), "a listener heard another file's progress: \(stopped.all)")
        XCTAssertFalse(stopped.all.contains(1), "a listener heard progress after it stopped: \(stopped.all)")
    }

    // MARK: - Helpers

    /// A small file named `name` in a scratch folder of the test's own.
    private func makeFile(_ name: String) throws -> URL {
        let file = try makeSandboxDirectory("PublishedProgress").appendingPathComponent(name)
        try Data(count: 16).write(to: file)
        return file
    }

    /// The progress of a download of `file` in `totalUnitCount` units,
    /// published as a sync service publishes its downloads. The caller
    /// unpublishes it.
    private static func publishDownload(of file: URL, totalUnitCount: Int64) -> Progress {
        let progress = Progress(totalUnitCount: totalUnitCount)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = file
        progress.publish()
        return progress
    }

    /// Waits until `condition` holds, checking every 20 milliseconds, and
    /// fails the test, naming `what` it waited to hear, after 10 seconds.
    private func waitFor(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("Never heard \(what)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The fractions a listener heard, in order, from whichever thread it heard
/// them on.
private final class HeardFractions: @unchecked Sendable {
    /// Guards `fractions`.
    private let lock = NSLock()
    /// Every fraction heard, in order.
    private var fractions: [Double] = []

    /// Notes that `fraction` was heard.
    func append(_ fraction: Double) {
        lock.withLock { fractions.append(fraction) }
    }

    /// Every fraction heard so far, in order.
    var all: [Double] {
        lock.withLock { fractions }
    }

    /// Every fraction heard so far, a fraction heard again at once counted
    /// once: the system may report one fraction twice.
    var changes: [Double] {
        all.reduce(into: []) { changes, fraction in
            if changes.last != fraction { changes.append(fraction) }
        }
    }
}
