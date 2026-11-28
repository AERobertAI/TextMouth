import Combine
import XCTest
@testable import TextMouth

/// The person's own interface lines in force (FR39 phase 10, steps 3 and 5): `interface_text.json` read once the library is
/// open, followed through the shared file watcher, applied to the engine, logged, and never written by anything but Edit
/// Interface Text…. Every test uses an engine over tables in memory and a file in a folder of its own inside the isolated
/// test root, never the real data directory, and every wait has a limit.
@MainActor
final class InterfaceTextOverridesTests: XCTestCase {
    // MARK: - Support

    /// The pack the tests read against.
    private static let lines: [String: [String: String]] = [
        "common.sleepTimer": ["en": "Sleep Timer", "es": "Temporizador de apagado"],
        "feed.opening": ["en": "Opening %@, part %lld", "es": "Abriendo %@, parte %lld"],
    ]

    /// What a service reported: the log lines, and the times the windows were told to read their lines again.
    private final class Record {
        var log: [String] = []
        var changes = 0
    }

    /// A service over a pack in memory and the file at `url`, with a short quiet period; stopped when the test ends.
    private func makeService(
        reading url: @escaping @MainActor () -> URL,
        record: Record = Record(),
        isUnavailable: @escaping @MainActor () -> Bool = { false }
    ) -> (service: InterfaceTextOverrides, engine: InterfaceTextEngine, record: Record) {
        let engine = makeInterfaceTextEngine(Self.lines, log: InterfaceTextReportLog())
        let service = InterfaceTextOverrides(
            engine: engine,
            fileURL: url,
            isUnavailable: isUnavailable,
            linesDidChange: { record.changes += 1 },
            log: { record.log.append($0) },
            quietPeriod: .milliseconds(60),
            // Short, so that a test can write a file after the watcher's own looks for it are over.
            retryDelays: [.milliseconds(20)]
        )
        addTeardownBlock { service.stop() }
        return (service, engine, record)
    }

    /// A file's place in a folder of this test's own; the folder is removed when the test ends.
    private func makeFileURL() throws -> URL {
        let directory = TextMouthPaths.root.appendingPathComponent("InterfaceTextOverridesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(TextMouthPaths.interfaceTextFileName)
    }

    /// The bytes of a file holding `lines` for Spanish.
    private func data(_ lines: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "languages": ["es": ["lines": lines]]])
    }

    /// What Edit's fill comes to, waited for by spinning the run loop as the other tests of this class do (the fill runs on a
    /// background queue and answers on the main actor; a test that is itself async and then spins the run loop would starve
    /// the reads it waits for).
    private func fill(_ service: InterfaceTextOverrides, language: String) -> InterfaceTextOverrides.FillResult {
        final class Answer { var result: InterfaceTextOverrides.FillResult? }
        let answer = Answer()
        Task { @MainActor in answer.result = await service.fillFileForEditing(language: language) }
        XCTAssertTrue(waitUntil(timeout: 5) { answer.result != nil }, "the fill never answered")
        return answer.result ?? .leftAsItIs
    }

    /// The Spanish text of the sleep timer's title now.
    private func sleepTimer(_ engine: InterfaceTextEngine) -> String {
        interfaceLine(engine, "common.sleepTimer", "Sleep Timer")
    }

    // MARK: - Reading and following

    /// A file present at the start is read, and its line reaches a lookup, within a bounded wait; the windows are told once.
    func testAFileThereAtTheStartIsReadAndApplied() throws {
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        let (service, engine, record) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })
        XCTAssertEqual(record.changes, 1)
        XCTAssertEqual(service.outcome.inUse.count, 1)
    }

    /// A change in the sandbox's data folder, noticed by the watcher, reaches a lookup within a bounded wait, and so does
    /// the file's going away.
    func testAWatchedChangeReachesALookup() throws {
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Uno"]]).write(to: url)
        let (service, engine, _) = makeService(reading: { url })
        service.start()
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Uno" })

        // An editor's atomic save, then a write in place to the new file.
        try data(["common.sleepTimer": ["text": "Dos"]]).write(to: url, options: .atomic)
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Dos" })
        try data(["common.sleepTimer": ["text": "Tres"]]).write(to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Tres" })

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador de apagado" })
        XCTAssertEqual(service.outcome, .empty)
    }

    /// A file the person makes while the app runs, with no watcher on it yet, is found when the app becomes active.
    func testAFileMadeLaterIsFoundWhenTheAppBecomesActive() throws {
        let url = try makeFileURL()
        let (service, engine, _) = makeService(reading: { url })
        let center = NotificationCenter()
        service.start(observing: center)
        // Past the watcher's looks for a file that is not there (20 ms, once), so only the activation can find it.
        _ = waitUntil(timeout: 0.5) { false }
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado", "nothing but the activation finds the file")

        center.post(name: PlatformApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })
    }

    /// A lookup takes the person's line, and the pack's text for a line left alone or not in the file.
    func testALookupTakesTheOwnLineAndThePacksOtherwise() throws {
        let url = try makeFileURL()
        try data([
            "common.sleepTimer": ["text": "Temporizador", "base": "Temporizador de apagado"],
            "feed.opening": ["text": "Abriendo %@, parte %lld", "base": "Abriendo %@, parte %lld"],
        ]).write(to: url)
        let (service, engine, _) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })
        XCTAssertEqual(interfaceLine(engine, "feed.opening", "Opening \("Atlas"), part \(number: 2)"), "Abriendo Atlas, parte 2")
        XCTAssertEqual(service.outcome.unchanged, 1)
    }

    /// A file only in the cloud, or a pack that is not there, changes nothing; the library's launch hook reads the file once it
    /// has come.
    func testFileMayHaveArrivedReadsTheFile() throws {
        let url = try makeFileURL()
        let (service, engine, _) = makeService(reading: { url })
        service.start()
        _ = waitUntil(timeout: 0.5) { false }
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado", "nothing but the arrival finds the file")

        service.fileMayHaveArrived()

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })
    }

    /// A move of the data folder reads the file at the new place.
    func testAMoveOfTheDataFolderReadsTheFileAtTheNewPlace() throws {
        let first = try makeFileURL()
        let second = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Del primero"]]).write(to: first)
        try data(["common.sleepTimer": ["text": "Del segundo"]]).write(to: second)
        var current = first
        let (service, engine, _) = makeService(reading: { current })
        let center = NotificationCenter()
        service.start(observing: center)
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Del primero" })

        current = second
        center.post(name: .dataDirectoryDidMove, object: nil)

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Del segundo" })
        // The watcher follows the new file: a later write there is noticed too.
        try data(["common.sleepTimer": ["text": "Del segundo, de nuevo"]]).write(to: second)
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Del segundo, de nuevo" })
    }

    /// While the data directory is unavailable nothing is read.
    func testNothingIsReadWhileTheDataDirectoryIsUnavailable() throws {
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        let (service, engine, record) = makeService(reading: { url }, isUnavailable: { true })

        service.start()
        _ = waitUntil(timeout: 0.5) { false }

        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado")
        XCTAssertEqual(record.log, [])
    }

    // MARK: - Writing

    /// A launch writes nothing to the file: with no file there is still none, and a file there keeps its bytes and its
    /// modification date, however long the watcher runs and whatever it finds.
    func testALaunchWritesNothingToTheFile() throws {
        let missing = try makeFileURL()
        let (first, _, _) = makeService(reading: { missing })
        first.start()
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let present = try makeFileURL()
        let bytes = try data(["common.sleepTimer": ["text": "Temporizador"], "retired.line": ["text": "x"]])
        try bytes.write(to: present)
        let before = try FileManager.default.attributesOfItem(atPath: present.path)[.modificationDate] as? Date
        let (second, _, _) = makeService(reading: { present })
        second.start()
        _ = waitUntil(timeout: 0.5) { false }

        XCTAssertEqual(try Data(contentsOf: present), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: present.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: present.deletingLastPathComponent().path), [present.lastPathComponent])
    }

    /// Edit Interface Text… fills the file when there is none, with every line of the interface language as the pack has it,
    /// and nothing applies (every line equals its base).
    func testEditFillsAMissingFileOnRequest() throws {
        let url = try makeFileURL()
        let (service, engine, _) = makeService(reading: { url })
        service.start()

        let filled = fill(service, language: "es")
        XCTAssertEqual(filled, .written)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let lines = try XCTUnwrap(((root["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])
        XCTAssertEqual(lines["common.sleepTimer"]?["text"] as? String, "Temporizador de apagado")
        XCTAssertEqual(lines["common.sleepTimer"]?["base"] as? String, "Temporizador de apagado")
        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.unchanged == 2 })
        XCTAssertEqual(service.outcome.inUse, [])
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado")
    }

    /// A line the person then edits in the filled file applies, and the file keeps what it said for the other lines.
    func testALineEditedInTheFilledFileApplies() throws {
        let url = try makeFileURL()
        let (service, engine, _) = makeService(reading: { url })
        service.start()
        let filled = fill(service, language: "es")
        XCTAssertEqual(filled, .written)
        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.unchanged == 2 })

        // The person edits one text in their editor.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var languages = try XCTUnwrap(root["languages"] as? [String: Any])
        var spanish = try XCTUnwrap(languages["es"] as? [String: Any])
        var lines = try XCTUnwrap(spanish["lines"] as? [String: [String: Any]])
        lines["common.sleepTimer"]?["text"] = "Temporizador"
        spanish["lines"] = lines
        languages["es"] = spanish
        root["languages"] = languages
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })
        XCTAssertEqual(service.outcome.inUse.count, 1)
        XCTAssertEqual(service.outcome.unchanged, 1)
    }

    /// A file that has the language, or that the person is mending, is left as it is; a file that lacks it gets it.
    func testEditLeavesAFileThatHasTheLanguage() throws {
        let url = try makeFileURL()
        let bytes = try data(["common.sleepTimer": ["text": "Temporizador"]])
        try bytes.write(to: url)
        let (service, _, _) = makeService(reading: { url })

        let left = fill(service, language: "es")
        XCTAssertEqual(left, .leftAsItIs)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        let added = fill(service, language: "en")
        XCTAssertEqual(added, .written)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set((root["languages"] as? [String: Any])?.keys.map { $0 } ?? []), ["es", "en"])
    }

    /// Nothing is written while the data directory is unavailable.
    func testEditWritesNothingWhileTheDataDirectoryIsUnavailable() throws {
        let url = try makeFileURL()
        let (service, _, _) = makeService(reading: { url }, isUnavailable: { true })

        let refused = fill(service, language: "es")
        guard case .failed = refused else { return XCTFail("a fill was not refused") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Export writes the language's lines as they read now, the person's own marked.
    func testExportCarriesTheOwnLinesMarked() throws {
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        let (service, engine, _) = makeService(reading: { url })
        service.start()
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })

        let exported = try XCTUnwrap(service.exportData(language: "es"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let lines = try XCTUnwrap(((root["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])

        XCTAssertEqual(lines["common.sleepTimer"]?["text"] as? String, "Temporizador")
        XCTAssertEqual(lines["common.sleepTimer"]?["changed"] as? Bool, true)
        XCTAssertEqual(lines["feed.opening"]?["text"] as? String, "Abriendo %@, parte %lld")
        XCTAssertNil(lines["feed.opening"]?["changed"])
        XCTAssertEqual(InterfaceTextOverrides.exportFileName(language: "es"), "interface_text-es.json")
    }

    // MARK: - The log

    /// One INTERFACE_TEXT_LOADED line with the counts, and one INTERFACE_TEXT_IGNORED line for each ignored line, in
    /// English, holding IDs and language codes and never a line's text.
    func testTheLogHoldsCountsAndEachIgnoredLineButNoText() throws {
        let url = try makeFileURL()
        try data([
            "common.sleepTimer": ["text": "Temporizador secreto"],
            "feed.opening": ["text": "Abriendo %s"],
            "common.nonsense": ["text": "Palabras privadas"],
        ]).write(to: url)
        let (service, _, record) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { record.log.count == 3 })
        XCTAssertEqual(record.log.first, "INTERFACE_TEXT_LOADED: 1 lines in use, 2 ignored, 0 left alone")
        let ignored = Set(record.log.dropFirst())
        XCTAssertEqual(ignored, [
            "INTERFACE_TEXT_IGNORED: line feed.opening in es: it has a specifier other than the five, or a lone percent sign",
            "INTERFACE_TEXT_IGNORED: line (15 characters) in es: TextMouth has no line with that ID",
        ])
        for line in record.log {
            XCTAssertFalse(line.contains("secreto") || line.contains("privadas"), line)
        }
        // Reading the same bytes again logs nothing more.
        service.reload()
        _ = waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(record.log.count, 3)
    }

    /// A file that is not this shape is ignored whole, with one line.
    func testAFileThatIsNotThisShapeIsLoggedOnce() throws {
        let url = try makeFileURL()
        try Data("not json".utf8).write(to: url)
        let (service, engine, record) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { record.log.count == 2 })
        XCTAssertEqual(record.log[0], "INTERFACE_TEXT_LOADED: 0 lines in use, 0 ignored, 0 left alone, the whole file ignored")
        XCTAssertEqual(record.log[1], "INTERFACE_TEXT_IGNORED: the whole file: the file is not JSON")
        XCTAssertEqual(service.outcome.fileProblem, .notJSON)
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado")
    }

    /// A key of the person's file that the app does not know is the person's own text: it is logged as its length only.
    func testAKeyTheAppDoesNotKnowIsLoggedAsALength() {
        XCTAssertEqual(InterfaceTextOverrides.logged("common.sleepTimer", isKnown: true), "common.sleepTimer")
        XCTAssertEqual(InterfaceTextOverrides.logged("pt-BR", isKnown: true), "pt-BR")
        XCTAssertEqual(InterfaceTextOverrides.logged("Temporizador", isKnown: false), "(12 characters)")
        XCTAssertEqual(InterfaceTextOverrides.logged("common.sleeptimer", isKnown: false), "(17 characters)")
    }

    /// A key typed as a word ("Temporizador" for an ID, "Klingon" for a language) never reaches the log, though it looks
    /// like an ID or a code: only keys the app knows do.
    func testTypedKeysNeverReachTheLog() throws {
        let url = try makeFileURL()
        try JSONSerialization.data(withJSONObject: ["version": 1, "languages": [
            "Klingon": ["lines": ["Temporizador": ["text": "Kronos"]]],
            "es": ["lines": ["Temporizador": ["text": "Kronos"], "common.sleepTimer": ["text": "ok"]]],
            // A key that begins like a carried language names it, and is the person's text after that.
            "es-my private note": ["lines": ["Otro": ["text": "x"]]],
        ]]).write(to: url)
        let (service, _, record) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { record.log.count == 4 })
        for line in record.log {
            XCTAssertFalse(line.contains("Klingon") || line.contains("Temporizador") || line.contains("private") || line.contains("Otro"), line)
        }
        XCTAssertTrue(record.log.contains("INTERFACE_TEXT_IGNORED: line (4 characters) in es: TextMouth has no line with that ID"), "\(record.log)")
        XCTAssertTrue(record.log.contains("INTERFACE_TEXT_IGNORED: line (12 characters) in (7 characters): the language is not one TextMouth carries"), "\(record.log)")
    }

    /// The log names the first 100 ignored lines, then says how many more there were.
    func testTheLogIsCappedAtOneHundredIgnoredLines() throws {
        let url = try makeFileURL()
        var lines: [String: Any] = [:]
        for index in 0..<130 { lines[String(format: "no.such%03d", index)] = ["text": "x"] }
        try data(lines).write(to: url)
        let (service, _, record) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { record.log.count == 1 + 100 + 1 })
        XCTAssertEqual(record.log.last, "INTERFACE_TEXT_IGNORED: and 30 more lines")
        XCTAssertEqual(service.outcome.ignored.count, 130)
    }

    /// Publishing another root as the data directory says so (`.dataDirectoryDidMove`) with the new root's path, later, on the main
    /// queue, once `publish` has returned and its own lock is released, not before. A boundary of the test's own is published,
    /// never the process's, and only the post that names its root counts (other posts in the process are not its).
    func testPublishingARootPostsDataDirectoryDidMoveAfterItReturns() throws {
        let first = try makeFileURL().deletingLastPathComponent()
        let second = try makeFileURL().deletingLastPathComponent()
        let boundary = StorageBoundary(root: first)
        var roots: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .dataDirectoryDidMove, object: nil, queue: .main) { note in
            let root = note.userInfo?[StorageBoundary.movedRootKey] as? String
            MainActor.assumeIsolated { if let root { roots.append(root) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let generation = boundary.publish(root: second)

        XCTAssertEqual(generation.root.path, second.path)
        XCTAssertFalse(roots.contains(second.path), "the post came before publish returned")
        XCTAssertTrue(waitUntil(timeout: 5) { roots.contains(second.path) })
        XCTAssertFalse(roots.contains(first.path), "the old root was named")
    }

    // MARK: - A file that cannot be read

    /// A file larger than any real one is ignored whole, without being read whole.
    func testAFileLargerThanAnyRealOneIsIgnoredWhole() throws {
        let url = try makeFileURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        // A sparse file: its size is past the limit, its blocks are not written.
        try handle.truncate(atOffset: UInt64(InterfaceTextOverridesFile.largestSize) + 10)
        try handle.close()
        let (service, _, _) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == .tooLarge })
    }

    /// A file that cannot be read keeps the lines in force and says so; the same bytes read well later are applied again and
    /// the problem goes (the bytes last read are forgotten by an unreadable read).
    func testAnUnreadableFileKeepsTheLinesAndTheProblemGoesWhenItReadsAgain() throws {
        try XCTSkipIf(geteuid() == 0, "a file's permissions do not stop root")
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        let (service, engine, record) = makeService(reading: { url })
        service.start()
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        service.reload()
        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == .unreadable })
        XCTAssertEqual(sleepTimer(engine), "Temporizador", "the lines in force stay")
        XCTAssertTrue(record.log.contains { $0.contains("the file could not be read and the lines in use stay") }, "\(record.log)")
        XCTAssertFalse(record.log.contains { $0.contains("lines in use") && $0.contains("could not be read") && $0.contains("whole file ignored") })

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        service.reload()
        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == nil })
        XCTAssertEqual(service.outcome.inUse.count, 1)
        XCTAssertEqual(sleepTimer(engine), "Temporizador")
    }

    /// A pipe by the file's name is a problem that shows, and it is not read (a plain read of a pipe waits forever).
    func testAPipeByTheFilesNameIsAProblemAndIsNotRead() throws {
        let url = try makeFileURL()
        XCTAssertEqual(mkfifo(url.path, 0o644), 0, "no pipe could be made")
        let (service, engine, record) = makeService(reading: { url })
        // A safety valve: should an open of the pipe ever wait for a writer again (as the watcher's did, November 23,
        // 2026), opening the pipe's other end after a few seconds releases it, so this test fails rather than hanging the
        // suite. With no open waiting, the valve's open finds no reader and does nothing.
        let path = url.path
        let valve = DispatchWorkItem {
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: valve)
        addTeardownBlock { valve.cancel() }

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == .notARegularFile })
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado")
        XCTAssertTrue(record.log.contains { $0.contains("could not be read and the lines in use stay") }, "\(record.log)")
    }

    /// A pipe or a folder takes the place of the file after its lines were read: the lines stay, and the problem shows, rather
    /// than the lines dropping as if the file were gone.
    func testAFileReplacedByAFolderKeepsTheLinesAndShowsTheProblem() throws {
        let url = try makeFileURL()
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)
        let (service, engine, _) = makeService(reading: { url })
        service.start()
        XCTAssertTrue(waitUntil(timeout: 5) { self.sleepTimer(engine) == "Temporizador" })

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        service.reload()

        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == .notARegularFile })
        XCTAssertEqual(sleepTimer(engine), "Temporizador", "the lines in force stay")
    }

    /// Edit never writes over a pipe, a folder, or a link to nothing: it refuses, and the thing is as it was.
    func testEditRefusesToWriteOverWhatIsNotAFile() throws {
        let folder = try makeFileURL().deletingLastPathComponent()
        let (service, _, _) = makeService(reading: { folder.appendingPathComponent("other.json") })
        let pipe = folder.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o644), 0)
        let dangling = folder.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: folder.appendingPathComponent("nowhere.json").path)
        let directory = folder.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        for target in [pipe, dangling, directory] {
            let editing = makeService(reading: { target }).service
            let refused = fill(editing, language: "es")
            guard case .failed = refused else { return XCTFail("a fill over \(target.lastPathComponent) was not refused: \(refused)") }
        }
        var info = stat()
        XCTAssertEqual(lstat(pipe.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFIFO), "the pipe is still a pipe")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), folder.appendingPathComponent("nowhere.json").path)
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        _ = service
    }

    /// A folder by the file's name is a problem too, and not read.
    func testAFolderByTheFilesNameIsAProblem() throws {
        let url = try makeFileURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let (service, engine, _) = makeService(reading: { url })

        service.start()

        XCTAssertTrue(waitUntil(timeout: 5) { service.outcome.fileProblem == .notARegularFile })
        XCTAssertEqual(sleepTimer(engine), "Temporizador de apagado")
    }
}
