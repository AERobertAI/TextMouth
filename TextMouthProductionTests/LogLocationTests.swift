import XCTest
@testable import TextMouth

/// Where the diagnostic logs are written (the user's decision of October 3):
/// inside the data directory by default, or in this Mac's Logs folder, as
/// Storage settings choose; the one resolution of the folder
/// (`TextMouthPaths.logDestination`); and the log writer going to this
/// Mac's Logs folder while the data directory can't take lines, saying so,
/// and coming back. The writers here are the tests' own, over folders of
/// their own, so nothing here changes the app's logs or its data directory.
final class LogLocationTests: XCTestCase {

    // MARK: - The Resolution

    /// Under the choice of this Mac's Logs folder, lines go there, whatever
    /// state the data directory is in.
    func testTheMachineChoiceAlwaysWritesInThisMacsFolder() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogMachineChoice"))

        for isUnavailable in [false, true] {
            XCTAssertEqual(
                world.destination(for: .machine, isUnavailable: isUnavailable),
                LogDestination(folder: world.thisMac, reason: .thisMac)
            )
        }
    }

    /// Under the default choice, lines go to the data directory's Logs
    /// folder while the library can be used and that folder is there.
    func testTheDataDirectoryChoiceWritesInItsLogsFolder() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogDataChoice"))

        XCTAssertEqual(
            world.destination(for: .dataDirectory),
            LogDestination(folder: world.dataLogs, reason: .dataDirectory)
        )
    }

    /// While the library model has found the data directory unavailable,
    /// lines go to this Mac's Logs folder, though the folder is there.
    func testWhileTheLibraryIsUnavailableLinesGoToThisMac() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogUnavailable"))

        XCTAssertEqual(
            world.destination(for: .dataDirectory, isUnavailable: true),
            LogDestination(folder: world.thisMac, reason: .fallback(.libraryUnavailable))
        )
    }

    /// A missing data directory, a missing Logs folder, and a file where
    /// the Logs folder should be each send lines to this Mac's Logs folder,
    /// each with its own reason, and the resolution makes nothing.
    func testWhatTheDataDirectoryLacksSendsLinesToThisMac() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogLacks"))

        try FileManager.default.removeItem(at: world.dataLogs)
        XCTAssertEqual(world.destination(for: .dataDirectory).reason, .fallback(.logsFolderMissing))
        try Data("a file".utf8).write(to: world.dataLogs)
        XCTAssertEqual(
            world.destination(for: .dataDirectory).reason,
            .fallback(.logsFolderUnusable("it is a file, not a folder"))
        )
        try FileManager.default.removeItem(at: world.dataDirectory)
        XCTAssertEqual(world.destination(for: .dataDirectory).reason, .fallback(.dataDirectoryMissing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.dataDirectory.path))
    }

    // MARK: - The Writer

    /// While the library is unavailable, lines go to this Mac's Logs folder
    /// after one line there saying why; once it is back, they go to the data
    /// directory's Logs folder again, after one line there saying so.
    func testLinesGoToThisMacWhileTheLibraryIsAwayAndComeBackAfterward() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogAway"))

        world.write("before")
        world.unavailable.value = true
        world.write("while away")
        world.write("still away")
        world.unavailable.value = false
        world.write("after")

        XCTAssertEqual(world.messages(in: world.dataLogs), [
            "before",
            "LOG_LOCATION: writing the logs in the data directory's Logs folder again; "
                + "the lines written while it couldn't take them are in this Mac's Logs folder, ~/Library/Logs/TextMouth",
            "after",
        ])
        XCTAssertEqual(world.messages(in: world.thisMac), [
            "LOG_LOCATION: writing the logs in this Mac's Logs folder, ~/Library/Logs/TextMouth, because the library in "
                + "\(world.shortName) isn't available; they go back to the data directory's Logs folder once it can take them",
            "while away",
            "still away",
        ])
    }

    /// A data directory that went missing, as an unplugged drive's does, is
    /// never made again by a line: the line goes to this Mac's Logs folder,
    /// after one line saying why. The first line of all says why too.
    func testALineNeverMakesAMissingDataDirectory() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogUnplugged"))
        try FileManager.default.removeItem(at: world.dataDirectory)

        world.write("unplugged")

        XCTAssertFalse(FileManager.default.fileExists(atPath: world.dataDirectory.path), "a line made the data directory")
        XCTAssertEqual(world.messages(in: world.thisMac), [
            "LOG_LOCATION: writing the logs in this Mac's Logs folder, ~/Library/Logs/TextMouth, because the data directory "
                + "\(world.shortName) is missing; they go back to the data directory's Logs folder once it can take them",
            "unplugged",
        ])
    }

    /// A line the data directory's Logs folder refuses, as a read-only log
    /// or a full disk refuses one, goes to this Mac's Logs folder, saying
    /// why, and the next line that can go back does.
    func testALineTheDataDirectoryRefusesGoesToThisMac() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogRefused"))
        let log = world.dataLogs.appendingPathComponent(DiagnosticLog.File.debug.rawValue)
        try "locked\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        }

        world.write("refused")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        world.write("taken")

        XCTAssertEqual(world.messages(in: world.thisMac), [
            "LOG_LOCATION: writing the logs in this Mac's Logs folder, ~/Library/Logs/TextMouth, because the Logs folder in "
                + "\(world.shortName) can't be written: Permission denied; "
                + "they go back to the data directory's Logs folder once it can take them",
            "refused",
        ])
        XCTAssertEqual(Array(world.messages(in: world.dataLogs).dropFirst()), [
            "LOG_LOCATION: writing the logs in the data directory's Logs folder again; "
                + "the lines written while it couldn't take them are in this Mac's Logs folder, ~/Library/Logs/TextMouth",
            "taken",
        ])
    }

    /// A change of the choice takes effect for the next line written, with
    /// one line saying so where lines go then; logs already written stay
    /// where they are.
    func testAChangeOfTheChoiceTakesEffectForTheNextLine() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogChoiceChange"))

        world.write("in the data directory")
        world.location.value = .machine
        world.write("on this Mac")
        world.location.value = .dataDirectory
        world.write("back in the data directory")

        XCTAssertEqual(world.messages(in: world.dataLogs), [
            "in the data directory",
            "LOG_LOCATION: writing the logs in the data directory's Logs folder, as Storage settings ask; "
                + "logs written before stay in this Mac's Logs folder, ~/Library/Logs/TextMouth",
            "back in the data directory",
        ])
        XCTAssertEqual(world.messages(in: world.thisMac), [
            "LOG_LOCATION: writing the logs in this Mac's Logs folder, ~/Library/Logs/TextMouth, as Storage settings ask; "
                + "logs written before stay where they are",
            "on this Mac",
        ])
    }

    /// The sleep timer's and speech's logs follow the same folder as the
    /// debug log, which alone takes the lines saying where lines go.
    func testEveryLogFollowsTheFolderAndOnlyTheDebugLogSaysWhy() throws {
        let world = try LogWorld(in: makeSandboxDirectory("LogEveryFile"))
        world.unavailable.value = true

        world.write("a timer line", to: .sleepTimer)
        world.write("a speech line", to: .speechTransitions)

        XCTAssertEqual(world.messages(of: .sleepTimer, in: world.thisMac), ["a timer line"])
        XCTAssertEqual(world.messages(of: .speechTransitions, in: world.thisMac), ["a speech line"])
        XCTAssertEqual(world.messages(in: world.thisMac).count, 1, "the debug log holds the one line saying why")
        XCTAssertTrue(world.messages(in: world.thisMac)[0].hasPrefix("LOG_LOCATION: "))
        XCTAssertEqual(world.messages(of: .sleepTimer, in: world.dataLogs), [])
    }

    // MARK: - The Setting

    /// The setting is saved as "dataDirectory" or "machine", and the data
    /// directory is the default.
    func testTheDataDirectoryIsTheDefaultOfTwoChoices() {
        XCTAssertEqual(SettingsPolicy.logLocation.key, "logLocation")
        XCTAssertEqual(SettingsPolicy.logLocation.defaultValue, .dataDirectory)
        XCTAssertEqual(SettingsPolicy.logLocation.allowedRawValues, ["dataDirectory", "machine"])
        XCTAssertEqual(LogLocation.preference.key, SettingsPolicy.logLocation.key)
    }

    /// The preference reads the choice saved, and the default for a missing
    /// value or one it can't use: a choice a later version may add, another
    /// spelling, or a number `defaults write` stored.
    func testThePreferenceReadsTheSavedChoiceOrTheDefault() {
        let store = makeSandboxedPreferences("log-location")
        XCTAssertEqual(LogLocation.preference.read(from: store), .dataDirectory)

        LogLocation.preference.write(.machine, to: store)
        XCTAssertEqual(store.string(forKey: "logLocation"), "machine")
        XCTAssertEqual(LogLocation.preference.read(from: store), .machine)

        for unusable: Any in ["cloud", "", "Machine", 1] {
            store.set(unusable, forKey: "logLocation")
            XCTAssertEqual(LogLocation.preference.read(from: store), .dataDirectory, "\(unusable)")
        }
    }
}

// MARK: - The Fixture

/// A log writer of a test's own, over a data directory holding its Logs
/// folder and a folder standing for this Mac's Logs folder, not made yet,
/// both inside a scratch folder. Storage settings' choice and the library
/// model's gate are the test's to change between lines.
private struct LogWorld {
    /// The data directory.
    let dataDirectory: URL
    /// The data directory's Logs folder.
    let dataLogs: URL
    /// The folder standing for this Mac's ~/Library/Logs/TextMouth.
    let thisMac: URL
    /// Storage settings' choice, as the writer reads it.
    let location: LockedValue<LogLocation>
    /// Whether the library model found the data directory unavailable.
    let unavailable: LockedValue<Bool>
    /// The writer.
    let writer: LogWriter

    /// A world inside the folder `scratch`, the default choice in force.
    init(in scratch: URL) throws {
        let dataDirectory = scratch.appendingPathComponent("Library Data", isDirectory: true)
        let thisMac = scratch.appendingPathComponent("This Mac/Logs/TextMouth", isDirectory: true)
        let location = LockedValue(LogLocation.dataDirectory)
        let unavailable = LockedValue(false)
        self.dataDirectory = dataDirectory
        dataLogs = dataDirectory.appendingPathComponent(TextMouthPaths.logsFolderName, isDirectory: true)
        self.thisMac = thisMac
        self.location = location
        self.unavailable = unavailable
        writer = LogWriter(environment: LogWriter.Environment(
            location: { location.value },
            dataDirectory: { dataDirectory },
            isUnavailable: { _ in unavailable.value },
            thisMacsFolder: { thisMac }
        ))
        try FileManager.default.createDirectory(at: dataLogs, withIntermediateDirectories: true)
    }

    /// How log lines name the data directory.
    var shortName: String {
        DataDirectoryPaths.shortName(of: dataDirectory)
    }

    /// Where lines go under `location`, the library model having found the
    /// data directory unavailable when `isUnavailable`.
    func destination(for location: LogLocation, isUnavailable: Bool = false) -> LogDestination {
        TextMouthPaths.logDestination(
            for: location,
            dataDirectory: dataDirectory,
            thisMacsFolder: thisMac,
            isUnavailable: { _ in isUnavailable }
        )
    }

    /// Writes `message` to the log `file`, and waits until it is written.
    func write(_ message: String, to file: DiagnosticLog.File = .debug) {
        writer.append(message, to: file)
        writer.flush()
    }

    /// The messages of the log `file` in `folder`, oldest first.
    func messages(of file: DiagnosticLog.File = .debug, in folder: URL) -> [String] {
        logMessages(of: file, in: folder)
    }
}
