import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// The person's own interface lines on the iPhone's own code (FR39 phase 10): the service that reads
/// `interface_text.json` and applies it, the outcome of the system's file exporter, and the document Export Interface Text…
/// hands that exporter. The files are in a folder of the test's own in the app's temporary directory; no exporter opens,
/// and nothing is played or typed. (The same checks on the shipped pack, for every language, are
/// `InterfaceTextShippedPackTests`, which this bundle runs too.)
@MainActor
final class InterfaceTextOverridesIOSTests: XCTestCase {
    /// A pack made in memory: a plain line and a plural line, English and Spanish.
    private static let lines: [String: [String: String]] = [
        "common.sleepTimer": ["en": "Sleep Timer", "es": "Temporizador de apagado"],
        "common.countMinutes": ["en": pluralEntry("%lld minute", "%lld minutes"), "es": "%lld minutos"],
    ]

    /// A folder of this test's own, removed when it ends.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterfaceTextIOSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Polls the main run loop until `condition` holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    // MARK: - The service

    /// The service reads the file once started, the engine takes the person's line, and a line left alone keeps the pack's text.
    func testTheServiceReadsAndAppliesTheFile() throws {
        let file = try makeFolder().appendingPathComponent(TextMouthPaths.interfaceTextFileName)
        let root: [String: Any] = ["version": 1, "languages": ["es": ["lines": [
            "common.sleepTimer": ["text": "Temporizador", "base": "Temporizador de apagado"],
            "common.countMinutes": ["plural": ["one": "%lld min", "many": "%lld de min", "other": "%lld min"]],
        ]]]]
        try JSONSerialization.data(withJSONObject: root).write(to: file)
        let engine = makeInterfaceTextEngine(Self.lines, log: InterfaceTextReportLog())
        var changes = 0
        let service = InterfaceTextOverrides(
            engine: engine, fileURL: { file }, isUnavailable: { false }, linesDidChange: { changes += 1 }, log: { _ in },
            quietPeriod: .milliseconds(60)
        )
        addTeardownBlock { service.stop() }

        service.start(observing: NotificationCenter())

        XCTAssertTrue(waitUntil(timeout: 5) { interfaceLine(engine, "common.sleepTimer", "Sleep Timer") == "Temporizador" })
        let count = 3
        XCTAssertEqual(interfaceLine(engine, "common.countMinutes", "\(number: count) minutes"), "3 min")
        XCTAssertEqual(service.outcome.inUse.count, 2)
        XCTAssertEqual(changes, 1)
    }

    /// A change of the file reaches the engine through the watcher, and the file's going away puts the pack's text back.
    func testAChangeOfTheFileIsFollowed() throws {
        let file = try makeFolder().appendingPathComponent(TextMouthPaths.interfaceTextFileName)
        let engine = makeInterfaceTextEngine(Self.lines, log: InterfaceTextReportLog())
        let service = InterfaceTextOverrides(
            engine: engine, fileURL: { file }, isUnavailable: { false }, linesDidChange: {}, log: { _ in },
            quietPeriod: .milliseconds(60), retryDelays: [.milliseconds(20)]
        )
        addTeardownBlock { service.stop() }
        service.start(observing: NotificationCenter())
        _ = waitUntil(timeout: 0.4) { false }

        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "languages": ["es": ["lines": ["common.sleepTimer": ["text": "Uno"]]]]])
        try json.write(to: file)
        service.fileMayHaveArrived()
        XCTAssertTrue(waitUntil(timeout: 5) { interfaceLine(engine, "common.sleepTimer", "Sleep Timer") == "Uno" })

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(waitUntil(timeout: 5) { interfaceLine(engine, "common.sleepTimer", "Sleep Timer") == "Temporizador de apagado" })
    }

    /// The export of the iPhone's own code reads back whole, with the plural line as plural though the pack stores its
    /// Spanish as one text, and writes nothing to the data directory's file.
    func testTheExportReadsBackWhole() throws {
        let file = try makeFolder().appendingPathComponent(TextMouthPaths.interfaceTextFileName)
        let engine = makeInterfaceTextEngine(Self.lines, log: InterfaceTextReportLog())
        let service = InterfaceTextOverrides(engine: engine, fileURL: { file }, isUnavailable: { false }, linesDidChange: {}, log: { _ in })

        let data = try XCTUnwrap(service.exportData(language: "es"))

        let reference = try XCTUnwrap(engine.reference(language: "en", withNotes: false))
        let read = InterfaceTextOverridesFile.read(data, reference: reference)
        XCTAssertNil(read.fileProblem)
        XCTAssertEqual(read.ignored, [])
        XCTAssertEqual(read.inUse.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an export never writes the data directory's file")
    }

    // MARK: - The exporter

    /// What the exporter reports becomes one of three outcomes: saved (by name), cancelled (which says nothing), or failed (by
    /// the error's domain and code, never a path).
    func testTheExporterResultBecomesAnOutcome() {
        XCTAssertEqual(InterfaceTextExportOutcome(.success(URL(fileURLWithPath: "/Documents/interface_text-es.json"))), .exported(fileName: "interface_text-es.json"))
        XCTAssertEqual(InterfaceTextExportOutcome(.failure(CocoaError(.userCancelled))), .cancelled)
        XCTAssertEqual(InterfaceTextExportOutcome(.failure(CocoaError(.fileWriteNoPermission))), .failed(reason: "NSCocoaErrorDomain 513"))
    }

    /// The document hands the exporter the bytes as they are, as JSON.
    func testTheDocumentHoldsTheExportsBytesAsJSON() {
        let bytes = Data(#"{"version": 1}"#.utf8)
        let document = InterfaceTextExportDocument(data: bytes)

        XCTAssertEqual(document.data, bytes)
        XCTAssertEqual(InterfaceTextExportDocument.readableContentTypes, [.json])
    }
}
