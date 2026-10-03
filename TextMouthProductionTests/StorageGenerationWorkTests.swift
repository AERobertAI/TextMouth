import XCTest
@testable import TextMouth

/// Work that writes into the data directory, and the hold a data-directory
/// move puts on it (TODO S04): a move waits for the work under way and
/// names it, work started meanwhile waits for the publication and runs
/// under it, and nothing ever waits on itself.
///
/// Every test uses a boundary of its own, so the app's data directory and
/// its work are never involved, and releases its holds and its waiting
/// threads when it ends, whatever happens.
@MainActor
final class StorageGenerationWorkTests: XCTestCase {

    // MARK: - Running Work

    /// Work on a background thread runs under the current generation.
    func testWorkRunsUnderTheCurrentGeneration() async throws {
        let boundary = try makeBoundary()
        boundary.publish(root: try makeSandboxDirectory("WorkSecond"))
        let ran = expectation(description: "the work ran under generation 1")

        DispatchQueue.global().async {
            let number = boundary.perform(.importing) { $0.number }
            XCTAssertEqual(number, 1)
            ran.fulfill()
        }

        await fulfillment(of: [ran], timeout: 10)
    }

    /// A move waits for the work under way before it goes on, and names it.
    func testAMoveWaitsForTheWorkUnderWayAndNamesIt() async throws {
        let boundary = try makeBoundary()
        let started = expectation(description: "the import started")
        let finish = makeGate()
        DispatchQueue.global().async {
            boundary.perform(.importing) { _ in
                started.fulfill()
                finish.wait()
            }
        }
        await fulfillment(of: [started], timeout: 10)
        let hold = try makeHold(on: boundary)
        var reports: [StorageWork] = []

        await hold.waitForWorkUnderWay { work in
            reports.append(work)
            // The import can finish only once the move says it waits for it.
            finish.signal()
        }

        XCTAssertEqual(reports, [.importing])
    }

    /// With an import and a text extraction under way, a move names the
    /// import first, then the extraction, each once.
    func testAMoveNamesEachKindOfWorkItWaitsForImportFirst() async throws {
        let boundary = try makeBoundary()
        let importStarted = expectation(description: "the import started")
        let extractionStarted = expectation(description: "the extraction started")
        let finishImport = makeGate()
        let finishExtraction = makeGate()
        DispatchQueue.global().async {
            boundary.perform(.textExtraction) { _ in
                extractionStarted.fulfill()
                finishExtraction.wait()
            }
        }
        DispatchQueue.global().async {
            boundary.perform(.importing) { _ in
                importStarted.fulfill()
                finishImport.wait()
            }
        }
        await fulfillment(of: [importStarted, extractionStarted], timeout: 10)
        let hold = try makeHold(on: boundary)
        var reports: [StorageWork] = []

        await hold.waitForWorkUnderWay { work in
            reports.append(work)
            (work == .importing ? finishImport : finishExtraction).signal()
        }

        XCTAssertEqual(reports, [.importing, .textExtraction])
    }

    /// Work started while a move holds work says so, waits until the hold
    /// is released, and then runs under the generation the move published.
    func testWorkStartedDuringAMoveRunsUnderTheGenerationItPublishes() async throws {
        let boundary = try makeBoundary()
        let hold = try makeHold(on: boundary)
        let told = expectation(description: "the extraction was told it is held")
        let ran = expectation(description: "the extraction ran")

        DispatchQueue.global().async {
            let number = boundary.perform(.textExtraction, whileHeld: { told.fulfill() }) { $0.number }
            // Generation 1 exists only once the move has published: work
            // that ran before that would have seen generation 0.
            XCTAssertEqual(number, 1)
            ran.fulfill()
        }
        await fulfillment(of: [told], timeout: 10)
        boundary.publish(root: try makeSandboxDirectory("WorkPublished"))
        hold.release()

        await fulfillment(of: [ran], timeout: 10)
    }

    /// Work started inside other work on the same thread, such as an
    /// import's text extraction, is part of it and runs at once, even while
    /// a move holds work; otherwise the move would wait for the outer work
    /// forever.
    func testWorkInsideWorkOnTheSameThreadRunsAtOnce() async throws {
        let boundary = try makeBoundary()
        let started = expectation(description: "the import started")
        let innerRan = expectation(description: "the import's extraction ran")
        let goOn = makeGate()
        DispatchQueue.global().async {
            boundary.perform(.importing) { _ in
                started.fulfill()
                goOn.wait()
                boundary.perform(.textExtraction) { _ in innerRan.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 10)
        let hold = try makeHold(on: boundary)
        goOn.signal()

        await fulfillment(of: [innerRan], timeout: 10)
        await hold.waitForWorkUnderWay { _ in }
    }

    /// Work on the main thread runs at once while a move holds work: the
    /// move itself runs there, between that work, never across it.
    func testWorkOnTheMainThreadRunsAtOnceDuringAMove() throws {
        let boundary = try makeBoundary()
        _ = try makeHold(on: boundary)

        XCTAssertEqual(boundary.perform(.importing) { $0.number }, 0)
    }

    /// Only one move holds work at a time; once its hold is released,
    /// another move may hold it.
    func testOnlyOneMoveHoldsWorkAtATime() throws {
        let boundary = try makeBoundary()
        let first = try makeHold(on: boundary)

        XCTAssertNil(boundary.holdWork(), "a second move held the work")
        first.release()
        first.release()
        let second = boundary.holdWork()
        XCTAssertNotNil(second)
        second?.release()
    }

    // MARK: - Fixtures

    /// A boundary of the test's own, starting at a scratch folder.
    private func makeBoundary() throws -> StorageBoundary {
        StorageBoundary(root: try makeSandboxDirectory("WorkBoundary"))
    }

    /// A move's hold on `boundary`'s work, released when the test ends
    /// even when the test released it already.
    private func makeHold(on boundary: StorageBoundary) throws -> StorageWorkHold {
        let hold = try XCTUnwrap(boundary.holdWork(), "a move already held the work")
        addTeardownBlock { hold.release() }
        return hold
    }

    /// A gate a background thread waits at until the test signals it,
    /// opened when the test ends so no thread is left waiting.
    private func makeGate() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        return gate
    }
}
