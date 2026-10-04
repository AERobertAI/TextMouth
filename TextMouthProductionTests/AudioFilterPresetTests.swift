import XCTest
@testable import TextMouth

/// The filter presets (FR04), kept in audio-filters.json beside
/// substitutions.json and read as it is: the premade presets stand in,
/// unsaved, until a change copies them into the file; edits, removals,
/// moves, and a reset are saved and read back; a damaged file is preserved
/// and the premade presets stand in; a file only in the cloud is neither
/// read nor written over; and one that arrives from another Mac while the
/// premade presets stand in is taken up instead of a change.
@MainActor
final class AudioFilterPresetTests: XCTestCase {

    /// The presets file lives in the data directory, beside
    /// substitutions.json.
    func testThePresetsFileIsBesideSubstitutionsJSON() {
        XCTAssertEqual(TextMouthPaths.audioFiltersFile, TextMouthPaths.root.appendingPathComponent("audio-filters.json"))
        XCTAssertEqual(
            TextMouthPaths.audioFiltersFile.deletingLastPathComponent(),
            TextMouthPaths.substitutionsFile.deletingLastPathComponent()
        )
    }

    /// With no file, the premade presets stand in and nothing is written;
    /// the first change copies them all into the file, with the change.
    func testThePremadePresetsStandInUntilAChangeCopiesThem() throws {
        let url = try makeFileURL()
        let library = AudioFilterPresetLibrary(url: url)
        XCTAssertEqual(library.presets, AudioFilterPresetLibrary.standard)
        XCTAssertTrue(library.standsInForMissingFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let added = try library.add(name: "  Phone Line  ", chain: "highpass=f=300,lowpass=f=3400")

        XCTAssertEqual(added.name, "Phone Line")
        XCTAssertFalse(library.standsInForMissingFile)
        XCTAssertEqual(AudioFilterPresetLibrary(url: url).presets, AudioFilterPresetLibrary.standard + [added])
    }

    /// Edits, removals, moves, and a reset are saved, and a new library
    /// reads them back as they were left.
    func testPresetsAreEditedSavedAndReadBack() throws {
        let url = try makeFileURL()
        let library = AudioFilterPresetLibrary(url: url)
        let first = try XCTUnwrap(library.presets.first)
        let second = try XCTUnwrap(library.presets.dropFirst().first)

        try library.update(AudioFilterPreset(id: first.id, name: "Less Rumble", chain: "highpass=f=60"))
        try library.move(first.id, .down)
        try library.remove(second.id)
        try library.move(first.id, .up)

        let reread = AudioFilterPresetLibrary(url: url).presets
        XCTAssertEqual(reread.first, AudioFilterPreset(id: first.id, name: "Less Rumble", chain: "highpass=f=60"))
        XCTAssertFalse(reread.contains { $0.id == second.id })
        XCTAssertEqual(reread.count, AudioFilterPresetLibrary.standard.count - 1)

        try library.resetToDefaults()
        XCTAssertEqual(AudioFilterPresetLibrary(url: url).presets, AudioFilterPresetLibrary.standard)
    }

    /// A blank name or chain is refused, and nothing is saved.
    func testBlankNamesAndChainsAreRefused() throws {
        let url = try makeFileURL()
        let library = AudioFilterPresetLibrary(url: url)
        XCTAssertThrowsError(try library.add(name: " ", chain: "volume=2")) { error in
            XCTAssertEqual(error as? AudioFilterPresetError, .blankName)
            XCTAssertEqual(error.localizedDescription, "A filter preset needs a name.")
        }
        XCTAssertThrowsError(try library.add(name: "Nothing", chain: "  ")) { error in
            XCTAssertEqual(error as? AudioFilterError, .empty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A file that can't be decoded is preserved beside itself, and the
    /// premade presets stand in until a change replaces it.
    func testADamagedFileIsPreservedAndThePremadeOnesStandIn() throws {
        let url = try makeFileURL()
        let damaged = Data(#"{"version":1,"presets":[{"name":"#.utf8)
        try damaged.write(to: url)

        let library = AudioFilterPresetLibrary(url: url)

        XCTAssertEqual(library.presets, AudioFilterPresetLibrary.standard)
        let copies = LibraryIndexQuarantine.existingCopies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copies.first)), damaged)
        try library.add(name: "Phone Line", chain: "highpass=f=300")
        XCTAssertEqual(AudioFilterPresetLibrary(url: url).presets.last?.name, "Phone Line")
    }

    /// A file only in the cloud is never read, which would download it, and
    /// nothing is written over it: a change waits until it is on this Mac.
    func testAFileOnlyInTheCloudIsNeitherReadNorWrittenOver() throws {
        let url = try makeFileURL()
        let library = AudioFilterPresetLibrary(url: url, reader: { _ in throw LocalBookFiles.downloadRefusal })

        XCTAssertTrue(library.awaitsFileInCloud)
        XCTAssertEqual(library.presets, AudioFilterPresetLibrary.standard)
        XCTAssertThrowsError(try library.add(name: "Phone Line", chain: "highpass=f=300")) { error in
            XCTAssertTrue(error is SavedFile.InCloudError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A file another Mac saved, arriving while the premade presets stand
    /// in for it, is taken up instead of a change, which isn't made.
    func testAFileThatArrivedIsTakenUpInsteadOfAChange() throws {
        let url = try makeFileURL()
        let library = AudioFilterPresetLibrary(url: url)
        let theirs = AudioFilterPreset(id: UUID(), name: "Their Preset", chain: "volume=2")
        try Data(#"{"version":1,"presets":[{"id":"\#(theirs.id.uuidString)","name":"Their Preset","chain":"volume=2"}]}"#.utf8)
            .write(to: url)

        XCTAssertThrowsError(try library.add(name: "Mine", chain: "volume=0.5")) { error in
            XCTAssertEqual(error as? AudioFilterPresetError, .fileArrived)
        }
        XCTAssertEqual(library.presets, [theirs])
        XCTAssertEqual(AudioFilterPresetLibrary(url: url).presets, [theirs])
    }

    // MARK: - Helpers

    /// Where a presets file of this test's own goes, in a folder removed
    /// when the test ends.
    private func makeFileURL() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(AudioFilterPresetLibrary.fileName)
    }
}
