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
    /// The folder the afinfo file sweep looks in and the stand-in afinfo
    /// writes in: its own, new for every test, made when first used.
    private let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("OrphanedConversionSweepTests-\(UUID().uuidString)", isDirectory: true)

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
        try? FileManager.default.removeItem(at: sandbox)
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

    // MARK: afinfo: Helpers (review item 9)

    /// A snapshot of an afinfo that the sweep must kill, with any part
    /// changed by a test. `output` is the file it prints to (descriptor 1).
    private func afinfoSnapshot(
        pid: pid_t = 901,
        parent: pid_t = 1,
        user: uid_t = geteuid(),
        path: String = "/usr/bin/afinfo",
        output: String? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPid: parent, userID: user, path: path,
            arguments: ["afinfo", "-x", "-r", "/Users/x/Book/01.ac3"],
            standardOutputPath: output ?? "/private/var/folders/zl/T/.\(uuid).watched-output")
    }

    /// Makes the sandbox, and a regular file `name` in it last modified
    /// `age` seconds before `now`.
    private func makeFile(_ name: String, age: TimeInterval, now: Date) throws {
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let url = sandbox.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    /// The names in the sandbox, sorted.
    private func sandboxNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []).sorted()
    }

    /// The pids a `@Sendable` kill closure was given, safely.
    private final class KilledPids: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [pid_t] = []
        var all: [pid_t] { lock.lock(); defer { lock.unlock() }; return pids }
        func add(_ pid: pid_t) { lock.lock(); pids.append(pid); lock.unlock() }
    }

    // MARK: afinfo: The Process Rule

    func testAnOrphanedAfinfoPrintingToACapturedOutputIsKilled() {
        var kills: [(pid_t, Int32)] = []
        let pids = OrphanedConversionSweep.sweepAfinfo(processes: [afinfoSnapshot()]) { kills.append(($0, $1)) }
        XCTAssertEqual(pids, [901])
        XCTAssertEqual(kills.count, 1)
        XCTAssertEqual(kills.first?.0, 901)
        XCTAssertEqual(kills.first?.1, SIGKILL)
    }

    /// Every one of the rules is needed: a change to any part spares it.
    func testAnAfinfoBreakingAnyRuleIsSpared() {
        let spared: [ProcessSnapshot] = [
            afinfoSnapshot(parent: 4_321),                                   // its parent lives
            afinfoSnapshot(user: geteuid() &+ 1),                            // another user's
            afinfoSnapshot(path: "/usr/bin/afconvert"),                      // not afinfo
            afinfoSnapshot(path: "/opt/homebrew/bin/afinfo"),                // another afinfo
            ProcessSnapshot(pid: 5, parentPid: 1, userID: geteuid(), path: "/usr/bin/afinfo",
                            arguments: ["afinfo", "x.ac3"]),                 // prints to no file
            afinfoSnapshot(output: "/tmp/report.txt"),                       // prints elsewhere
            afinfoSnapshot(output: "/tmp/.\(uuid).textutil.html"),          // textutil's name
            afinfoSnapshot(output: "/tmp/.not-a-uuid.watched-output"),       // not a UUID
            afinfoSnapshot(output: "/tmp/\(uuid).watched-output"),          // not hidden
            afinfoSnapshot(output: "/tmp/..watched-output"),                 // nothing before the suffix
            afinfoSnapshot(output: "/tmp/.\(uuid).watched-output.bak"),     // something after it
        ]
        for process in spared {
            XCTAssertFalse(OrphanedConversionSweep.shouldKillAfinfo(process), "\(process)")
        }
        var kills = 0
        XCTAssertTrue(OrphanedConversionSweep.sweepAfinfo(processes: spared) { _, _ in kills += 1 }.isEmpty)
        XCTAssertEqual(kills, 0)
    }

    func testOnlyTheOrphanedAfinfosAreKilledFromAMixedList() {
        let list = [afinfoSnapshot(pid: 1_001), afinfoSnapshot(pid: 1_002, parent: 77), afinfoSnapshot(pid: 1_003)]
        XCTAssertEqual(OrphanedConversionSweep.sweepAfinfo(processes: list) { _, _ in }, [1_001, 1_003])
    }

    func testTheCapturedOutputNameRule() {
        XCTAssertTrue(OrphanedConversionSweep.isCapturedOutputName(".\(uuid).watched-output"))
        XCTAssertTrue(OrphanedConversionSweep.isCapturedOutputName(".\(uuid.lowercased()).watched-output"))
        for name in ["", ".watched-output", "..watched-output", "\(uuid).watched-output",
                     ".\(uuid).watched-outputs", ".x.watched-output", ".\(uuid).textutil.html"] {
            XCTAssertFalse(OrphanedConversionSweep.isCapturedOutputName(name), name)
        }
    }

    /// The file descriptor read for a real process: `sleep` started with its
    /// output in a captured-output file is seen printing to it, and a process
    /// that is not afinfo is not asked.
    func testTheStandardOutputOfARealProcessIsRead() throws {
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let file = sandbox.appendingPathComponent(".\(uuid).watched-output")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = handle
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        sleepProcess = child
        let found = OrphanedConversionSweep.standardOutputPath(of: child.processIdentifier)
        // The system may resolve /var to /private/var, so compare the name.
        XCTAssertEqual(found.map { ($0 as NSString).lastPathComponent }, ".\(uuid).watched-output")
        // A snapshot of a program other than afinfo never carries the path.
        let snapshot = try XCTUnwrap(OrphanedConversionSweep.snapshot(of: child.processIdentifier))
        XCTAssertNil(snapshot.standardOutputPath)
        // A process that has gone has none.
        child.terminate()
        child.waitUntilExit()
        XCTAssertNil(OrphanedConversionSweep.standardOutputPath(of: child.processIdentifier))
    }

    // MARK: afinfo: The Leftover Files

    func testOutputFilesOlderThanAnHourAreRemovedAndNewerOnesKept() throws {
        let now = Date()
        let old = ".\(uuid).watched-output"
        let newer = ".\(UUID().uuidString).watched-output"
        try makeFile(old, age: 3_601, now: now)
        try makeFile(newer, age: 3_599, now: now)
        // Old files that are not captured outputs stay.
        try makeFile("notes.txt", age: 90_000, now: now)
        try makeFile(".\(uuid).textutil.html", age: 90_000, now: now)
        try makeFile(".\(uuid).watched-output.bak", age: 90_000, now: now)
        XCTAssertEqual(OrphanedConversionSweep.sweepCapturedOutputFiles(in: sandbox, now: now), 1)
        XCTAssertEqual(sandboxNames(), [".\(uuid).textutil.html", ".\(uuid).watched-output.bak", newer, "notes.txt"].sorted())
    }

    /// A folder named like an output file is not a file of ours.
    func testAFolderNamedLikeAnOutputFileIsKept() throws {
        let now = Date()
        let name = ".\(uuid).watched-output"
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90_000)],
            ofItemAtPath: sandbox.appendingPathComponent(name).path)
        XCTAssertEqual(OrphanedConversionSweep.sweepCapturedOutputFiles(in: sandbox, now: now), 0)
        XCTAssertEqual(sandboxNames(), [name])
    }

    /// A missing folder is not an error.
    func testSweepingAFolderThatIsNotThereRemovesNothing() {
        XCTAssertEqual(OrphanedConversionSweep.sweepCapturedOutputFiles(in: sandbox), 0)
    }

    // MARK: afinfo: At Launch

    func testTheAfinfoLogLineNamesBothCounts() {
        XCTAssertEqual(
            OrphanedConversionSweep.afinfoLogLine(killedCount: 2, removedFileCount: 3),
            "AFINFO_LEFTOVERS_SWEPT: killed 2 orphaned afinfo process(es), removed 3 old output file(s)")
    }

    func testTheAfinfoSweepDoesNothingInTheTestHost() {
        XCTAssertTrue(TextMouthRuntime.current.isHostedTest)
        let listed = Flag()
        OrphanedConversionSweep.sweepAfinfoInBackground(
            lister: { listed.set(); return [] },
            root: sandbox)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertFalse(listed.isSet)
    }

    /// Outside a hosted test the background sweep kills the orphan and
    /// removes the old file, in the sandbox only.
    func testTheBackgroundAfinfoSweepKillsTheOrphanAndRemovesTheOldFile() throws {
        let now = Date()
        try makeFile(".\(uuid).watched-output", age: 7_200, now: now)
        let killed = KilledPids()
        let finished = expectation(description: "finished")
        let listed = [afinfoSnapshot(pid: 4_001), afinfoSnapshot(pid: 4_002, parent: 9)]
        OrphanedConversionSweep.sweepAfinfoInBackground(
            isHostedTest: false,
            lister: { listed },
            kill: { pid, _ in killed.add(pid) },
            root: sandbox,
            now: { now },
            completion: { finished.fulfill() })
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(killed.all, [4_001])
        XCTAssertEqual(sandboxNames(), [])
    }
}
