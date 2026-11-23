import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Mac's Edit Interface Text… and Export Interface Text… (FR39 phase 10, step 4). Every file is in a folder of the
/// test's own inside the isolated test root, nothing is opened in an editor, and no panel is shown. The group that holds the
/// two buttons draws them as SwiftUI views, not AppKit controls, so a hosted window cannot find them (the buttons' words,
/// hints, and place are pinned by InterfaceTextOverridesWordingTests and the source).
@MainActor
final class InterfaceTextEditingTests: XCTestCase {
    // MARK: - Support

    /// A service over a pack in memory and a file in a folder of this test's own.
    private func makeService(isUnavailable: Bool = false) throws -> (service: InterfaceTextOverrides, file: URL) {
        let directory = TextMouthPaths.root.appendingPathComponent("InterfaceTextEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(TextMouthPaths.interfaceTextFileName)
        let engine = makeInterfaceTextEngine([
            "common.sleepTimer": ["en": "Sleep Timer", "es": "Temporizador de apagado"],
        ], log: InterfaceTextReportLog())
        let service = InterfaceTextOverrides(
            engine: engine,
            fileURL: { file },
            isUnavailable: { isUnavailable },
            linesDidChange: {},
            log: { _ in }
        )
        addTeardownBlock { service.stop() }
        return (service, file)
    }

    // MARK: - Edit Interface Text…

    /// What the editor was asked to open, and what VoiceOver was told.
    private final class Calls {
        var opened: [URL] = []
        var announced: [String] = []
    }

    /// Edit with an editor that opens (or refuses to open) nothing real, recording into `calls`.
    private func edit(_ service: InterfaceTextOverrides, _ calls: Calls, opening succeeds: Bool = true) async -> Bool {
        await InterfaceTextEditing.edit(
            service: service,
            language: "es",
            open: { url in
                calls.opened.append(url)
                if !succeeds { throw CocoaError(.fileReadUnknown) }
            },
            announce: { calls.announced.append($0) }
        )
    }

    /// Edit fills a missing file, then opens it, once.
    func testEditFillsAMissingFileAndOpensIt() async throws {
        let (service, file) = try makeService()
        let calls = Calls()

        let result = await edit(service, calls)

        XCTAssertTrue(result)
        XCTAssertEqual(calls.opened, [file])
        XCTAssertEqual(calls.announced, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A file that has the language is opened as it is, never written over.
    func testEditOpensAFileThatHasTheLanguageAsItIs() async throws {
        let (service, file) = try makeService()
        let bytes = Data(#"{"version": 1, "languages": {"es": {"lines": {}}}}"#.utf8)
        try bytes.write(to: file)
        let calls = Calls()

        _ = await edit(service, calls)

        XCTAssertEqual(calls.opened, [file])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    /// A file whose version this TextMouth does not know is left as it is, opened, and VoiceOver says so.
    func testEditLeavesAFileOfAnUnknownVersionAndSaysSo() async throws {
        let (service, file) = try makeService()
        let bytes = Data(#"{"version": 2, "languages": {"fr": {"lines": {}}}}"#.utf8)
        try bytes.write(to: file)
        let calls = Calls()

        let result = await edit(service, calls)

        XCTAssertFalse(result)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(calls.opened, [file])
        XCTAssertEqual(calls.announced, [InterfaceTextOverridesWording.editVersionUnknown])
    }

    /// When the file cannot be made, nothing is opened and VoiceOver says it could not be made.
    func testEditSaysWhenTheFileCannotBeMade() async throws {
        let (unavailable, file) = try makeService(isUnavailable: true)
        let calls = Calls()

        let refused = await edit(unavailable, calls)

        XCTAssertFalse(refused)
        XCTAssertEqual(calls.opened, [])
        XCTAssertEqual(calls.announced, [InterfaceTextOverridesWording.editFailed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// When the file was made and the editor cannot open it, the sentence is its own: the file exists, so "could not be made"
    /// would be false.
    func testEditSaysWhenTheEditorCannotOpenTheFile() async throws {
        let (service, file) = try makeService()
        let calls = Calls()

        let opened = await edit(service, calls, opening: false)

        XCTAssertFalse(opened)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(calls.announced, [InterfaceTextOverridesWording.editOpenFailed])
        XCTAssertNotEqual(InterfaceTextOverridesWording.editOpenFailed, InterfaceTextOverridesWording.editFailed)
    }

    // MARK: - Export Interface Text…

    /// An export is written in one step and announced by the file's name.
    func testExportWritesTheFileAndAnnouncesIt() throws {
        let (service, file) = try makeService()
        let data = try XCTUnwrap(service.exportData(language: "es"))
        let destination = file.deletingLastPathComponent().appendingPathComponent("interface_text-es.json")
        var announced: [String] = []

        let written = InterfaceTextEditing.write(data, to: destination, announce: { announced.append($0) })

        XCTAssertTrue(written)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(announced, ["Exported the interface text to interface_text-es.json."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an export never touches the data directory's file")
    }

    /// A destination that cannot be written is said, and nothing is claimed.
    func testExportSaysWhenItCannotWrite() throws {
        let (service, file) = try makeService()
        let data = try XCTUnwrap(service.exportData(language: "es"))
        let missingFolder = file.deletingLastPathComponent().appendingPathComponent("nowhere/interface_text-es.json")
        var announced: [String] = []

        let written = InterfaceTextEditing.write(data, to: missingFolder, announce: { announced.append($0) })

        XCTAssertFalse(written)
        XCTAssertEqual(announced, [InterfaceTextOverridesWording.exportFailed])
    }
}
