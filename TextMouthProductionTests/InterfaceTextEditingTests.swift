import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Mac's Edit Interface Text… and Export Interface Text… (FR39 phase 10, step 4), and the group that holds them. Every
/// file is in a folder of the test's own inside the isolated test root, nothing is opened in an editor, and no panel is
/// shown.
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

    /// Edit fills a missing file, then opens it, once.
    func testEditFillsAMissingFileAndOpensIt() throws {
        let (service, file) = try makeService()
        var opened: [URL] = []
        var announced: [String] = []

        let result = InterfaceTextEditing.edit(service: service, language: "es", open: { opened.append($0); return true }, announce: { announced.append($0) })

        XCTAssertTrue(result)
        XCTAssertEqual(opened, [file])
        XCTAssertEqual(announced, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A file that has the language is opened as it is, never written over.
    func testEditOpensAFileThatHasTheLanguageAsItIs() throws {
        let (service, file) = try makeService()
        let bytes = Data(#"{"version": 1, "languages": {"es": {"lines": {}}}}"#.utf8)
        try bytes.write(to: file)
        var opened: [URL] = []

        InterfaceTextEditing.edit(service: service, language: "es", open: { opened.append($0); return true }, announce: { _ in })

        XCTAssertEqual(opened, [file])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    /// When the file cannot be made, or cannot be opened, VoiceOver is told and nothing is opened.
    func testEditSaysWhenItCannot() throws {
        let (unavailable, file) = try makeService(isUnavailable: true)
        var opened = 0
        var announced: [String] = []

        let refused = InterfaceTextEditing.edit(service: unavailable, language: "es", open: { _ in opened += 1; return true }, announce: { announced.append($0) })

        XCTAssertFalse(refused)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(announced, [InterfaceTextOverridesWording.editFailed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let (service, _) = try makeService()
        announced = []
        let notOpened = InterfaceTextEditing.edit(service: service, language: "es", open: { _ in false }, announce: { announced.append($0) })
        XCTAssertFalse(notOpened)
        XCTAssertEqual(announced, [InterfaceTextOverridesWording.editFailed])
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

    // MARK: - The group

    /// The group hosted in a window of a fixed size holds both commands, as buttons the keyboard reaches, and nowhere else do
    /// the commands live.
    func testTheGroupHoldsBothCommands() throws {
        let view = Form { InterfaceLanguageSettingsSection(choice: .system) }
            .frame(width: 450, height: 420)

        try withHostedView(
            view,
            size: NSSize(width: 450, height: 420),
            until: { hosting in
                let titles = self.descendants(of: hosting, as: NSButton.self).map(\.title)
                return titles.contains(InterfaceTextOverridesWording.editTitle) && titles.contains(InterfaceTextOverridesWording.exportTitle)
            }
        ) { hosting in
            let buttons = self.descendants(of: hosting, as: NSButton.self)
            let edit = try XCTUnwrap(buttons.first { $0.title == InterfaceTextOverridesWording.editTitle })
            let export = try XCTUnwrap(buttons.first { $0.title == InterfaceTextOverridesWording.exportTitle })
            XCTAssertTrue(edit.isEnabled)
            XCTAssertTrue(export.isEnabled)
            XCTAssertEqual(buttons.filter { $0.title == InterfaceTextOverridesWording.editTitle }.count, 1)
            XCTAssertEqual(buttons.filter { $0.title == InterfaceTextOverridesWording.exportTitle }.count, 1)
        }
    }
}
