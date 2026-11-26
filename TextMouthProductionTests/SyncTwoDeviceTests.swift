import os
import XCTest
@testable import TextMouth

/// Two devices over one stand-in cloud folder, the test choosing when files travel (FR43, section 11).
/// Each is a real engine with its own files; the drive is the one the test controls.
struct SyncTwoDevices {
    /// A device: its engine and its own files.
    struct Device {
        var engine: SyncEngine
        var files: SyncLocalFiles
        var identity: SyncDeviceIdentity
    }

    let drive: SyncTestDrive
    let folder: SyncFolder
    var mac: Device
    var phone: Device
    /// The sandbox the devices' files are in.
    let sandbox: URL

    /// Two devices in a new sandbox.
    init(sandbox: URL) throws {
        self.sandbox = sandbox
        drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        folder = SyncFolder(root: drive.root, access: drive)
        func make(_ name: String, _ install: String) throws -> Device {
            let files = SyncLocalFiles(root: sandbox.appendingPathComponent(name, isDirectory: true))
            let identity = SyncDeviceIdentity(name: name, platform: "test", appVersion: "0.6.0", installID: install)
            return Device(engine: try SyncEngine(local: files, identity: identity), files: files, identity: identity)
        }
        mac = try make("Mac", "install-mac")
        phone = try make("iPhone", "install-phone")
    }

    /// Starts `device` again from its own files, as after a quit or a crash.
    mutating func restart(_ keyPath: WritableKeyPath<SyncTwoDevices, Device>) throws {
        let old = self[keyPath: keyPath]
        self[keyPath: keyPath].engine = try SyncEngine(local: old.files, identity: old.identity)
    }
}

/// What two devices tell each other (FR43, section 11): changes made on both while apart meet in one
/// state, in whatever order the cloud delivers the files.
final class SyncTwoDeviceTests: XCTestCase {
    /// Two books' ids.
    private let first = UUID()
    private let second = UUID()

    /// Both devices change while offline from each other; once they meet they hold the same state.
    func testChangesMadeApartMeetInOneState() async throws {
        let world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("two-devices"))
        try await world.mac.engine.recordKeep(true, for: [first])
        try await world.phone.engine.recordKeep(true, for: [second])
        _ = try await world.mac.engine.exchange(in: world.folder)
        _ = try await world.phone.engine.exchange(in: world.folder)
        _ = try await world.mac.engine.exchange(in: world.folder)
        let onMac = await world.mac.engine.keptBookIDs()
        let onPhone = await world.phone.engine.keptBookIDs()
        XCTAssertEqual(onMac, [first, second])
        XCTAssertEqual(onPhone, onMac)
    }

    /// The cloud delivers a later file before an earlier one: nothing is skipped, and the cursor waits.
    func testFilesArrivingOutOfOrderAreNeverSkipped() async throws {
        let world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("two-devices-order"))
        let macID = await world.mac.engine.deviceID
        for book in [first, second, UUID()] { try await world.mac.engine.recordKeep(true, for: [book]) }
        _ = try await world.mac.engine.exchange(in: world.folder)
        // The snapshot and the first two files are late; the last change file is already there.
        for seq in 1...2 { world.drive.setNotDownloaded(SyncNames.changeFile(seq: seq, kind: .changes)) }
        world.drive.setNotDownloaded(SyncNames.changeFile(seq: 4, kind: .snapshot))
        let early = try await world.phone.engine.exchange(in: world.folder)
        XCTAssertEqual(early.read.cursors.merged[macID] ?? 0, 0)
        let before = await world.phone.engine.keptBookIDs()
        XCTAssertTrue(before.isEmpty)

        for seq in 1...2 { world.drive.setNotDownloaded(SyncNames.changeFile(seq: seq, kind: .changes), false) }
        world.drive.setNotDownloaded(SyncNames.changeFile(seq: 4, kind: .snapshot), false)
        _ = try await world.phone.engine.exchange(in: world.folder)
        let kept = await world.phone.engine.keptBookIDs()
        XCTAssertEqual(kept.count, 3)
    }

    /// A device restarted between exchanges, as after a crash, still ends with the same state.
    func testARestartBetweenExchangesChangesNothing() async throws {
        var world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("two-devices-restart"))
        try await world.mac.engine.recordKeep(true, for: [first])
        _ = try await world.mac.engine.exchange(in: world.folder)
        _ = try await world.phone.engine.exchange(in: world.folder)
        try world.restart(\.phone)
        try await world.mac.engine.recordKeep(true, for: [second])
        _ = try await world.mac.engine.exchange(in: world.folder)
        _ = try await world.phone.engine.exchange(in: world.folder)
        let kept = await world.phone.engine.keptBookIDs()
        XCTAssertEqual(kept, [first, second])
    }
}

/// A run, an exchange, and a copy stopped after each step and started afresh (FR43, section 11): each change
/// is in the outbox or the folder, nothing is lost, nothing is sent twice.
final class SyncInterruptionTests: XCTestCase {
    /// A copy that stops after the first file leaves nothing lost or doubled once the exchange is run again.
    func testAnInterruptedExchangeIsFinishedByTheNextOne() async throws {
        var world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("interrupt-exchange"))
        for _ in 1...3 { try await world.mac.engine.recordKeep(true, for: [UUID()]) }
        world.drive.failCopies(after: 1)
        do {
            _ = try await world.mac.engine.exchange(in: world.folder)
            XCTFail("the copy was stopped")
        } catch {}
        try world.restart(\.mac)
        world.drive.failCopies(after: nil)
        _ = try await world.mac.engine.exchange(in: world.folder)
        XCTAssertEqual(Set(world.drive.copiedPaths).count, world.drive.copiedPaths.count, "no file went twice")
        _ = try await world.phone.engine.exchange(in: world.folder)
        let kept = await world.phone.engine.keptBookIDs()
        XCTAssertEqual(kept.count, 3)
    }
}

/// A run stopped after each of its steps in turn (section 11), then started afresh on the same files.
extension SyncInterruptionTests {
    /// After a stop at any step: every change made before it is in the folder or still in the outbox, never lost or
    /// doubled; the library is as it was; and a second device ends with the same state as the first.
    func testAStopAfterEveryStepLosesNothing() async throws {
        for step in SyncStep.allCases {
            try await checkAStop(after: step)
        }
    }

    /// One stop: the Mac records its library and a keep, exchanges, and is stopped after `step`; it restarts, and
    /// the two devices meet.
    private func checkAStop(after step: SyncStep) async throws {
        var world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("interrupt-\(step.rawValue)"))
        let rows = [SyncTestFixtures.book(title: "One"), SyncTestFixtures.book(title: "Two")]
        let library = SyncTestFixtures.library(books: rows)
        let keep = UUID()
        let theirs = UUID()
        // The iPhone wrote something for the Mac to read, merge, and apply.
        try await world.phone.engine.recordKeep(true, for: [theirs])
        _ = try await world.phone.engine.exchange(in: world.folder)

        // The Mac works until the stop. The stop throws at `step` wherever the step is reached.
        struct Stop: Error {}
        let reachedIt = OSAllocatedUnfairLock(initialState: false)
        await world.mac.engine.setStopAfter { reached in
            if reached == step {
                reachedIt.withLock { $0 = true }
                throw Stop()
            }
        }
        _ = try? await world.mac.engine.record(library: library)
        try? await world.mac.engine.recordKeep(true, for: [keep])
        _ = try? await world.mac.engine.exchange(in: world.folder)
        let application = await world.mac.engine.application(for: library, voices: nil)
        try? await world.mac.engine.didApply(application, keys: application.appliedKeys)

        XCTAssertTrue(reachedIt.withLock { $0 }, "the stop after \(step) was never reached")

        // Started afresh on the same files, as after a crash: the app records again, exchanges, and applies.
        try world.restart(\.mac)
        let relaunched = world.mac.engine
        _ = try await relaunched.record(library: library)
        let again = try await relaunched.exchange(in: world.folder)
        XCTAssertNil(again.uploadProblem, "after a stop after \(step)")
        let rebuilt = await relaunched.application(for: library, voices: nil)
        try await relaunched.didApply(rebuilt, keys: rebuilt.appliedKeys)
        _ = try await world.phone.engine.exchange(in: world.folder)
        _ = try await relaunched.exchange(in: world.folder)

        // The library opens, and every row is still there.
        XCTAssertEqual(rebuilt.library.books.map(\.id), rows.map(\.id), "rows are kept after a stop after \(step)")

        // Every change made before the stop is in the state: the keep, the rows' presence, and the other device's keep.
        let macKept = await relaunched.keptBookIDs()
        let phoneKept = await world.phone.engine.keptBookIDs()
        XCTAssertEqual(macKept, [keep, theirs], "the Mac's keeps after a stop after \(step)")
        XCTAssertEqual(phoneKept, macKept, "the iPhone ends with the Mac's keeps after a stop after \(step)")
        for row in rows {
            let onMac = await relaunched.entry(for: .book(row.id, .presence))
            let onPhone = await world.phone.engine.entry(for: .book(row.id, .presence))
            XCTAssertEqual(onMac?.value, .bool(true), "a row recorded by the Mac after a stop after \(step)")
            XCTAssertEqual(onPhone?.value, onMac?.value, "the iPhone holds the same row after a stop after \(step)")
        }
        // Nothing went into the folder twice. Files are told apart by their path: both devices write seq 1, seq 2, and so
        // on, so the same bare name in two devices' folders is two files.
        XCTAssertEqual(Set(world.drive.copiedPaths).count, world.drive.copiedPaths.count, "a file went twice after a stop after \(step): \(world.drive.copiedPaths)")
    }
}

/// Each moment in each network case (FR43, section 11): the library stays whole, every wait is bounded, and
/// the status can say what happened.
final class SyncNetworkCaseTests: XCTestCase {
    /// Offline: files not downloaded are not waited for; the read says it was refused at once.
    func testOfflineReadsAreRefusedAtOnce() async throws {
        let world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("network-offline"))
        try await world.mac.engine.recordKeep(true, for: [UUID()])
        _ = try await world.mac.engine.exchange(in: world.folder)
        let macID = await world.mac.engine.deviceID
        for name in [SyncNames.changeFile(seq: 1, kind: .changes), SyncNames.changeFile(seq: 2, kind: .snapshot)] {
            world.drive.setNotDownloaded(name)
        }
        world.drive.setOffline(true)
        let result = try await world.phone.engine.exchange(in: world.folder)
        XCTAssertTrue(result.read.sawOffline)
        XCTAssertEqual(result.read.cursors.merged[macID] ?? 0, 0)
        XCTAssertTrue(world.drive.readLimits.allSatisfy { $0 <= .seconds(30) }, "every wait was bounded")
    }

    /// The folder lost: the outbox keeps growing and is sent when the folder is back.
    func testALostFolderKeepsTheChangesForLater() async throws {
        let world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("network-lost"))
        world.drive.setFolderLost(true)
        try await world.mac.engine.recordKeep(true, for: [UUID()])
        do {
            _ = try await world.drive.withFolder { _ in 0 }
            XCTFail("the folder is lost")
        } catch { XCTAssertEqual(error as? SyncProblem, .folderMissing) }
        let waiting = await world.mac.engine.pendingChanges()
        XCTAssertEqual(waiting, 1)
        world.drive.setFolderLost(false)
        let result = try await world.mac.engine.exchange(in: world.folder)
        XCTAssertEqual(result.pendingChanges, 0)
    }

    /// A drive that refuses for room: the upload problem is reported, and the changes stay counted.
    func testAFullDriveIsReported() async throws {
        let world = try SyncTwoDevices(sandbox: try makeSandboxDirectory("network-full"))
        world.drive.setUpload(.failed(.outOfSpace))
        try await world.mac.engine.recordKeep(true, for: [UUID()])
        let result = try await world.mac.engine.exchange(in: world.folder)
        XCTAssertEqual(result.uploadProblem, .outOfSpace)
        XCTAssertEqual(result.pendingChanges, 1)
    }
}
