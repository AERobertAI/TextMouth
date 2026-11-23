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
            quietPeriod: .milliseconds(60)
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
        _ = waitUntil(timeout: 0.3) { false }
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)

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
        _ = waitUntil(timeout: 0.3) { false }
        try data(["common.sleepTimer": ["text": "Temporizador"]]).write(to: url)

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

        XCTAssertEqual(service.fillFileForEditing(language: "es"), .written)

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
        XCTAssertEqual(service.fillFileForEditing(language: "es"), .written)
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

        XCTAssertEqual(service.fillFileForEditing(language: "es"), .leftAsItIs)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        XCTAssertEqual(service.fillFileForEditing(language: "en"), .written)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set((root["languages"] as? [String: Any])?.keys.map { $0 } ?? []), ["es", "en"])
    }

    /// Nothing is written while the data directory is unavailable.
    func testEditWritesNothingWhileTheDataDirectoryIsUnavailable() throws {
        let url = try makeFileURL()
        let (service, _, _) = makeService(reading: { url }, isUnavailable: { true })

        guard case .failed = service.fillFileForEditing(language: "es") else { return XCTFail("a fill was not refused") }
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
            "INTERFACE_TEXT_IGNORED: line common.nonsense in es: TextMouth has no line with that ID",
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

    /// A key of the person's file that is not an ID is never logged as it is.
    func testAKeyThatIsNotAnIDIsLoggedAsALength() {
        XCTAssertEqual(InterfaceTextOverrides.loggable("common.sleepTimer"), "common.sleepTimer")
        XCTAssertEqual(InterfaceTextOverrides.loggable("pt-BR"), "pt-BR")
        XCTAssertEqual(InterfaceTextOverrides.loggable("my secret words"), "(15 characters)")
        XCTAssertEqual(InterfaceTextOverrides.loggable("é"), "(1 characters)")
        XCTAssertEqual(InterfaceTextOverrides.loggable(String(repeating: "a", count: 65)), "(65 characters)")
        XCTAssertEqual(InterfaceTextOverrides.loggable(String(repeating: "a", count: 64)), String(repeating: "a", count: 64))
    }
}
