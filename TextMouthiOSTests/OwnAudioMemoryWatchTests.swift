import os
import XCTest
@testable import TextMouth

/// The iPhone's watch on the memory a conversion by TextMouth's own readers
/// takes (`OwnAudioMemoryWatch`): the floor FFmpeg's in-app run keeps, asked
/// before each block, ending a conversion with the same sentences. A scripted
/// system stands in for `os_proc_available_memory()`; nothing is decoded.
final class OwnAudioMemoryWatchTests: XCTestCase {
    /// A megabyte, in bytes.
    private static let megabyte = 1_048_576

    /// A floor of 512 MB over a scripted system that has `atStart` bytes left
    /// as a run begins (its first reading) and `after` from then on.
    private static func floor(atStart: Int, after: Int, zeroMeansNoLimit: Bool = false) -> SessionMemoryFloor {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        return SessionMemoryFloor(
            bytes: 512 * megabyte,
            available: {
                readings.withLock { count -> Int in
                    count += 1
                    return count == 1 ? atStart : after
                }
            },
            zeroMeansNoLimit: zeroMeansNoLimit
        )
    }

    /// With the memory the floor asks for, a block is decoded: nothing is
    /// thrown, however many times it is asked.
    func testNothingIsThrownWhileTheAppHasMemoryToSpare() throws {
        let megabyte = Self.megabyte
        let watch = OwnAudioMemoryWatch(
            fileName: "a.ape", floor: Self.floor(atStart: 2_000 * megabyte, after: 600 * megabyte))
        for _ in 0..<5 { XCTAssertNoThrow(try watch.check()) }
    }

    /// A conversion that leaves the app less memory than its floor ends, in
    /// the words FFmpeg's in-app run ends in: what the app's memory grew by.
    func testAConversionThatLeavesTooLittleMemoryEndsSayingWhatTheAppsMemoryGrewBy() {
        let megabyte = Self.megabyte
        let watch = OwnAudioMemoryWatch(
            fileName: "a.ape", floor: Self.floor(atStart: 2_000 * megabyte, after: 300 * megabyte))
        XCTAssertThrowsError(try watch.check()) { error in
            let failure = error as? ImportAudioConverter.Failure
            XCTAssertEqual(
                failure, .killed(fileName: "a.ape", reason: "the app's memory grew by more than 1700 MB while it ran"))
            XCTAssertEqual(
                failure?.errorDescription,
                "Converting a.ape was stopped because the app's memory grew by more than 1700 MB while it ran.")
        }
    }

    /// A conversion that began with little memory free keeps half of it, and
    /// says it began short, as FFmpeg's does.
    func testAConversionThatBeganShortSaysSo() {
        let megabyte = Self.megabyte
        let watch = OwnAudioMemoryWatch(
            fileName: "a.wv", floor: Self.floor(atStart: 400 * megabyte, after: 100 * megabyte))
        XCTAssertThrowsError(try watch.check()) { error in
            XCTAssertEqual(
                error as? ImportAudioConverter.Failure,
                .killed(
                    fileName: "a.wv",
                    reason: "the iPhone had only 400 MB of memory free when it began, and TextMouth keeps half of that free"))
        }
    }

    /// The system's 0 is an app over its limit on an iPhone, which ends the
    /// conversion at once, and no limit in the simulator, where it does not.
    func testZeroLeftEndsAConversionOnAnIPhoneAndNotInTheSimulator() {
        let megabyte = Self.megabyte
        let phone = OwnAudioMemoryWatch(
            fileName: "a.tta", floor: Self.floor(atStart: 2_000 * megabyte, after: 0, zeroMeansNoLimit: false))
        XCTAssertThrowsError(try phone.check())
        let simulator = OwnAudioMemoryWatch(
            fileName: "a.tta", floor: Self.floor(atStart: 2_000 * megabyte, after: 0, zeroMeansNoLimit: true))
        XCTAssertNoThrow(try simulator.check())
    }
}
