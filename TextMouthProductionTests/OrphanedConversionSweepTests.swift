import Darwin
import XCTest
@testable import TextMouth

/// The launch sweep that kills `afconvert` processes an earlier TextMouth
/// left running (REV17a finding 4). The rules are tested on fabricated
/// snapshots, so no real afconvert is ever run or killed; the lister is
/// tested on live processes (the test host, and a `sleep` it starts).
final class OrphanedConversionSweepTests: XCTestCase {

    private let uuid = "6F1C2B7E-0C55-4B1B-9D5F-0A1B2C3D4E5F"
    private var sleepProcess: Process?

    /// A flag a background closure may set, safely.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    override func tearDown() {
        // Stop and reap the child the lister test started.
        if let child = sleepProcess {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        sleepProcess = nil
        super.tearDown()
    }

    // MARK: Helpers

    /// A snapshot that the sweep must kill, with any part changed by a test.
    private func snapshot(
        pid: pid_t = 900,
        parent: pid_t = 1,
        user: uid_t = geteuid(),
        path: String = "/usr/bin/afconvert",
        arguments: [String]? = nil
    ) -> ProcessSnapshot {
        let output = "/Users/x/Book/.01.\(uuid).audio-conversion.m4a"
        return ProcessSnapshot(
            pid: pid, parentPid: parent, userID: user, path: path,
            arguments: arguments ?? ["afconvert", "-f", "m4af", "-d", "aac", "/Users/x/Book/01.ogg", output])
    }

    /// The pids `sweep` returns for `processes`, with the kill calls recorded.
    private func sweep(_ processes: [ProcessSnapshot]) -> (pids: [pid_t], kills: [(pid_t, Int32)]) {
        var kills: [(pid_t, Int32)] = []
        let pids = OrphanedConversionSweep.sweep(processes: processes) { kills.append(($0, $1)) }
        return (pids, kills)
    }

    // MARK: Killed

    func testAnOrphanedConverterWithTheLongTemporaryNameIsKilled() {
        let result = sweep([snapshot()])
        XCTAssertEqual(result.pids, [900])
        XCTAssertEqual(result.kills.count, 1)
        XCTAssertEqual(result.kills.first?.0, 900)
        XCTAssertEqual(result.kills.first?.1, SIGKILL)
    }

    func testAnOrphanedConverterWithTheShortTemporaryNameIsKilled() {
        let output = "/Users/x/Book/.\(uuid).audio-conversion.m4a"
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", output])]).pids, [900])
    }

    /// A converter an earlier version left running has the legacy suffix
    /// on its output, and is swept all the same.
    func testAnOrphanedConverterWithTheLegacyTemporaryNameIsKilled() {
        let output = "/Users/x/Book/.01.\(uuid).ogg-conversion.m4a"
        XCTAssertEqual(ImportAudioConverter.legacyTemporarySuffix, ".ogg-conversion.m4a")
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", output])]).pids, [900])
    }

    func testAFolderWithSpacesAndNonASCIICharactersIsStillMatched() {
        let output = "/Users/x/Mein Bücher/Die Räuber – Teil 1/.01.\(uuid).audio-conversion.m4a"
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", output])]).pids, [900])
    }

    // MARK: Spared

    func testAConverterWhoseParentIsAliveIsSpared() {
        let result = sweep([snapshot(parent: 4321)])
        XCTAssertEqual(result.pids, [])
        XCTAssertTrue(result.kills.isEmpty)
    }

    func testAnotherUsersConverterIsSpared() {
        XCTAssertEqual(sweep([snapshot(user: geteuid() &+ 1)]).pids, [])
    }

    func testAnotherProgramWithTheSameArgumentsIsSpared() {
        XCTAssertEqual(sweep([snapshot(path: "/usr/bin/ditto")]).pids, [])
        XCTAssertEqual(sweep([snapshot(path: "/opt/homebrew/bin/afconvert")]).pids, [])
    }

    func testAVisibleOutputIsSpared() {
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", "/Users/x/Book/01.m4a"])]).pids, [])
    }

    func testAHiddenOutputWithAnotherSuffixIsSpared() {
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", "/Users/x/Book/.hidden.m4a"])]).pids, [])
    }

    func testANameWithTheSuffixButNoLeadingDotIsSpared() {
        let output = "/Users/x/Book/01.\(uuid).audio-conversion.m4a"
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", output])]).pids, [])
    }

    func testTheBareSuffixAsANameIsSpared() {
        let output = "/Users/x/Book/\(ImportAudioConverter.temporarySuffix)"
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", output])]).pids, [])
    }

    func testNoArgumentsAreSpared() {
        XCTAssertEqual(sweep([snapshot(arguments: [])]).pids, [])
    }

    func testAnEmptyLastArgumentIsSpared() {
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", "in.ogg", ""])]).pids, [])
    }

    func testOnlyTheLastArgumentIsJudged() {
        // A temporary name earlier on the line does not make the process ours.
        let temporary = "/Users/x/Book/.01.\(uuid).audio-conversion.m4a"
        XCTAssertEqual(sweep([snapshot(arguments: ["afconvert", temporary, "/Users/x/Book/01.m4a"])]).pids, [])
    }

    // MARK: Several Together

    func testExactlyTheRightOnesOfAMixedListAreKilledOnceEachWithSigkill() {
        let processes = [
            snapshot(pid: 10),
            snapshot(pid: 11, parent: 4321),
            snapshot(pid: 12, path: "/usr/bin/say"),
            snapshot(pid: 13),
            snapshot(pid: 14, arguments: ["afconvert", "in.ogg", "out.m4a"]),
            snapshot(pid: 15, user: geteuid() &+ 1),
        ]
        let result = sweep(processes)
        XCTAssertEqual(result.pids, [10, 13])
        XCTAssertEqual(result.kills.map { $0.0 }, [10, 13])
        XCTAssertTrue(result.kills.allSatisfy { $0.1 == SIGKILL })
    }

    func testAnEmptyListKillsNothing() {
        let result = sweep([])
        XCTAssertEqual(result.pids, [])
        XCTAssertTrue(result.kills.isEmpty)
    }

    // MARK: The Argument Parser

    /// A KERN_PROCARGS2 buffer: argc, the path, padding, the arguments, then
    /// an environment.
    private func buffer(argc: Int32, path: String, padding: Int = 3, arguments: [String], environment: [String] = ["A=1"]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for argument in arguments + environment { bytes += Array(argument.utf8) + [0] }
        return bytes
    }

    func testTheParserReadsTheArgumentsAndIgnoresTheEnvironment() {
        let bytes = buffer(argc: 3, path: "/bin/sleep", arguments: ["sleep", "a b", "ü"])
        XCTAssertEqual(OrphanedConversionSweep.parseProcessArguments(bytes), ["sleep", "a b", "ü"])
    }

    func testTheParserKeepsAnEmptyArgumentInTheMiddleAndAtTheEnd() {
        let bytes = buffer(argc: 3, path: "/bin/x", arguments: ["x", "", ""])
        XCTAssertEqual(OrphanedConversionSweep.parseProcessArguments(bytes), ["x", "", ""])
    }

    func testTheParserRefusesShortAndBadBuffers() {
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments([]))
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments([1, 0]))
        // A negative argc.
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments(buffer(argc: -1, path: "/bin/x", arguments: ["x"])))
        // An argc larger than the arguments present.
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments(buffer(argc: 9, path: "/bin/x", arguments: ["x"], environment: [])))
        // An absurd argc.
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments(buffer(argc: Int32.max, path: "/bin/x", arguments: ["x"])))
        // A buffer cut inside an argument (no closing NUL).
        var cut = buffer(argc: 1, path: "/bin/x", arguments: ["xyz"], environment: [])
        cut.removeLast()
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments(cut))
        // Only a header, and a header with a path but no arguments.
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments([1, 0, 0, 0]))
        XCTAssertNil(OrphanedConversionSweep.parseProcessArguments([1, 0, 0, 0, 0x2F, 0x78]))
    }

    func testTheParserAcceptsAnArgcOfZero() {
        XCTAssertEqual(OrphanedConversionSweep.parseProcessArguments(buffer(argc: 0, path: "/bin/x", arguments: [])), [])
    }

    // MARK: The Lister, on Live Processes

    func testTheListerFindsTheTestHostItself() throws {
        let processes = OrphanedConversionSweep.runningProcesses()
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        XCTAssertFalse(me.path.isEmpty)
        XCTAssertEqual(me.parentPid, getppid())
        XCTAssertEqual(me.userID, geteuid())
        XCTAssertFalse(me.arguments.isEmpty)
        XCTAssertEqual(me.arguments.first.map { ($0 as NSString).lastPathComponent },
                       (me.path as NSString).lastPathComponent)
    }

    func testTheListerReadsAChildsPathParentAndLastArgument() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        sleepProcess = child
        let processes = OrphanedConversionSweep.runningProcesses()
        let listed = try XCTUnwrap(processes.first { $0.pid == child.processIdentifier })
        XCTAssertEqual(listed.path, "/bin/sleep")
        XCTAssertEqual(listed.parentPid, getpid())
        XCTAssertEqual(listed.arguments.last, "30")
    }

    func testTheListerSkipsAPidThatDoesNotExist() {
        // Pids stop far below Int32.max, so this one cannot be running.
        XCTAssertNil(OrphanedConversionSweep.snapshot(of: Int32.max - 1))
        XCTAssertNil(OrphanedConversionSweep.snapshot(of: -5))
    }

    func testTheListingIsQuickAndHoldsManyProcesses() {
        let start = Date()
        let processes = OrphanedConversionSweep.runningProcesses()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertGreaterThanOrEqual(processes.count, 10)
    }

    // MARK: At Launch

    func testSweepingInTheBackgroundDoesNothingInTheTestHost() {
        // The default for isHostedTest is the real runtime's, true here.
        XCTAssertTrue(TextMouthRuntime.current.isHostedTest)
        let listed = Flag()
        let killed = Flag()
        let fake = snapshot()
        OrphanedConversionSweep.sweepInBackground(
            lister: { listed.set(); return [fake] },
            kill: { _, _ in killed.set() })
        // Give a wrongly started background task time to run.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertFalse(listed.isSet)
        XCTAssertFalse(killed.isSet)
    }

    func testOutsideAHostedTestTheBackgroundSweepListsAndFinishes() {
        // An empty list: nothing is killed, and nothing is logged.
        let finished = expectation(description: "finished")
        let killed = Flag()
        OrphanedConversionSweep.sweepInBackground(
            isHostedTest: false,
            lister: { [] },
            kill: { _, _ in killed.set() },
            completion: { finished.fulfill() })
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(killed.isSet)
    }

    func testTheLogLineNamesTheCount() {
        XCTAssertEqual(OrphanedConversionSweep.logLine(killedCount: 2),
                       "OGG_ORPHAN_SWEPT: killed 2 leftover afconvert process(es)")
    }
}
