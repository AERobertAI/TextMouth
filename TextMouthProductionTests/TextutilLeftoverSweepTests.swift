import Darwin
import XCTest
@testable import TextMouth

/// The launch sweep for what a force-quit or a crash leaves of a textutil
/// conversion: an orphaned `textutil` process and the old
/// `TextMouth-textutil-<UUID>` working folders. The process rule is tested on
/// fabricated snapshots, so no real process is ever killed; the folder sweep
/// runs in a sandbox root of the test's own, never in the real temporary
/// directory.
final class TextutilLeftoverSweepTests: XCTestCase {

    private let uuid = "6F1C2B7E-0C55-4B1B-9D5F-0A1B2C3D4E5F"
    /// The folder the folder sweep looks in: its own, new for every test.
    private let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextutilLeftoverSweepTests-\(UUID().uuidString)", isDirectory: true)

    /// A flag a background closure may set, safely.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Makes the sandbox root the folder sweep looks in.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    /// Removes the sandbox.
    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    // MARK: Helpers: the process rule

    /// A snapshot that the sweep must kill, with any part changed by a test.
    private func snapshot(
        pid: pid_t = 900,
        parent: pid_t = 1,
        user: uid_t = geteuid(),
        path: String = "/usr/bin/textutil",
        arguments: [String]? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPid: parent, userID: user, path: path,
            arguments: arguments ?? Self.arguments(output: "/tmp/TextMouth-textutil-X/.\(uuid).textutil.html"))
    }

    /// The command line `TextutilConverter` builds, with `output` as the file
    /// it writes (the real arguments, so the rule is tested against the real
    /// shape of the command).
    private static func arguments(output: String) -> [String] {
        ["textutil"] + TextutilConverter.arguments(
            input: URL(fileURLWithPath: "/Users/x/Book.doc"), format: .doc, output: URL(fileURLWithPath: output))
    }

    /// The pids `sweepTextutil` returns for `processes`, with the kill calls recorded.
    private func sweep(_ processes: [ProcessSnapshot]) -> (pids: [pid_t], kills: [(pid_t, Int32)]) {
        var kills: [(pid_t, Int32)] = []
        let pids = OrphanedConversionSweep.sweepTextutil(processes: processes) { kills.append(($0, $1)) }
        return (pids, kills)
    }

    // MARK: Helpers: the folder sweep

    /// Makes `name` in the sandbox as a folder, or a file, last modified `age`
    /// seconds before `now`, with a file inside a folder; returns its URL.
    @discardableResult
    private func make(_ name: String, isFolder: Bool = true, age: TimeInterval, now: Date) throws -> URL {
        let url = sandbox.appendingPathComponent(name, isDirectory: isFolder)
        if isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent(".\(uuid).textutil.html"))
        } else {
            try Data("x".utf8).write(to: url)
        }
        // Set the date last: writing the file inside changed the folder's.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private let hour: TimeInterval = 3600

    // MARK: Killed

    func testAnOrphanedTextutilWritingATextMouthOutputIsKilled() {
        let result = sweep([snapshot()])
        XCTAssertEqual(result.pids, [900])
        XCTAssertEqual(result.kills.count, 1)
        XCTAssertEqual(result.kills.first?.0, 900)
        XCTAssertEqual(result.kills.first?.1, SIGKILL)
    }

    func testOnlyTheOrphansOfSeveralAreKilled() {
        let result = sweep([snapshot(pid: 901), snapshot(pid: 902, parent: 4321), snapshot(pid: 903)])
        XCTAssertEqual(result.pids, [901, 903])
    }

    // MARK: Spared

    func testATextutilWhoseParentLivesIsNotKilled() {
        XCTAssertTrue(sweep([snapshot(parent: 4321)]).pids.isEmpty)
        // Parent pid 0 (the kernel) is not launchd either.
        XCTAssertTrue(sweep([snapshot(parent: 0)]).pids.isEmpty)
    }

    func testAnotherUsersTextutilIsNotKilled() {
        XCTAssertTrue(sweep([snapshot(user: geteuid() &+ 1)]).pids.isEmpty)
    }

    func testAnOutputThatIsNotHiddenIsNotKilled() {
        let plain = Self.arguments(output: "/tmp/\(uuid).textutil.html")
        XCTAssertTrue(sweep([snapshot(arguments: plain)]).pids.isEmpty)
    }

    func testAnotherSuffixIsNotKilled() {
        let other = Self.arguments(output: "/tmp/.\(uuid).textutil.rtf")
        XCTAssertTrue(sweep([snapshot(arguments: other)]).pids.isEmpty)
    }

    func testTheSuffixAloneIsNotAName() {
        XCTAssertFalse(OrphanedConversionSweep.isTextutilTemporaryOutputName(".textutil.html"))
        XCTAssertFalse(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/.textutil.html"))
        XCTAssertTrue(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/.a.textutil.html"))
    }

    func testAnotherProgramWithTheSameArgumentsIsNotKilled() {
        XCTAssertTrue(sweep([snapshot(path: "/usr/bin/afconvert")]).pids.isEmpty)
        XCTAssertTrue(sweep([snapshot(path: "/Applications/Other.app/Contents/MacOS/textutil")]).pids.isEmpty)
    }

    func testATextutilWithNoOutputArgumentIsNotKilled() {
        XCTAssertTrue(sweep([snapshot(arguments: ["textutil", "-convert", "html", "--", "a.doc"])]).pids.isEmpty)
        // "-output" as the last option, with no value after it.
        XCTAssertTrue(sweep([snapshot(arguments: ["textutil", "-output"])]).pids.isEmpty)
        XCTAssertTrue(sweep([snapshot(arguments: [])]).pids.isEmpty)
    }

    func testAnInputNamedLikeAnOutputIsNotTakenForOne() {
        // The user's own file, after "--", is named like a TextMouth output.
        // The real output (a user-chosen name) is what decides.
        let tricky = ["textutil", "-convert", "html", "-output", "/Users/x/mine.html",
                      "--", "-output", "/tmp/.\(uuid).textutil.html"]
        XCTAssertEqual(OrphanedConversionSweep.textutilOutputArgument(in: tricky), "/Users/x/mine.html")
        XCTAssertTrue(sweep([snapshot(arguments: tricky)]).pids.isEmpty)
        // And an "-output" only after "--" is not an option at all.
        let onlyAfter = ["textutil", "--", "-output", "/tmp/.\(uuid).textutil.html"]
        XCTAssertNil(OrphanedConversionSweep.textutilOutputArgument(in: onlyAfter))
        XCTAssertTrue(sweep([snapshot(arguments: onlyAfter)]).pids.isEmpty)
    }

    // MARK: Folders

    func testAnOldWorkingFolderIsRemovedWithItsHiddenOutput() throws {
        let now = Date()
        let old = try make("TextMouth-textutil-\(uuid)", age: hour + 60, now: now)
        let removed = OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(exists(old))
    }

    func testAFreshWorkingFolderIsKept() throws {
        let now = Date()
        // A conversion may be running in it: just under the hour, and new.
        let justUnder = try make("TextMouth-textutil-\(uuid)", age: hour - 60, now: now)
        let fresh = try make("TextMouth-textutil-\(UUID().uuidString)", age: 5, now: now)
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now), 0)
        XCTAssertTrue(exists(justUnder))
        XCTAssertTrue(exists(fresh))
    }

    func testAnOldFolderWithAnotherNameIsKept() throws {
        let now = Date()
        let names = [
            "Documents", "textutil-\(uuid)", "TextMouth-textutil-", "TextMouth-textutil-not-a-uuid",
            "TextMouth-textutil-\(uuid)-copy", "TextMouth-afconvert-\(uuid)", "textmouth-textutil-\(uuid)x",
        ]
        let kept = try names.map { try make($0, age: 10 * hour, now: now) }
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now), 0)
        for url in kept { XCTAssertTrue(exists(url), url.lastPathComponent) }
    }

    func testAnOldFileNamedLikeTheFolderIsKept() throws {
        let now = Date()
        let file = try make("TextMouth-textutil-\(uuid)", isFolder: false, age: 10 * hour, now: now)
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now), 0)
        XCTAssertTrue(exists(file))
    }

    func testASymbolicLinkNamedLikeTheFolderIsKeptAndItsTargetUntouched() throws {
        let now = Date()
        // A real, old folder that is not named like one of ours, and a link to it that is.
        let target = try make("Elsewhere", age: 10 * hour, now: now)
        let link = sandbox.appendingPathComponent("TextMouth-textutil-\(uuid)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now), 0)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(exists(target))
    }

    func testOnlyTheOldOnesOfSeveralAreRemovedAndCounted() throws {
        let now = Date()
        let oldA = try make("TextMouth-textutil-\(uuid)", age: 2 * hour, now: now)
        let oldB = try make("TextMouth-textutil-\(UUID().uuidString.lowercased())", age: 30 * hour, now: now)
        let fresh = try make("TextMouth-textutil-\(UUID().uuidString)", age: 60, now: now)
        let other = try make("KeepMe", age: 30 * hour, now: now)
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: sandbox, now: now), 2)
        XCTAssertFalse(exists(oldA))
        XCTAssertFalse(exists(oldB))
        XCTAssertTrue(exists(fresh))
        XCTAssertTrue(exists(other))
    }

    func testAMissingRootRemovesNothing() {
        let missing = sandbox.appendingPathComponent("not-there", isDirectory: true)
        XCTAssertEqual(OrphanedConversionSweep.sweepTextutilFolders(in: missing), 0)
    }

    // MARK: At Launch

    func testSweepingInTheBackgroundDoesNothingInTheTestHost() throws {
        // The default for isHostedTest is the real runtime's, true here.
        XCTAssertTrue(TextMouthRuntime.current.isHostedTest)
        let now = Date()
        let old = try make("TextMouth-textutil-\(uuid)", age: 10 * hour, now: now)
        let listed = Flag()
        let fake = snapshot()
        OrphanedConversionSweep.sweepTextutilInBackground(
            lister: { listed.set(); return [fake] },
            kill: { _, _ in listed.set() },
            root: sandbox)
        // Give a wrongly started background task time to run.
        let settle = expectation(description: "settle")
        settle.assertForOverFulfill = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertFalse(listed.isSet)
        XCTAssertTrue(exists(old))
    }

    func testOutsideAHostedTestTheBackgroundSweepKillsAndRemovesWhatTheRulesName() throws {
        let now = Date()
        let old = try make("TextMouth-textutil-\(uuid)", age: 10 * hour, now: now)
        let fresh = try make("TextMouth-textutil-\(UUID().uuidString)", age: 5, now: now)
        // A recording kill, safely shared with the background queue.
        final class Kills: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [pid_t] = []
            func add(_ pid: pid_t) { lock.lock(); recorded.append(pid); lock.unlock() }
            var pids: [pid_t] { lock.lock(); defer { lock.unlock() }; return recorded }
        }
        let kills = Kills()
        let doomed = snapshot(pid: 777)
        let spared = snapshot(pid: 778, parent: 4321)
        let finished = expectation(description: "finished")
        finished.assertForOverFulfill = false
        OrphanedConversionSweep.sweepTextutilInBackground(
            isHostedTest: false,
            lister: { [doomed, spared] },
            kill: { pid, _ in kills.add(pid) },
            root: sandbox,
            now: { now },
            completion: { finished.fulfill() })
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(kills.pids, [777])
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(fresh))
    }

    func testTheLogLineNamesBothCounts() {
        XCTAssertEqual(
            OrphanedConversionSweep.textutilLogLine(killedCount: 2, removedFolderCount: 3),
            "TEXTUTIL_LEFTOVERS_SWEPT: killed 2 orphaned textutil process(es), removed 3 old working folder(s)")
    }
}
